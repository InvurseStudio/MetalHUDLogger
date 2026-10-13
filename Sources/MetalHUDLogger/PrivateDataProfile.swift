import Foundation

/// Configuration profile (com.apple.system.logging) that turns off `<private>` redaction in the
/// unified log, which libMTLHud needs for its per-frame payload. Applies system-wide; remove it in
/// System Settings › General › Device Management when no longer needed.
enum PrivateDataProfile {
    static let fileName = "MetalHUD Logger Private Log Data.mobileconfig"

    static func write() throws -> URL {
        try FileManager.default.createDirectory(at: RunWriter.directory, withIntermediateDirectories: true)
        let url = RunWriter.directory.appendingPathComponent(fileName)
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.invursestudio.metalhudlogger.privatedata",
            "PayloadUUID": "9C3E1F7A-6B52-4D8E-A1F0-3B7C2D4E5F61",
            "PayloadDisplayName": "MetalHUD Logger – Private Log Data",
            "PayloadDescription": "Shows private data in the unified log so MetalHUD Logger can read per-frame Metal HUD timings. Affects all log messages on this Mac; remove this profile to restore redaction.",
            "PayloadScope": "System",
            "PayloadContent": [[
                "PayloadType": "com.apple.system.logging",
                "PayloadVersion": 1,
                "PayloadIdentifier": "com.invursestudio.metalhudlogger.privatedata.logging",
                "PayloadUUID": "4A8D2B6C-1E3F-4970-8C5D-7F2A9B1E0D34",
                "PayloadDisplayName": "Unified Log Private Data",
                "System": ["Enable-Private-Data": true],
            ]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        return url
    }
}
