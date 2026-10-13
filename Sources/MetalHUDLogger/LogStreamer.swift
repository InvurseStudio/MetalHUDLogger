import Foundation

/// Runs `/usr/bin/log stream` as a child process and delivers parsed HUD samples on the main queue.
final class LogStreamer {
    var onSamples: (([HUDSample]) -> Void)?
    var onStatus: ((String) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "MetalHUDLogger.logstream")
    private var wantsRunning = false

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        killOrphanedStreams()
        launch()
    }

    /// A force-quit app leaves its `log stream` child running (reparented to launchd) until the
    /// next matching message breaks its pipe; clean those up on launch.
    private func killOrphanedStreams() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", "1", "-f", "^/usr/bin/log stream --style ndjson .*metal-HUD:"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    func stop() {
        wantsRunning = false
        process?.terminate()
        process = nil
    }

    private func launch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--level", "info",
                             "--predicate", "eventMessage CONTAINS \"metal-HUD:\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.wantsRunning else { return }
                self.onStatus?("log stream exited — restarting…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if self.wantsRunning { self.launch() }
                }
            }
        }

        do {
            try process.run()
            self.process = process
            queue.async { self.buffer.removeAll() }
            onStatus?("Listening for metal-HUD logs")
        } catch {
            onStatus?("Couldn’t start log stream: \(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        var samples: [HUDSample] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8),
               let sample = HUDParser.parseLogLine(line) {
                samples.append(sample)
            }
        }
        guard !samples.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onSamples?(samples) }
    }
}
