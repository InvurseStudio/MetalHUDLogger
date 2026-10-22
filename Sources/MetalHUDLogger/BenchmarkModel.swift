import AppKit
import Foundation

struct DetectedGame: Identifiable, Equatable {
    let name: String
    var pid: Int32
    var firstSeen: Date
    var lastSeen: Date
    /// Per-frame payload is hidden by log privacy; only per-second averages are available.
    var isRedacted: Bool
    var id: String { name }
    var isActive: Bool { Date().timeIntervalSince(lastSeen) < 5 }
}

enum RunDuration: Int, CaseIterable, Identifiable {
    case manual = 0, s30 = 30, s60 = 60, s90 = 90, s120 = 120, s180 = 180
    var id: Int { rawValue }
    var label: String { self == .manual ? "Manual" : "\(rawValue) s" }
}

/// All app state. Used from the main thread only.
final class BenchmarkModel: ObservableObject {
    static let liveCapacity = 900
    static let warmupOptions = [0, 5, 10, 15, 30, 60]

    // Detection / selection ("" = Auto)
    @Published private(set) var games: [DetectedGame] = []
    @Published var selection = "" { didSet { refreshDisplayedGame() } }
    @Published private(set) var displayedGame: String?
    var displayedGameIsRedacted: Bool { games.first { $0.name == displayedGame }?.isRedacted ?? false }

    // Live data
    @Published private(set) var liveFrameTimes: [Double] = []   // ms, most recent last
    @Published private(set) var liveFPS: Double?
    @Published private(set) var stats: FrameStats?
    @Published private(set) var statsCaption = "Last 900 frames"

    // Temperatures
    @Published private(set) var temperature: TemperatureSample?
    @Published private(set) var temperatureStats: TemperatureStats?
    @Published private(set) var temperatureCaption = "Last 2 minutes"
    @Published private(set) var temperatureAvailable = true

    // Recording
    @Published var label = ""
    @Published var duration: RunDuration = .manual
    @Published var warmupSeconds = 0
    @Published private(set) var isRecording = false
    @Published private(set) var recordingGame: String?
    @Published private(set) var recordingElapsed: Double = 0

    // Misc
    @Published var history: [RunRecord] = [] { didSet { RunStore.save(history) } }
    @Published private(set) var streamStatus = "Starting log stream…"
    @Published private(set) var hudEnabled = false
    @Published var notice: String?
    private(set) var hotKeyRegistered = false

    private var recorded: [RecordedFrame] = []
    private var recordingStart = Date()
    private var runWarmup = 0
    private var runDuration: RunDuration = .manual
    private var runLabel = ""
    private var lastCounters: [Int32: (frame: Int, time: Date)] = [:]
    private let streamer = LogStreamer()
    private var hotKey: GlobalHotKey?

    static let temperatureWindow: TimeInterval = 120
    private var recentTemperatures: [(time: Date, sample: TemperatureSample)] = []
    private var runTemperatures: [(elapsed: Double, sample: TemperatureSample)] = []
    private var temperatureSensor: TemperatureSensor?
    private let temperatureQueue = DispatchQueue(label: "TemperatureSensor", qos: .utility)
    private var temperatureTimer: Timer?

    init() {
        history = RunStore.load()
        hudEnabled = HUDEnvironment.isEnabled

        streamer.onSamples = { [weak self] in self?.ingest($0) }
        streamer.onStatus = { [weak self] in self?.streamStatus = $0 }
        streamer.start()

        hotKey = GlobalHotKey { [weak self] in self?.toggleRecording() }
        hotKeyRegistered = hotKey != nil

        startTemperatureSampling()

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.streamer.stop()
        }
    }

    // MARK: Game selection

    /// Most recently detected game that is still sending data; otherwise the last one heard from.
    var autoGame: String? {
        let active = games.filter(\.isActive)
        if !active.isEmpty { return active.max { $0.firstSeen < $1.firstSeen }?.name }
        return games.max { $0.lastSeen < $1.lastSeen }?.name
    }

    private var resolvedSelection: String? { selection.isEmpty ? autoGame : selection }

    private func refreshDisplayedGame() {
        let target = recordingGame ?? resolvedSelection
        guard target != displayedGame else { return }
        displayedGame = target
        liveFrameTimes = []
        liveFPS = nil
        updateStats()
    }

    private func noteGame(_ sample: HUDSample) {
        let now = Date()
        if let index = games.firstIndex(where: { $0.name == sample.process }) {
            games[index].lastSeen = now
            games[index].pid = sample.pid
            games[index].isRedacted = sample.isRedacted
        } else {
            games.append(DetectedGame(name: sample.process, pid: sample.pid, firstSeen: now, lastSeen: now,
                                      isRedacted: sample.isRedacted))
            games.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: Ingest

    /// Drops duplicate messages (libMTLHud logs every line twice) and, when the per-frame payload
    /// is redacted, synthesizes evenly spaced frames from the frame-counter delta since the last message.
    private func normalize(_ sample: HUDSample) -> HUDSample? {
        let previous = lastCounters[sample.pid]
        if let previous, sample.frameNumber == previous.frame { return nil }
        lastCounters[sample.pid] = (sample.frameNumber, sample.timestamp)

        guard sample.isRedacted, sample.frames.isEmpty, let previous else { return sample }
        let count = sample.frameNumber - previous.frame
        let seconds = sample.timestamp.timeIntervalSince(previous.time)
        guard count > 0, seconds > 0, seconds < 3 else { return sample }
        var synthesized = sample
        synthesized.frames = Array(repeating: HUDFrame(frameTimeMs: seconds * 1000 / Double(count), gpuTimeMs: nil),
                                   count: count)
        return synthesized
    }

    private func ingest(_ rawSamples: [HUDSample]) {
        let samples = rawSamples.compactMap(normalize)
        samples.forEach(noteGame)
        refreshDisplayedGame()

        var frameTimes = liveFrameTimes
        for sample in samples where !sample.frames.isEmpty {
            if isRecording {
                if recordingGame == nil {
                    recordingGame = sample.process
                    refreshDisplayedGame()
                    frameTimes = liveFrameTimes
                }
                if sample.process == recordingGame { appendRecorded(sample) }
            }
            if sample.process == displayedGame {
                frameTimes.append(contentsOf: sample.frames.map(\.frameTimeMs))
            }
        }
        if frameTimes.count > Self.liveCapacity { frameTimes.removeFirst(frameTimes.count - Self.liveCapacity) }
        liveFrameTimes = frameTimes
        liveFPS = Self.fpsOverLastSecond(frameTimes)

        checkAutoStop()
        updateStats()
    }

    private func appendRecorded(_ sample: HUDSample) {
        // The log timestamp marks the end of the batch; back-date each frame from it.
        let batchSeconds = sample.frames.reduce(0) { $0 + $1.frameTimeMs } / 1000
        var wallClock = sample.timestamp.addingTimeInterval(-batchSeconds)
        // The frame counter in the message is taken as the number of the batch's last frame.
        let firstFrame = sample.frameNumber - sample.frames.count + 1
        for (i, frame) in sample.frames.enumerated() {
            let seconds = frame.frameTimeMs / 1000
            wallClock += seconds
            recordingElapsed += seconds
            recorded.append(RecordedFrame(wallClock: wallClock,
                                          process: sample.process,
                                          frame: firstFrame + i,
                                          elapsed: recordingElapsed,
                                          frameTimeMs: frame.frameTimeMs,
                                          gpuTimeMs: frame.gpuTimeMs,
                                          misses: i == 0 ? sample.misses : 0,
                                          approximate: sample.isRedacted))
        }
    }

    private static func fpsOverLastSecond(_ frameTimesMs: [Double]) -> Double? {
        var total = 0.0, count = 0
        for frameTimeMs in frameTimesMs.reversed() {
            total += frameTimeMs
            count += 1
            if total >= 1000 { break }
        }
        return total > 0 ? Double(count) * 1000 / total : nil
    }

    private func updateStats() {
        if isRecording {
            let warmup = Double(runWarmup)
            if recordingElapsed == 0 {
                statsCaption = "Recording — waiting for frames"
                stats = nil
            } else if recordingElapsed <= warmup {
                statsCaption = "Warming up"
                stats = nil
            } else {
                statsCaption = displayedGameIsRedacted ? "This run — per-second avg." : "This run (excl. warm-up)"
                stats = FrameStats.compute(recorded.lazy.filter { $0.elapsed > warmup }.map(\.frameTimeMs))
            }
        } else {
            statsCaption = displayedGameIsRedacted ? "Per-second averages" : "Last \(Self.liveCapacity) frames"
            stats = FrameStats.compute(liveFrameTimes)
        }
    }

    // MARK: Temperatures

    private func startTemperatureSampling() {
        // Key discovery walks every SMC key, so keep it (and the reads) off the main thread.
        temperatureQueue.async { [weak self] in
            let sensor = TemperatureSensor()
            DispatchQueue.main.async {
                guard let self else { return }
                self.temperatureSensor = sensor
                self.temperatureAvailable = sensor.isAvailable
                guard sensor.isAvailable else { return }
                self.temperatureTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.sampleTemperature()
                }
                self.sampleTemperature()
            }
        }
    }

    private func sampleTemperature() {
        guard let sensor = temperatureSensor else { return }
        temperatureQueue.async { [weak self] in
            let sample = sensor.read()
            DispatchQueue.main.async { self?.ingestTemperature(sample) }
        }
    }

    private func ingestTemperature(_ sample: TemperatureSample) {
        let now = Date()
        temperature = sample
        recentTemperatures.append((now, sample))
        recentTemperatures.removeAll { now.timeIntervalSince($0.time) > Self.temperatureWindow }
        // Samples before the first frame arrives can't be placed relative to the warm-up.
        if isRecording, recordingElapsed > 0 { runTemperatures.append((recordingElapsed, sample)) }
        updateTemperatureStats()
    }

    private func updateTemperatureStats() {
        if isRecording {
            let warmup = Double(runWarmup)
            let measured = runTemperatures.filter { $0.elapsed > warmup }
            temperatureCaption = measured.isEmpty ? "Waiting for this run" : "This run (excl. warm-up)"
            temperatureStats = measured.isEmpty ? nil : TemperatureStats.compute(measured.map(\.sample))
        } else {
            temperatureCaption = "Last 2 minutes"
            temperatureStats = recentTemperatures.isEmpty ? nil : TemperatureStats.compute(recentTemperatures.map(\.sample))
        }
    }

    private func checkAutoStop() {
        guard isRecording, runDuration != .manual else { return }
        let target = Double(runWarmup + runDuration.rawValue)
        guard recordingElapsed >= target else { return }
        recorded.removeAll { $0.elapsed > target + 1e-9 }
        recordingElapsed = recorded.last?.elapsed ?? 0
        stopRecording()
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        recorded = []
        recordingElapsed = 0
        runTemperatures = []
        recordingStart = Date()
        runWarmup = warmupSeconds
        runDuration = duration
        runLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        recordingGame = resolvedSelection   // nil → lock onto the first game that sends frames
        isRecording = true
        notice = nil
        NSSound(named: "Glass")?.play()
        refreshDisplayedGame()
        updateStats()
        updateTemperatureStats()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        NSSound(named: "Submarine")?.play()

        let frames = recorded
        let game = recordingGame
        // Same warm-up rule as the frame stats: fall back to everything if the warm-up covered the run.
        let lastElapsed = frames.last?.elapsed ?? 0
        let inRun = runTemperatures.filter { $0.elapsed <= lastElapsed + 1 }
        let measured = inRun.filter { $0.elapsed > Double(runWarmup) }
        let temperatures = TemperatureStats.compute((measured.isEmpty ? inRun : measured).map(\.sample))
        recorded = []
        runTemperatures = []
        recordingGame = nil
        refreshDisplayedGame()
        updateStats()
        updateTemperatureStats()

        guard let game, !frames.isEmpty else {
            notice = "Recording stopped — no frames were captured."
            return
        }
        do {
            let run = try RunWriter.save(frames: frames, game: game, label: runLabel,
                                         warmupSeconds: runWarmup, duration: runDuration,
                                         start: recordingStart, temperatures: temperatures)
            history.insert(run, at: 0)
            notice = "Saved \(URL(fileURLWithPath: run.csvPath).lastPathComponent)"
        } catch {
            notice = "Couldn’t save run: \(error.localizedDescription)"
        }
    }

    var recordingStatus: String {
        guard isRecording else { return "" }
        let game = recordingGame ?? "first game to send frames"
        if recordingElapsed == 0 { return "Waiting for \(game)…" }
        if recordingElapsed < Double(runWarmup) {
            return String(format: "Warming up %.0f / %d s", recordingElapsed, runWarmup)
        }
        let measured = recordingElapsed - Double(runWarmup)
        if runDuration == .manual { return String(format: "Recording %.1f s", measured) }
        return String(format: "Recording %.0f / %d s", measured, runDuration.rawValue)
    }

    // MARK: HUD environment

    func setHUDLogging(_ enabled: Bool) {
        let ok = enabled ? HUDEnvironment.enable() : HUDEnvironment.disable()
        hudEnabled = HUDEnvironment.isEnabled
        if !ok {
            notice = "launchctl failed to \(enabled ? "set" : "unset") the HUD variables."
        } else if enabled {
            notice = "HUD logging enabled for apps launched from now on — relaunch the game (and Steam)."
        } else {
            notice = "HUD logging disabled for newly launched apps."
        }
    }

    /// Writes a configuration profile that disables log redaction (so the per-frame payload is
    /// visible) and opens it. The user installs it in System Settings › Device Management.
    func openPrivateDataProfile() {
        do {
            let url = try PrivateDataProfile.write()
            NSWorkspace.shared.open(url)
            if let settings = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") {
                NSWorkspace.shared.open(settings)
            }
            notice = "Install “MetalHUD Logger – Private Log Data” in System Settings › Device Management, then relaunch the game."
        } catch {
            notice = "Couldn’t write profile: \(error.localizedDescription)"
        }
    }

    func copySteamLaunchOption() {
        copyToPasteboard(HUDEnvironment.steamLaunchOption)
        notice = "Copied Steam launch option: \(HUDEnvironment.steamLaunchOption)"
    }

    // MARK: History

    func revealInFinder(_ run: RunRecord) {
        let existing = run.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            notice = "The files for this run no longer exist."
            NSWorkspace.shared.open(RunWriter.directory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    func openLogsFolder() {
        try? FileManager.default.createDirectory(at: RunWriter.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(RunWriter.directory)
    }

    func copySummary(_ run: RunRecord) {
        let text = (try? String(contentsOfFile: run.summaryPath, encoding: .utf8)) ?? run.summary
        copyToPasteboard(text)
        notice = "Copied summary for \(run.game)."
    }

    func delete(_ run: RunRecord, trashFiles: Bool) {
        history.removeAll { $0.id == run.id }
        guard trashFiles else { return }
        for url in run.fileURLs where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
