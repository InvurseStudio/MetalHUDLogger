import Foundation

struct FrameStats {
    var frameCount: Int
    var totalSeconds: Double
    var averageFPS: Double
    var low1: Double        // 1000 ÷ mean frame time of slowest 1% of frames
    var low01: Double       // 1000 ÷ mean frame time of slowest 0.1% of frames
    var averageFrameTimeMs: Double
    var maxFrameTimeMs: Double

    static func compute(_ frameTimesMs: [Double]) -> FrameStats? {
        guard !frameTimesMs.isEmpty else { return nil }
        let total = frameTimesMs.reduce(0, +)
        guard total > 0 else { return nil }
        let mean = total / Double(frameTimesMs.count)
        let slowestFirst = frameTimesMs.sorted(by: >)
        return FrameStats(frameCount: frameTimesMs.count,
                          totalSeconds: total / 1000,
                          averageFPS: 1000 / mean,
                          low1: low(slowestFirst, fraction: 0.01),
                          low01: low(slowestFirst, fraction: 0.001),
                          averageFrameTimeMs: mean,
                          maxFrameTimeMs: slowestFirst[0])
    }

    private static func low(_ slowestFirst: [Double], fraction: Double) -> Double {
        let count = max(1, Int((Double(slowestFirst.count) * fraction).rounded(.up)))
        let mean = slowestFirst.prefix(count).reduce(0, +) / Double(count)
        return mean > 0 ? 1000 / mean : 0
    }
}

func formatFPS(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.1f", value)
}
