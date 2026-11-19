import Foundation
import Darwin

// MARK: - Network buffer sizing

/// libmpv network-cache sizes, driven by Settings → Playback → Network Cache.
/// `forwardBuffer` is how far ahead mpv prefetches ("preload"); `backBuffer`
/// keeps already-played data resident for instant backward seeks. Values are
/// libmpv bytesize strings (e.g. `"128MiB"`).
///
/// Dynamic scaling in Auto balances ample readahead runway for high-bitrate 4K
/// (512 MiB forward on high-headroom 4 GB devices like Apple TV 4K Gen 3)
/// against tvOS jetsam memory pressure limits, throttling down on lower-RAM/constrained
/// devices or under memory pressure.
struct PlaybackCacheSettings: Equatable {
    let forwardBuffer: String
    let backBuffer: String

    static var current: PlaybackCacheSettings {
        switch ProfileSettings.current.string(forKey: SettingsKey.networkCache) ?? "Auto" {
        case "Small", "Conservative":
            // Minimal readahead — prefer stability over seek/buffer comfort.
            return PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        case "Medium":
            return PlaybackCacheSettings(forwardBuffer: "128MiB", backBuffer: "32MiB")
        case "Large":
            return PlaybackCacheSettings(forwardBuffer: "192MiB", backBuffer: "48MiB")
        case "Max":
            // High-RAM Apple TV (256 MiB forward / 64 MiB back).
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        case "Ultra", "Extreme":
            // Safe ceiling for Apple TV 4K Gen 3. Leaves ample headroom for 4K VideoToolbox decode.
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        default:
            return auto
        }
    }

    /// Dynamically scales buffer size based on live available memory headroom and physical RAM.
    /// Safely sized on tvOS to ensure VideoToolbox 4K decoding (videocodecd ~1.5 GB) never triggers jetsam kills.
    /// - High Headroom (Apple TV 4K Gen 3 with 4GB RAM and >=350 MB available) -> 256/64
    /// - Mid Headroom (Apple TV 4K Gen 1/2 with 3GB RAM and >=250 MB available) -> 256/64
    /// - Constrained Memory (>=150 MB available) -> 128/32
    /// - Low Memory (<150 MB or Apple TV HD) -> 64/16
    static var auto: PlaybackCacheSettings {
        resolveAuto(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            availableMemoryBytes: os_proc_available_memory(),
            footprintBytes: PlaybackMemoryBudget.footprintBytes()
        )
    }

    static func resolveAuto(
        physicalMemoryBytes: UInt64,
        availableMemoryBytes: size_t,
        footprintBytes: UInt64 = 0
    ) -> PlaybackCacheSettings {
        let gibPhysical = Double(physicalMemoryBytes) / 1_073_741_824.0
        let mbAvailable = Double(availableMemoryBytes) / (1024.0 * 1024.0)

        let ramTier: PlaybackCacheSettings
        if gibPhysical > 3.5 && mbAvailable >= 350 {
            ramTier = PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        } else if gibPhysical > 2.5 && mbAvailable >= 250 {
            ramTier = PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        } else if mbAvailable >= 150 {
            ramTier = PlaybackCacheSettings(forwardBuffer: "128MiB", backBuffer: "32MiB")
        } else {
            ramTier = PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        }
        return PlaybackMemoryBudget.tightened(ramTier, footprintBytes: footprintBytes, availableMemoryBytes: availableMemoryBytes)
    }
}

/// The tvOS process is jetsam-limited near 2 GB even when the box has more RAM.
/// A zero footprint means the caller did not measure, and the historical tier is kept.
enum PlaybackMemoryBudget {
    static let jetsamBytes: UInt64 = 2 * 1_073_741_824
    /// Room left inside that cap for a 4K HDR decode session besides the cache.
    static let decodeReserveBytes: UInt64 = 768 * 1_048_576

    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// Bytes still safe to spend on caches. Nil when footprint was not measured.
    static func effectiveFreeBytes(availableMemoryBytes: UInt64, footprintBytes: UInt64) -> UInt64? {
        guard footprintBytes > 0 else { return nil }
        let room = jetsamBytes > footprintBytes &+ decodeReserveBytes
            ? jetsamBytes &- footprintBytes &- decodeReserveBytes
            : 0
        return min(availableMemoryBytes, room)
    }

    static func tightened(
        _ tier: PlaybackCacheSettings,
        footprintBytes: UInt64,
        availableMemoryBytes: size_t
    ) -> PlaybackCacheSettings {
        guard let free = effectiveFreeBytes(
            availableMemoryBytes: UInt64(availableMemoryBytes),
            footprintBytes: footprintBytes
        ) else {
            return tier
        }
        let freeMB = Double(free) / (1024.0 * 1024.0)
        if freeMB >= 512 { return tier }
        if freeMB >= 180 {
            return moreConservative(tier, PlaybackCacheSettings(forwardBuffer: "128MiB", backBuffer: "32MiB"))
        }
        return moreConservative(tier, PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB"))
    }

    private static func moreConservative(
        _ current: PlaybackCacheSettings,
        _ ceiling: PlaybackCacheSettings
    ) -> PlaybackCacheSettings {
        let rank: (PlaybackCacheSettings) -> Int = { settings in
            switch settings.forwardBuffer {
            case "256MiB": return 3
            case "192MiB": return 2
            case "128MiB": return 1
            default: return 0
            }
        }
        return rank(ceiling) < rank(current) ? ceiling : current
    }
}

/// Fixed RAM limits for MPV; remote sources may use libmpv's separate packet
/// cache on disk when its sandbox directory is available.
struct MPVPlaybackCachePolicy: Equatable {
    let nativeDiskEnabled: Bool
    let forwardBuffer: String
    let backBuffer: String
    let cacheSeconds: Int
    let source: Source

    enum Source: Equatable {
        case localOrLoopback
        case remote
        case liveRemote
    }

    var diagnosticMode: String {
        switch (source, nativeDiskEnabled) {
        case (.localOrLoopback, _): return "local_or_disk"
        case (.remote, true): return "network_disk"
        case (.liveRemote, true): return "live_network_disk"
        case (.remote, false): return "network_ram_fallback"
        case (.liveRemote, false): return "live_network_ram_fallback"
        }
    }

    static func resolve(
        url: URL,
        isLiveStream: Bool,
        profile: PlaybackCacheProfile,
        nativeDiskAvailable: Bool
    ) -> MPVPlaybackCachePolicy {
        let host = url.host?.lowercased()
        let isLocal = url.isFileURL || host == "localhost" || host == "127.0.0.1" || host == "::1"
        let source: Source = isLocal ? .localOrLoopback : (isLiveStream ? .liveRemote : .remote)
        let useDisk = !isLocal && nativeDiskAvailable
        let duration = isLocal ? 30 : max(1, Int(ceil(profile.hybridCacheTargetLeadSeconds)))
        return MPVPlaybackCachePolicy(
            nativeDiskEnabled: useDisk,
            forwardBuffer: "32MiB",
            backBuffer: "16MiB",
            cacheSeconds: duration,
            source: source
        )
    }
}

extension PlaybackCacheSettings {
    /// Creates the app-owned directory used by libmpv's temporary packet cache.
    /// Returns nil when the sandbox location is unavailable or unwritable.
    static func prepareMPVPacketCacheDirectory(
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) -> URL? {
        guard let root = cachesDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = root.appendingPathComponent("MPVPacketCache", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return fileManager.isWritableFile(atPath: directory.path) ? directory : nil
        } catch {
            return nil
        }
    }
}

