import Foundation

/// Whether the next item can keep the HDMI mode already requested.
///
/// Apple TV switches the panel from the refresh rate and the dynamic range.
/// A different resolution or codec at the same rate and range does not need
/// another `preferredDisplayCriteria` write.
enum DisplayCriteriaContinuity {
    struct OutputMode: Equatable {
        var refreshRateMilliHz: Int
        var dynamicRange: String

        init(refreshRate: Float, dynamicRange: String) {
            refreshRateMilliHz = Int((refreshRate * 1_000).rounded())
            self.dynamicRange = dynamicRange
        }
    }

    static func shouldReuseHeldMode(current: OutputMode?, next: OutputMode) -> Bool {
        guard let current else { return false }
        return current == next
    }
}
