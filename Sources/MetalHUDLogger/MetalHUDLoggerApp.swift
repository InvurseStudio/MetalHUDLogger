import AppKit
import SwiftUI

@main
struct MetalHUDLoggerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BenchmarkModel()

    var body: some Scene {
        WindowGroup("MetalHUD Logger") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 780)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
