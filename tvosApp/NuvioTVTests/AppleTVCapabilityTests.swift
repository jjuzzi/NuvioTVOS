import XCTest
@testable import NuvioTV

final class AppleTVCapabilityTests: XCTestCase {
    private let appleTVHD = AppleTVCapability(
        maxResolution: 1080,
        supportsHDR: false,
        supportsDolbyVision: false,
        supportsHEVCHardwareDecode: false,
        supportsAV1HardwareDecode: false
    )

    private let appleTV4K = AppleTVCapability(
        maxResolution: 2160,
        supportsHDR: true,
        supportsDolbyVision: true,
        supportsHEVCHardwareDecode: true,
        supportsAV1HardwareDecode: false
    )

    func testAppleTVHDRejects4KDolbyVision() {
        let tags = StreamQualityTags.parse(name: "Movie 2160p Dolby Vision")
        XCTAssertFalse(appleTVHD.isPlayable(tags: tags))
    }

    func testAppleTVHDRejectsHDROnlyAtAnyResolution() {
        let tags = StreamQualityTags.parse(name: "Movie 1080p HDR10")
        XCTAssertFalse(appleTVHD.isPlayable(tags: tags))
    }

    func testAppleTVHDAccepts1080pSDR() {
        let tags = StreamQualityTags.parse(name: "Movie 1080p WEB-DL")
        XCTAssertTrue(appleTVHD.isPlayable(tags: tags))
    }

    func testAppleTVHDAccepts1080pHDRip() {
        let tags = StreamQualityTags.parse(name: "Movie 1080p HDRip x264")
        XCTAssertFalse(tags.isHDR)
        XCTAssertTrue(appleTVHD.isPlayable(tags: tags))
    }

    func testAppleTVHDAcceptsUntaggedStream() {
        let tags = StreamQualityTags.parse(name: "Movie")
        XCTAssertTrue(appleTVHD.isPlayable(tags: tags))
    }

    func testAppleTV4KAccepts4KDolbyVision() {
        let tags = StreamQualityTags.parse(name: "Movie 2160p Dolby Vision")
        XCTAssertTrue(appleTV4K.isPlayable(tags: tags))
    }

    func testUnknownHardwareIdentifierIsAvailable() {
        XCTAssertFalse(AppleTVCapability.hardwareIdentifier().isEmpty)
    }

    func testAppleTV4K1stGenDisablesLiquidGlass() {
        let firstGen = AppleTVCapability.capability(for: "AppleTV6,2")
        XCTAssertFalse(firstGen.supportsLiquidGlass)
        XCTAssertTrue(firstGen.supportsHDR)
        XCTAssertTrue(firstGen.supportsDolbyVision)
    }

    func testAppleTVHDDisablesLiquidGlass() {
        let hd = AppleTVCapability.capability(for: "AppleTV5,3")
        XCTAssertFalse(hd.supportsLiquidGlass)
    }

    func testAppleTV4K2ndAnd3rdGenEnableLiquidGlass() {
        let secondGen = AppleTVCapability.capability(for: "AppleTV11,1")
        XCTAssertTrue(secondGen.supportsLiquidGlass)

        let thirdGen = AppleTVCapability.capability(for: "AppleTV14,1")
        XCTAssertTrue(thirdGen.supportsLiquidGlass)
    }

    func testDisplayCriteriaStayWhenOnlyResolutionChanges() {
        let held = DisplayCriteriaContinuity.OutputMode(refreshRate: 23.976, dynamicRange: "pq")
        let nextEpisode = DisplayCriteriaContinuity.OutputMode(refreshRate: 23.976, dynamicRange: "pq")
        XCTAssertTrue(DisplayCriteriaContinuity.shouldReuseHeldMode(current: held, next: nextEpisode))

        let differentRate = DisplayCriteriaContinuity.OutputMode(refreshRate: 24, dynamicRange: "pq")
        XCTAssertFalse(DisplayCriteriaContinuity.shouldReuseHeldMode(current: held, next: differentRate))

        let sdr = DisplayCriteriaContinuity.OutputMode(refreshRate: 23.976, dynamicRange: "sdr")
        XCTAssertFalse(DisplayCriteriaContinuity.shouldReuseHeldMode(current: held, next: sdr))
        XCTAssertFalse(DisplayCriteriaContinuity.shouldReuseHeldMode(current: nil, next: held))
    }

    func testHardwareAV1RankingKeepsTheOldBiasWithoutHardware() {
        let av1 = StreamQualityTags(resolution: 2160, isAV1: true, isHDR: true)
        let hevc = StreamQualityTags(resolution: 2160, isHEVC: true, isHDR: true)
        let dolbyAV1 = StreamQualityTags(resolution: 2160, isDolbyVision: true, isAV1: true)
        let dolbyHEVC = StreamQualityTags(resolution: 2160, isDolbyVision: true, isHEVC: true)

        XCTAssertGreaterThan(
            HardwareAV1Ranking.boost(tags: hevc, resolution: 2160, preferHardware: true, av1Hardware: false),
            HardwareAV1Ranking.boost(tags: av1, resolution: 2160, preferHardware: true, av1Hardware: false)
        )
        XCTAssertEqual(
            HardwareAV1Ranking.boost(tags: av1, resolution: 2160, preferHardware: true, av1Hardware: false),
            -25_000
        )
        XCTAssertGreaterThan(
            HardwareAV1Ranking.boost(tags: av1, resolution: 2160, preferHardware: true, av1Hardware: true),
            HardwareAV1Ranking.boost(tags: hevc, resolution: 2160, preferHardware: true, av1Hardware: true)
        )
        XCTAssertGreaterThan(
            HardwareAV1Ranking.boost(tags: dolbyHEVC, resolution: 2160, preferHardware: true, av1Hardware: true),
            HardwareAV1Ranking.boost(tags: dolbyAV1, resolution: 2160, preferHardware: true, av1Hardware: true)
        )
    }

    func testPlaybackBudgetStaysGenerousWhenHeadroomIsPlentiful() {
        let fourGB: UInt64 = 4 * 1_073_741_824
        let available = 1_200 * 1_024 * 1_024
        let footprint: UInt64 = 400 * 1_024 * 1_024
        XCTAssertEqual(
            PlaybackCacheSettings.resolveAuto(
                physicalMemoryBytes: fourGB,
                availableMemoryBytes: available,
                footprintBytes: footprint
            ),
            PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        )
        XCTAssertEqual(
            PlaybackCacheProfile.resolveAutoSegments(
                physicalMemoryBytes: fourGB,
                availableMemoryBytes: available,
                footprintBytes: footprint
            ),
            25
        )
        XCTAssertEqual(
            CatalogImageCacheBudget.posterBytes(
                physicalMemoryBytes: 8 * 1_073_741_824,
                availableMemoryBytes: 1_200 * 1_024 * 1_024,
                allowsLiquidGlass: true
            ),
            140 * 1_024 * 1_024
        )
    }

    func testPlaybackBudgetStepsDownWhenTheProcessIsNearJetsam() {
        let eightGB: UInt64 = 8 * 1_073_741_824
        let available = 400 * 1_024 * 1_024
        let footprint: UInt64 = 1_200 * 1_024 * 1_024
        XCTAssertEqual(
            PlaybackCacheSettings.resolveAuto(
                physicalMemoryBytes: eightGB,
                availableMemoryBytes: available,
                footprintBytes: footprint
            ),
            PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        )
        XCTAssertEqual(
            PlaybackCacheProfile.resolveAutoSegments(
                physicalMemoryBytes: eightGB,
                availableMemoryBytes: available,
                footprintBytes: footprint
            ),
            4
        )
        XCTAssertLessThan(
            PlaybackCacheProfile.resolveAutoLeadSeconds(
                physicalMemoryBytes: eightGB,
                availableMemoryBytes: available,
                footprintBytes: footprint
            ),
            600
        )
    }
}
