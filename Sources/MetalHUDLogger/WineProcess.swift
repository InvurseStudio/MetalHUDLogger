import Darwin
import Foundation

/// Wine games all run from the same `wine` / `wine-preloader` binary, but Wine rewrites argv[0]
/// to the Windows executable path (e.g. `C:\Program Files (x86)\Diablo IV\Diablo IV.exe`).
/// Only accessed from the log-stream queue.
enum WineProcess {
    private static var cache: [Int32: String] = [:]

    static func isWineBinary(_ name: String) -> Bool {
        name.lowercased().hasPrefix("wine")
    }

    /// The game's Windows executable name without `.exe`, or nil if it can't be read.
    static func windowsName(pid: Int32) -> String? {
        if let cached = cache[pid] { return cached }
        guard let argv0 = argv0(pid: pid) else { return nil }
        let file = argv0.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? argv0
        guard file.lowercased().hasSuffix(".exe") else { return nil }
        let name = String(file.dropLast(4))
        cache[pid] = name
        return name
    }

    /// Reads argv[0] via KERN_PROCARGS2: `int argc`, exec path, NUL padding, then argv.
    private static func argv0(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(decoding: buffer[start..<index], as: UTF8.self)
    }
}
