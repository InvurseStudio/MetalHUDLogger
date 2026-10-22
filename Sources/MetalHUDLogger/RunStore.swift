import Foundation

struct RecordedFrame {
    let wallClock: Date
    let process: String
    let frame: Int
    let elapsed: Double       // seconds since recording start, at end of this frame
    let frameTimeMs: Double
    let gpuTimeMs: Double?
    let misses: Int           // HUD miss count for the batch, attributed to its first frame
    let approximate: Bool     // synthesized from per-second frame counts (log data redacted)
}

struct RunRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var game: String
    var label: String
    var seconds: Double
    var frameCount: Int
    var averageFPS: Double
    var low1: Double
    var low01: Double
    // Optional so history saved before temperatures were tracked still decodes.
    var cpuTempAverage: Double?
    var cpuTempMax: Double?
    var gpuTempAverage: Double?
    var gpuTempMax: Double?
    var csvPath: String
    var summaryPath: String
    var summary: String

    var fileURLs: [URL] { [csvPath, summaryPath].map { URL(fileURLWithPath: $0) } }
}

/// Run history persisted in UserDefaults.
enum RunStore {
    private static let key = "runHistory"

    static func load() -> [RunRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let runs = try? JSONDecoder().decode([RunRecord].self, from: data) else { return [] }
        return runs
    }

    static func save(_ runs: [RunRecord]) {
        if let data = try? JSONEncoder().encode(runs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Writes a run's CSV and `_summary.txt` into ~/Documents/MetalHUD Logs/.
enum RunWriter {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MetalHUD Logs", isDirectory: true)
    }

    static func save(frames: [RecordedFrame],
                     game: String,
                     label: String,
                     warmupSeconds: Int,
                     duration: RunDuration,
                     start: Date,
                     temperatures: TemperatureStats) throws -> RunRecord {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        var baseName = "\(stampFormatter.string(from: start)) \(game)"
        if !label.isEmpty { baseName += " - \(label)" }
        baseName = sanitize(baseName)

        let csvURL = directory.appendingPathComponent(baseName + ".csv")
        let summaryURL = directory.appendingPathComponent(baseName + "_summary.txt")

        try csv(for: frames).write(to: csvURL, atomically: true, encoding: .utf8)

        let warmup = Double(warmupSeconds)
        var analysed = frames.filter { $0.elapsed > warmup }
        let warmupLongerThanRun = analysed.isEmpty
        if warmupLongerThanRun { analysed = frames }
        let stats = FrameStats.compute(analysed.map(\.frameTimeMs))
        let recordedSeconds = frames.last?.elapsed ?? 0
        let gpuTimes = analysed.compactMap(\.gpuTimeMs)

        var lines = [
            "MetalHUD Logger — run summary",
            "",
            "Game:              \(game)",
            "Label:             \(label.isEmpty ? "—" : label)",
            "Started:           \(start.formatted(date: .long, time: .standard))",
            "Duration setting:  \(duration.label)",
            "Warm-up excluded:  \(warmupSeconds) s (\(frames.count - analysed.count) frames)",
            "Recorded:          \(String(format: "%.1f", recordedSeconds)) s, \(frames.count) frames",
            "Analysed:          \(String(format: "%.1f", stats?.totalSeconds ?? 0)) s, \(analysed.count) frames",
            "",
            "Average FPS:       \(formatFPS(stats?.averageFPS))",
            "1% low:            \(formatFPS(stats?.low1))",
            "0.1% low:          \(formatFPS(stats?.low01))",
            "Avg frame time:    \(String(format: "%.2f", stats?.averageFrameTimeMs ?? 0)) ms",
            "Max frame time:    \(String(format: "%.2f", stats?.maxFrameTimeMs ?? 0)) ms",
            "Avg GPU time:      \(gpuTimes.isEmpty ? "n/a" : String(format: "%.2f ms", gpuTimes.reduce(0, +) / Double(gpuTimes.count)))",
            "Frame misses:      \(analysed.map(\.misses).reduce(0, +))",
            "",
            "CPU temp:          avg \(formatTemperature(temperatures.cpuAverage)), max \(formatTemperature(temperatures.cpuMax))",
            "GPU temp:          avg \(formatTemperature(temperatures.gpuAverage)), max \(formatTemperature(temperatures.gpuMax))",
        ]
        if frames.contains(where: \.approximate) {
            lines.append("")
            lines.append("Note: per-frame HUD data was redacted by macOS log privacy. Frame times are")
            lines.append("per-second averages from the HUD frame counter, so the lows are approximate.")
        }
        if warmupLongerThanRun {
            lines.append("")
            lines.append("Note: the warm-up was longer than the recording, so stats use all frames.")
        }
        lines.append("")
        lines.append("CSV: \(csvURL.lastPathComponent)")
        let summary = lines.joined(separator: "\n") + "\n"
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)

        return RunRecord(date: start,
                         game: game,
                         label: label,
                         seconds: stats?.totalSeconds ?? 0,
                         frameCount: analysed.count,
                         averageFPS: stats?.averageFPS ?? 0,
                         low1: stats?.low1 ?? 0,
                         low01: stats?.low01 ?? 0,
                         cpuTempAverage: temperatures.cpuAverage,
                         cpuTempMax: temperatures.cpuMax,
                         gpuTempAverage: temperatures.gpuAverage,
                         gpuTempMax: temperatures.gpuMax,
                         csvPath: csvURL.path,
                         summaryPath: summaryURL.path,
                         summary: summary)
    }

    private static func csv(for frames: [RecordedFrame]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = .current

        var out = "wall_clock,process,frame,elapsed_s,frame_time_ms,gpu_time_ms,misses,fps\n"
        out.reserveCapacity(frames.count * 90)
        for f in frames {
            out += iso.string(from: f.wallClock)
            out += "," + csvField(f.process)
            out += ",\(f.frame)"
            out += String(format: ",%.4f,%.3f,", f.elapsed, f.frameTimeMs)
            out += f.gpuTimeMs.map { String(format: "%.3f,", $0) } ?? ","
            out += "\(f.misses)"
            out += String(format: ",%.2f\n", 1000 / f.frameTimeMs)
        }
        return out
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
