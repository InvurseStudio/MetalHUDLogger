import Foundation

/// One frame reported by the Metal Performance HUD.
struct HUDFrame: Equatable {
    var frameTimeMs: Double   // present interval
    var gpuTimeMs: Double?    // nil when unknown (redacted log data)
}

/// One `metal-HUD:` log message (the HUD emits roughly one per second, covering many frames).
struct HUDSample {
    var process: String
    var pid: Int32
    var timestamp: Date
    var frameNumber: Int
    var memory: [Double]      // the two float fields after the frame number (memory, MB)
    var misses: Int
    var frames: [HUDFrame]
    /// macOS log privacy replaced the per-frame payload with `<private>`.
    var isRedacted: Bool
}

/// Parses `log stream --style ndjson` output.
///
/// libMTLHud logs with the format string `metal-HUD: %zu,%.2f,%.2f%s`:
/// `frameNumber, memory, memory` followed by the per-frame payload
/// `,interval0,gpu0,interval1,gpu1,…`. The payload is a `%s` argument, so unless
/// private log data is enabled macOS redacts it to `<private>`.
enum HUDParser {
    static let marker = "metal-HUD:"
    static let redactedToken = "<private>"

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    static func parseLogLine(_ line: String) -> HUDSample? {
        guard line.contains(marker),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["eventMessage"] as? String,
              let payload = parseMessage(message)
        else { return nil }

        let pid = (object["processID"] as? NSNumber)?.int32Value ?? 0
        let imagePath = object["processImagePath"] as? String ?? ""
        var process = (imagePath as NSString).lastPathComponent
        if WineProcess.isWineBinary(process), let windowsName = WineProcess.windowsName(pid: pid) {
            process = windowsName
        }
        if process.isEmpty { process = "pid \(pid)" }

        let timestamp = (object["timestamp"] as? String).flatMap(timestampFormatter.date(from:)) ?? Date()

        return HUDSample(process: process,
                         pid: pid,
                         timestamp: timestamp,
                         frameNumber: payload.frameNumber,
                         memory: payload.memory,
                         misses: payload.misses,
                         frames: payload.frames,
                         isRedacted: payload.isRedacted)
    }

    static func parseMessage(_ message: String)
        -> (frameNumber: Int, memory: [Double], misses: Int, frames: [HUDFrame], isRedacted: Bool)? {
        guard let range = message.range(of: marker) else { return nil }
        var body = String(message[range.upperBound...])
        let isRedacted = body.contains(redactedToken)
        body = body.replacingOccurrences(of: redactedToken, with: "")

        var numbers: [Double] = []
        for field in body.split(separator: ",") {
            let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let value = Double(trimmed) else { break }
            numbers.append(value)
        }
        guard let frameNumber = numbers.first else { return nil }

        let memory = Array(numbers.dropFirst().prefix(2))
        var tail = Array(numbers.dropFirst(3))
        // The payload is interval/GPU pairs; an odd leading value is treated as a frame-miss count.
        var misses = 0
        if tail.count % 2 == 1 {
            misses = Int(tail.removeFirst())
        }
        var frames: [HUDFrame] = []
        frames.reserveCapacity(tail.count / 2)
        var i = 0
        while i + 1 < tail.count {
            if tail[i] > 0 { frames.append(HUDFrame(frameTimeMs: tail[i], gpuTimeMs: tail[i + 1])) }
            i += 2
        }
        return (Int(frameNumber), memory, misses, frames, isRedacted)
    }
}
