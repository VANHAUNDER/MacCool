import Foundation
import Darwin

// MARK: - SMC

struct FanInfo: Identifiable {
    let id: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var manual: Bool
    var percent: Double { maxRPM > minRPM ? max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM))) : 0 }
}

struct TempGroup {
    var avg: Double = 0
    var max: Double = 0
    var available: Bool { max > 0 }
}

/// Читает температуры и вентиляторы из SMC. Список ключей собирается один раз при запуске.
final class SMCReader {
    private var groups: [String: [String]] = [:]
    let fanCount: Int

    init() {
        _ = smc_open()
        var n: Double = 0
        fanCount = smc_read_double("FNum", &n) == 0 ? Int(n) : 0

        // Префиксы ключей Apple Silicon: Tp — ядра CPU, Tg — GPU, Tm — память, TH — SSD, TB?T — батарея.
        let prefixes = ["Tp": "cpu", "Tg": "gpu", "Tm": "mem", "TH": "ssd"]
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<smc_key_count() {
            guard smc_key_at(i, &buf) == 0 else { continue }
            let key = String(cString: buf)
            guard key.hasPrefix("T"), let v = Self.read(key), v > 5, v < 130 else { continue }
            if let g = prefixes[String(key.prefix(2))] {
                groups[g, default: []].append(key)
            } else if key.hasPrefix("TB"), key.hasSuffix("T") {
                groups["bat", default: []].append(key)
            }
        }
    }

    static func read(_ key: String) -> Double? {
        var v: Double = 0
        return smc_read_double(key, &v) == 0 ? v : nil
    }

    func temps(_ group: String) -> TempGroup {
        let values = (groups[group] ?? []).compactMap(Self.read).filter { $0 > 5 && $0 < 130 }
        guard !values.isEmpty else { return TempGroup() }
        return TempGroup(avg: values.reduce(0, +) / Double(values.count), max: values.max()!)
    }

    func fans() -> [FanInfo] {
        (0..<fanCount).map { i in
            FanInfo(id: i,
                    rpm: Self.read("F\(i)Ac") ?? 0,
                    minRPM: Self.read("F\(i)Mn") ?? 0,
                    maxRPM: Self.read("F\(i)Mx") ?? 0,
                    manual: (Self.read("F\(i)md") ?? 0) != 0)
        }
    }

    /// Полное потребление системы в ваттах.
    func systemPower() -> Double? { Self.read("PSTR") }
}

// MARK: - CPU / память / процессы

final class LoadReader {
    private var prevTicks: [(busy: UInt64, total: UInt64)] = []

    /// Загрузка CPU в процентах (0–100) с прошлого вызова.
    func cpuUsage() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [(UInt64, UInt64)] = []
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let sys = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            ticks.append((user + sys + nice, user + sys + nice + idle))
        }
        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count else { return 0 }
        var busy: UInt64 = 0, total: UInt64 = 0
        for (now, prev) in zip(ticks, prevTicks) {
            busy += now.0 &- prev.busy
            total += now.1 &- prev.total
        }
        return total > 0 ? Double(busy) / Double(total) * 100 : 0
    }

    /// Использованная память (как «Память использована» в Мониторинге системы), байты.
    func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let pages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    /// 1 — норма, 2 — предупреждение, 4 — критично.
    func memoryPressure() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return Int(level)
    }
}

struct ProcessLoad: Identifiable {
    let id = UUID()
    let name: String
    let cpu: Double
}

enum ProcessList {
    /// Самые прожорливые по CPU процессы (через ps).
    static func top(_ n: Int) -> [ProcessLoad] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pcpu=,comm=", "-r"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        return lines.prefix(n).compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let cpu = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { return nil }
            return ProcessLoad(name: String(parts[1]), cpu: cpu)
        }
    }
}
