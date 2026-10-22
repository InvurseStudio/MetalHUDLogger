import Foundation
import IOKit

/// One CPU / GPU temperature reading, in °C. Each value is the mean of that unit's die sensors.
struct TemperatureSample {
    var cpu: Double?
    var gpu: Double?
}

/// Reads die temperatures from the System Management Controller (AppleSMC). No root needed.
///
/// Sensor keys differ per chip, so they are found by prefix rather than from a fixed table:
/// Apple silicon reports `flt` keys `Tp*` / `Te*` / `Ts*` (CPU core clusters) and `Tg*` (GPU);
/// Intel Macs report `sp78` keys `TC<n>*` (CPU) and `TG<n>*` (GPU).
final class TemperatureSensor {
    private struct Key {
        let code: UInt32
        let info: SMCKeyInfo
    }

    private var connection: io_connect_t = 0
    private var cpuKeys: [Key] = []
    private var gpuKeys: [Key] = []

    var isAvailable: Bool { !cpuKeys.isEmpty || !gpuKeys.isEmpty }

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return }
        discoverKeys()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func read() -> TemperatureSample {
        TemperatureSample(cpu: mean(cpuKeys), gpu: mean(gpuKeys))
    }

    // MARK: Discovery

    private func discoverKeys() {
        guard let countKey = keyInfo(fourCC("#KEY")), let countBytes = readBytes(fourCC("#KEY"), countKey)
        else { return }
        let count = countBytes.reduce(0) { $0 << 8 | Int($1) }

        for index in 0..<count {
            var input = SMCParam()
            input.data8 = SMCCommand.keyAtIndex
            input.data32 = UInt32(index)
            guard let output = call(input) else { continue }
            let name = string(output.key)
            guard name.hasPrefix("T"), let info = keyInfo(output.key) else { continue }
            let key = Key(code: output.key, info: info)
            // Skip sensors that aren't populated on this machine.
            guard let value = value(of: key), Self.isPlausible(value) else { continue }
            switch Self.unit(of: name, type: string(info.dataType)) {
            case .cpu: cpuKeys.append(key)
            case .gpu: gpuKeys.append(key)
            case nil: break
            }
        }
    }

    private enum Unit { case cpu, gpu }

    private static func unit(of name: String, type: String) -> Unit? {
        let chars = Array(name)
        guard chars.count == 4 else { return nil }
        switch type {
        case "flt ":
            if ["p", "e", "s"].contains(chars[1]) { return .cpu }
            if chars[1] == "g" { return .gpu }
        case "sp78":
            guard chars[2].isNumber else { return nil }
            if chars[1] == "C" { return .cpu }
            if chars[1] == "G" { return .gpu }
        default:
            break
        }
        return nil
    }

    private static func isPlausible(_ celsius: Double) -> Bool { celsius > 5 && celsius < 150 }

    // MARK: Reading

    private func mean(_ keys: [Key]) -> Double? {
        let values = keys.compactMap(value(of:)).filter(Self.isPlausible)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func value(of key: Key) -> Double? {
        guard let bytes = readBytes(key.code, key.info) else { return nil }
        switch string(key.info.dataType) {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "sp78":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }

    private func keyInfo(_ code: UInt32) -> SMCKeyInfo? {
        var input = SMCParam()
        input.key = code
        input.data8 = SMCCommand.keyInfo
        return call(input)?.keyInfo
    }

    private func readBytes(_ code: UInt32, _ info: SMCKeyInfo) -> [UInt8]? {
        var input = SMCParam()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCCommand.readKey
        guard let output = call(input) else { return nil }
        let size = min(Int(info.dataSize), 32)
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
    }

    private func call(_ input: SMCParam) -> SMCParam? {
        guard connection != 0 else { return nil }
        var input = input
        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.stride
        let result = IOConnectCallStructMethod(connection, SMCCommand.kernelIndex,
                                               &input, MemoryLayout<SMCParam>.stride,
                                               &output, &outputSize)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func fourCC(_ string: String) -> UInt32 { string.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }
}

// MARK: - AppleSMC user client ABI

private enum SMCCommand {
    static let kernelIndex: UInt32 = 2
    static let readKey: UInt8 = 5
    static let keyAtIndex: UInt8 = 8
    static let keyInfo: UInt8 = 9
}

/// Mirrors the kernel's 12-byte `SMCKeyData_keyInfo_t`; the explicit padding keeps the following
/// fields at their C offsets (Swift would otherwise pack them after `dataAttributes`).
private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

/// Mirrors the kernel's 80-byte `SMCKeyData_t`.
private struct SMCParam {
    var key: UInt32 = 0
    var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// Average and peak of a series of temperature samples.
struct TemperatureStats: Equatable {
    var cpuAverage: Double?
    var cpuMax: Double?
    var gpuAverage: Double?
    var gpuMax: Double?

    static func compute<S: Sequence>(_ samples: S) -> TemperatureStats where S.Element == TemperatureSample {
        let samples = Array(samples)
        let cpu = samples.compactMap(\.cpu)
        let gpu = samples.compactMap(\.gpu)
        return TemperatureStats(cpuAverage: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
                                cpuMax: cpu.max(),
                                gpuAverage: gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count),
                                gpuMax: gpu.max())
    }
}

func formatTemperature(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.0f °C", value)
}

/// "avg / max" without units, for the compact history columns.
func formatTemperatureRange(_ average: Double?, _ maximum: Double?) -> String {
    guard let average, let maximum else { return "—" }
    return String(format: "%.0f / %.0f", average, maximum)
}
