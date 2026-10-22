import SwiftUI

// MARK: - Theme

enum Theme {
    static let background = Color(red: 0.055, green: 0.059, blue: 0.075)
    static let surface = Color(red: 0.090, green: 0.098, blue: 0.122)
    static let surfaceRaised = Color(red: 0.125, green: 0.137, blue: 0.169)
    static let border = Color.white.opacity(0.07)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)

    static let accent = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let live = Color(red: 0.30, green: 0.85, blue: 0.60)
    static let warning = Color(red: 1.0, green: 0.66, blue: 0.25)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.40)

    static let cornerRadius: CGFloat = 14
}

private struct CardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.border))
    }
}

private extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

private struct SubtleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surfaceRaised.opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            .contentShape(Rectangle())
    }
}

private struct RecordButtonStyle: ButtonStyle {
    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isRecording ? Theme.surfaceRaised : Theme.danger)
                .opacity(configuration.isPressed ? 0.75 : 1))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isRecording ? Theme.danger.opacity(0.6) : .clear))
            .contentShape(Rectangle())
    }
}

private struct SectionTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
    }
}

// MARK: - Content

struct ContentView: View {
    @EnvironmentObject private var model: BenchmarkModel
    @State private var selectedRunID: RunRecord.ID?
    @State private var runPendingDelete: RunRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            topBar
            if model.displayedGameIsRedacted { redactionBanner }
            tiles
            HStack(alignment: .top, spacing: 14) {
                temperaturePanel
                recordingPanel
            }
            .fixedSize(horizontal: false, vertical: true)
            historySection
            footer
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .padding(.top, 4)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text("MetalHUD Logger")
                    .font(.title3.weight(.semibold))
            }
            .fixedSize()

            Divider().frame(height: 20).overlay(Theme.border)

            Picker("Game", selection: $model.selection) {
                Text("Auto" + (model.autoGame.map { " (\($0))" } ?? "")).tag("")
                if !model.games.isEmpty { Divider() }
                ForEach(model.games) { game in
                    Text(game.isActive ? game.name : "\(game.name) — idle").tag(game.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 210)
            .disabled(model.isRecording)

            statusPill

            Spacer(minLength: 8)

            Toggle(isOn: Binding(get: { model.hudEnabled }, set: { model.setHUDLogging($0) })) {
                Text("HUD logging")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(model.hudEnabled ? Theme.textPrimary : Theme.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            .tint(Theme.live)
            .help("Sets MTL_HUD_ENABLED / MTL_HUD_LOG_ENABLED for apps launched from now on.")

            Button {
                model.copySteamLaunchOption()
            } label: {
                Label("Steam Launch Option", systemImage: "doc.on.doc")
            }
            .buttonStyle(SubtleButtonStyle())
            .fixedSize()
            .help("Copy: \(HUDEnvironment.steamLaunchOption)")
        }
        .frame(height: 36)
    }

    private var statusPill: some View {
        let live = model.displayedGame != nil
        return HStack(spacing: 6) {
            Circle()
                .fill(live ? Theme.live : Theme.warning)
                .frame(width: 7, height: 7)
                .shadow(color: (live ? Theme.live : Theme.warning).opacity(0.8), radius: 4)
            Text(model.games.isEmpty ? "\(model.streamStatus) — no games detected yet" : model.streamStatus)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.border))
        .help(model.streamStatus)
    }

    private var redactionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .font(.title3)
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Per-frame data is redacted by macOS")
                    .font(.callout.weight(.semibold))
                Text("Showing per-second averages from the frame counter — 1% / 0.1% lows are approximate and GPU time is unavailable.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Enable Per-Frame Data…") { model.openPrivateDataProfile() }
                .buttonStyle(SubtleButtonStyle())
                .help("Opens a configuration profile that turns off private-data redaction in the unified log (system-wide). Install it in System Settings › Device Management; remove it there to undo.")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.warning.opacity(0.25)))
    }

    // MARK: Tiles

    private var tiles: some View {
        HStack(spacing: 14) {
            StatTile(title: "Live FPS", value: formatFPS(model.liveFPS), caption: "Last second", tint: Theme.live)
            StatTile(title: "Average FPS", value: formatFPS(model.stats?.averageFPS), caption: model.statsCaption, tint: Theme.accent)
            StatTile(title: "1% Low", value: formatFPS(model.stats?.low1), caption: model.statsCaption, tint: Theme.warning)
            StatTile(title: "0.1% Low", value: formatFPS(model.stats?.low01), caption: model.statsCaption, tint: Theme.danger)
        }
    }

    // MARK: Temperatures

    private var temperaturePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionTitle(title: "Temperatures", systemImage: "thermometer.medium")
                Spacer()
                Text(model.temperatureCaption)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            if model.temperatureAvailable {
                HStack(spacing: 14) {
                    TemperatureGauge(title: "CPU",
                                     current: model.temperature?.cpu,
                                     average: model.temperatureStats?.cpuAverage,
                                     maximum: model.temperatureStats?.cpuMax,
                                     tint: Theme.accent)
                    TemperatureGauge(title: "GPU",
                                     current: model.temperature?.gpu,
                                     average: model.temperatureStats?.gpuAverage,
                                     maximum: model.temperatureStats?.gpuMax,
                                     tint: Theme.warning)
                }
                .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "thermometer.medium.slash")
                        .font(.title)
                        .foregroundStyle(Theme.textTertiary)
                    Text("Couldn’t read temperature sensors on this Mac.")
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    // MARK: Recording

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Benchmark Run", systemImage: "record.circle")

            VStack(alignment: .leading, spacing: 5) {
                FieldLabel("Label")
                TextField("e.g. 1440p High, MetalFX Quality", text: $model.label)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                    .disabled(model.isRecording)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel("Duration")
                    Picker("Duration", selection: $model.duration) {
                        ForEach(RunDuration.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel("Warm-up")
                    Picker("Warm-up", selection: $model.warmupSeconds) {
                        ForEach(BenchmarkModel.warmupOptions, id: \.self) { seconds in
                            Text(seconds == 0 ? "None" : "\(seconds) s").tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            .disabled(model.isRecording)

            Spacer(minLength: 0)

            if model.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Theme.danger).frame(width: 7, height: 7)
                    Text(model.recordingStatus)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                }
            }

            Button {
                model.toggleRecording()
            } label: {
                Label(model.isRecording ? "Stop Recording" : "Start Recording",
                      systemImage: model.isRecording ? "stop.fill" : "record.circle.fill")
            }
            .buttonStyle(RecordButtonStyle(isRecording: model.isRecording))

            HStack(spacing: 5) {
                Image(systemName: model.hotKeyRegistered ? "keyboard" : "exclamationmark.triangle")
                Text(model.hotKeyRegistered
                     ? "⌃⌥R toggles recording, even in fullscreen games."
                     : "Couldn’t register ⌃⌥R (another app may be using it).")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
        }
        .frame(width: 280, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    // MARK: History

    private var selectedRun: RunRecord? {
        model.history.first { $0.id == selectedRunID }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle(title: "Run History", systemImage: "clock.arrow.circlepath")
                Text("\(model.history.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.surfaceRaised))
                Spacer()
                Group {
                    Button { selectedRun.map(model.revealInFinder) } label: { Image(systemName: "magnifyingglass") }
                        .help("Show in Finder")
                        .disabled(selectedRun == nil)
                    Button { selectedRun.map(model.copySummary) } label: { Image(systemName: "doc.on.clipboard") }
                        .help("Copy Summary")
                        .disabled(selectedRun == nil)
                    Button { runPendingDelete = selectedRun } label: { Image(systemName: "trash") }
                        .help("Delete…")
                        .disabled(selectedRun == nil)
                    Button { model.openLogsFolder() } label: { Label("Logs Folder", systemImage: "folder") }
                        .help("Open Logs Folder")
                }
                .buttonStyle(SubtleButtonStyle())
            }

            Table(model.history, selection: $selectedRunID) {
                TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                TableColumn("Game", value: \.game)
                TableColumn("Label", value: \.label)
                TableColumn("Length") { Text(String(format: "%.1f s", $0.seconds)).monospacedDigit() }
                    .width(70)
                TableColumn("Avg FPS") { Text(formatFPS($0.averageFPS)).monospacedDigit().foregroundStyle(Theme.accent) }
                    .width(70)
                TableColumn("1% Low") { Text(formatFPS($0.low1)).monospacedDigit().foregroundStyle(Theme.warning) }
                    .width(70)
                TableColumn("0.1% Low") { Text(formatFPS($0.low01)).monospacedDigit().foregroundStyle(Theme.danger) }
                    .width(70)
                TableColumn("CPU °C") { Text(formatTemperatureRange($0.cpuTempAverage, $0.cpuTempMax)).monospacedDigit() }
                    .width(70)
                TableColumn("GPU °C") { Text(formatTemperatureRange($0.gpuTempAverage, $0.gpuTempMax)).monospacedDigit() }
                    .width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: RunRecord.ID.self) { ids in
                if let run = model.history.first(where: { ids.contains($0.id) }) {
                    Button("Show in Finder") { model.revealInFinder(run) }
                    Button("Copy Summary") { model.copySummary(run) }
                    Divider()
                    Button("Delete…") { runPendingDelete = run }
                }
            }
            .overlay {
                if model.history.isEmpty {
                    Text("No runs yet — recorded benchmarks will appear here.")
                        .font(.callout)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(minHeight: 150)
        }
        .card(padding: 14)
        .confirmationDialog("Delete this run?",
                            isPresented: Binding(get: { runPendingDelete != nil },
                                                 set: { if !$0 { runPendingDelete = nil } }),
                            presenting: runPendingDelete) { run in
            Button("Remove from History") { model.delete(run, trashFiles: false) }
            Button("Remove and Move Files to Trash", role: .destructive) { model.delete(run, trashFiles: true) }
            Button("Cancel", role: .cancel) {}
        } message: { run in
            Text("\(run.game)\(run.label.isEmpty ? "" : " — \(run.label)"), \(run.date.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let notice = model.notice {
                Image(systemName: "info.circle")
                Text(notice).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .frame(height: 14)
    }
}

// MARK: - Components

private struct StatTile: View {
    let title: String
    let value: String
    let caption: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 12)
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(value)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value == "—" ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(caption)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
        .overlay(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 40)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .allowsHitTesting(false)
        }
    }
}

/// Current temperature with the average and peak over the caption's window. The bar spans 20–110 °C.
private struct TemperatureGauge: View {
    let title: String
    let current: Double?
    let average: Double?
    let maximum: Double?
    let tint: Color

    private static let range = 20.0...110.0

    private static func fraction(_ celsius: Double) -> CGFloat {
        CGFloat((min(max(celsius, range.lowerBound), range.upperBound) - range.lowerBound)
                / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 12)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(formatTemperature(current))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(current == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.background)
                    if let current {
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0.6), tint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geometry.size.width * Self.fraction(current)))
                    }
                    if let maximum {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.textPrimary)
                            .frame(width: 2, height: 12)
                            .offset(x: geometry.size.width * Self.fraction(maximum) - 1)
                    }
                }
            }
            .frame(height: 6)
            .help("Bar spans 20–110 °C; the tick marks the maximum.")

            Spacer(minLength: 0)

            HStack(spacing: 18) {
                summary("Avg", average)
                summary("Max", maximum)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }

    private func summary(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            FieldLabel(label)
            Text(formatTemperature(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Theme.textTertiary : Theme.textPrimary)
        }
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.textTertiary)
    }
}
