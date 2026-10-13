import Foundation

/// Toggles Metal HUD logging for apps launched afterwards via `launchctl setenv/unsetenv`.
enum HUDEnvironment {
    static let variables = ["MTL_HUD_ENABLED", "MTL_HUD_LOG_ENABLED"]
    static let steamLaunchOption = "MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1 %command%"

    static var isEnabled: Bool {
        variables.allSatisfy { launchctl(["getenv", $0]).output == "1" }
    }

    @discardableResult
    static func enable() -> Bool {
        variables.map { launchctl(["setenv", $0, "1"]).status == 0 }.allSatisfy { $0 }
    }

    @discardableResult
    static func disable() -> Bool {
        variables.map { launchctl(["unsetenv", $0]).status == 0 }.allSatisfy { $0 }
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, output)
    }
}
