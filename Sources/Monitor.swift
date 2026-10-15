import Foundation
import AppKit
import ServiceManagement

enum FanMode: Equatable {
    case system
    case percent(Int)
}

struct Advice {
    enum Level { case ok, info, warn, hot }
    let level: Level
    let text: String
}

@MainActor
final class Monitor: ObservableObject {
    @Published var cpu = TempGroup()
    @Published var gpu = TempGroup()
    @Published var mem = TempGroup()
    @Published var ssd = TempGroup()
    @Published var battery = TempGroup()
    @Published var fans: [FanInfo] = []
    @Published var power: Double?
    @Published var cpuLoad: Double = 0
    @Published var memUsed: UInt64 = 0
    @Published var memPressure = 1
    @Published var thermalState = ProcessInfo.processInfo.thermalState
    @Published var topProcesses: [ProcessLoad] = []

    @Published var mode: FanMode = .system
    @Published var helperInstalled = FanController.isInstalled
    @Published var lastError: String?
    /// Охлаждение включено автоматически (по температуре), а не вручную.
    @Published var boostedByRule = false

    @Published var autoBoost = UserDefaults.standard.bool(forKey: "autoBoost") {
        didSet { UserDefaults.standard.set(autoBoost, forKey: "autoBoost") }
    }
    @Published var boostThreshold = UserDefaults.standard.object(forKey: "boostThreshold") as? Int ?? 85 {
        didSet { UserDefaults.standard.set(boostThreshold, forKey: "boostThreshold") }
    }

    /// Значение слайдера ручной скорости, %.
    @Published var customPct: Double = 60
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { launchAtLogin ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { lastError = error.localizedDescription }
        }
    }

    let memTotal = ProcessInfo.processInfo.physicalMemory
    private let smc = SMCReader()
    private let load = LoadReader()
    private var timer: Timer?
    private var tickCount = 0

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        // После сна SMC сбрасывает ручной режим — применяем заново.
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapply() }
        }
        // При выходе обязательно отдаём вентиляторы системе.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.mode != .system { _ = FanController.setAuto() }
            }
        }
    }

    var hasFans: Bool { smc.fanCount > 0 }

    func refresh() {
        cpu = smc.temps("cpu")
        gpu = smc.temps("gpu")
        mem = smc.temps("mem")
        ssd = smc.temps("ssd")
        battery = smc.temps("bat")
        fans = smc.fans()
        power = smc.systemPower()
        cpuLoad = load.cpuUsage()
        memUsed = load.memoryUsed()
        memPressure = load.memoryPressure()
        thermalState = ProcessInfo.processInfo.thermalState

        if tickCount % 2 == 0 {
            Task.detached(priority: .utility) {
                let top = ProcessList.top(6).filter { $0.name != "ps" }.prefix(5)
                await MainActor.run { self.topProcesses = Array(top) }
            }
        }
        tickCount += 1
        applyRules()
    }

    // MARK: - Управление

    func setMode(_ new: FanMode, byRule: Bool = false) {
        guard helperInstalled else { lastError = "Сначала установи помощника"; return }
        let err: String?
        switch new {
        case .system: err = FanController.setAuto()
        case .percent(let p): err = FanController.setPercent(p)
        }
        lastError = err
        if err == nil {
            mode = new
            boostedByRule = byRule
        }
    }

    func installHelper() {
        lastError = FanController.install()
        helperInstalled = FanController.isInstalled
    }

    func uninstallHelper() {
        lastError = FanController.uninstall()
        mode = .system
        helperInstalled = FanController.isInstalled
    }

    private func reapply() {
        if mode != .system { setMode(mode, byRule: boostedByRule) }
    }

    private func applyRules() {
        guard helperInstalled, hasFans else { return }
        let hot = cpu.max

        // Страховка: ручной тихий режим + чип перегрелся → максимум.
        if case .percent(let p) = mode, p < 100, hot >= 95 {
            setMode(.percent(100), byRule: true)
            return
        }
        guard autoBoost else { return }
        if mode == .system, hot >= Double(boostThreshold) {
            setMode(.percent(100), byRule: true)
        } else if boostedByRule, hot <= Double(boostThreshold - 15) {
            setMode(.system)
        }
    }

    // MARK: - Анализ

    var advice: [Advice] {
        var list: [Advice] = []
        let hot = cpu.max
        if thermalState == .critical || thermalState == .serious || hot >= 95 {
            list.append(Advice(level: .hot, text: "Перегрев — процессор снижает частоты. Включи максимальное охлаждение."))
        } else if hot >= 80 {
            list.append(Advice(level: .warn, text: "Горячо (\(Int(hot))°). Усиленное охлаждение поможет держать частоты."))
        }
        if let top = topProcesses.first, top.cpu >= 80 {
            list.append(Advice(level: .info, text: "«\(top.name)» грузит процессор на \(Int(top.cpu))%."))
        }
        if memPressure >= 4 {
            list.append(Advice(level: .hot, text: "Критически мало памяти — закрой тяжёлые приложения."))
        } else if memPressure >= 2 {
            list.append(Advice(level: .warn, text: "Память на пределе, система активно сжимает и свопит."))
        }
        if battery.max >= 40 {
            list.append(Advice(level: .warn, text: "Батарея нагрета до \(Int(battery.max))° — это ускоряет её износ."))
        }
        if list.isEmpty {
            list.append(Advice(level: .ok, text: hot < 60 ? "Всё в норме, мак холодный." : "Всё в норме."))
        }
        return list
    }

    var thermalStateText: String {
        switch thermalState {
        case .nominal: "норма"
        case .fair: "тёплый"
        case .serious: "троттлинг"
        case .critical: "критично"
        @unknown default: "?"
        }
    }
}
