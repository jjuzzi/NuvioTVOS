import Darwin
import Foundation

/// Poster and backdrop cache ceilings.
///
/// When `os_proc_available_memory` is plentiful the historical physical-RAM
/// tiers are kept, so normal browsing does not hold fewer images. A tight
/// launch uses a smaller ceiling. Playback then suspends the caches separately.
enum CatalogImageCacheBudget {
    static func posterBytes(
        physicalMemoryBytes: UInt64,
        availableMemoryBytes: UInt64,
        allowsLiquidGlass: Bool
    ) -> Int {
        let gib = Double(physicalMemoryBytes) / 1_073_741_824.0
        let base: Int
        if !allowsLiquidGlass {
            base = 80 * 1024 * 1024
        } else if gib > 3.5 {
            base = 140 * 1024 * 1024
        } else if gib > 2.5 {
            base = 100 * 1024 * 1024
        } else {
            base = 60 * 1024 * 1024
        }
        return tightened(base, availableMemoryBytes: availableMemoryBytes, floor: 32 * 1024 * 1024)
    }

    static func posterCount(
        physicalMemoryBytes: UInt64,
        availableMemoryBytes: UInt64,
        allowsLiquidGlass: Bool
    ) -> Int {
        let gib = Double(physicalMemoryBytes) / 1_073_741_824.0
        let base: Int
        if !allowsLiquidGlass {
            base = 120
        } else if gib > 3.5 {
            base = 220
        } else if gib > 2.5 {
            base = 160
        } else {
            base = 90
        }
        if plentiful(availableMemoryBytes) { return base }
        return min(base, 80)
    }

    static func backdropBytes(physicalMemoryBytes: UInt64, availableMemoryBytes: UInt64) -> Int {
        let gib = Double(physicalMemoryBytes) / 1_073_741_824.0
        let base: Int
        if gib > 3.5 {
            base = 96 * 1024 * 1024
        } else if gib > 2.5 {
            base = 64 * 1024 * 1024
        } else {
            base = 40 * 1024 * 1024
        }
        return tightened(base, availableMemoryBytes: availableMemoryBytes, floor: 16 * 1024 * 1024)
    }

    private static func plentiful(_ availableMemoryBytes: UInt64) -> Bool {
        availableMemoryBytes >= 512 * 1024 * 1024
    }

    private static func tightened(_ base: Int, availableMemoryBytes: UInt64, floor: Int) -> Int {
        guard !plentiful(availableMemoryBytes) else { return base }
        return min(base, max(floor, Int(availableMemoryBytes / 8)))
    }
}

enum CatalogArtworkMemory {
    static func setPlaybackActive(_ active: Bool) {
        Task {
            await PosterArtworkCache.shared.setPlaybackSuspended(active)
        }
        BackdropImageCache.shared.setPlaybackSuspended(active)
    }
}
