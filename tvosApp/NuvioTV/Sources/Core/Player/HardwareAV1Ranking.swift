import Foundation
#if !targetEnvironment(simulator)
import AetherEngine
#endif

/// How 4K streams are ranked once the device can hardware-decode AV1.
///
/// The Apple TV simulator cannot play AV1, so it keeps the historical HEVC bias.
/// A device whose VideoToolbox probe reports hardware AV1 prefers that codec,
/// except Dolby Vision, which stays on HEVC.
enum HardwareAV1Ranking {
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return AppleTVCapability.current.supportsAV1HardwareDecode
        #else
        return VTCapabilityProbe.av1Available
        #endif
    }

    static func boost(
        tags: StreamQualityTags,
        resolution: Int,
        preferHardware: Bool,
        av1Hardware: Bool? = nil
    ) -> Int {
        guard preferHardware, resolution >= 2160 else { return 0 }
        let available = av1Hardware ?? isAvailable
        if !available {
            if tags.isHardwareAccelerated() {
                return 25_000
            }
            if tags.isAV1 {
                return -25_000
            }
            return 0
        }
        if tags.isDolbyVision {
            if tags.isAV1 { return -25_000 }
            if tags.isHEVC || tags.isHardwareAccelerated() { return 25_000 }
            return 0
        }
        if tags.isAV1 { return 30_000 }
        if tags.isHardwareAccelerated() { return 25_000 }
        return 0
    }

    /// Higher sorts earlier among otherwise equal 4K streams.
    static func qualityRank(tags: StreamQualityTags) -> Int {
        if tags.isDolbyVision {
            if tags.isAV1 { return 0 }
            if tags.isHEVC || tags.isHardwareAccelerated() { return 2 }
            return 1
        }
        if tags.isAV1 { return 3 }
        if tags.isHardwareAccelerated() { return 2 }
        return 1
    }
}
