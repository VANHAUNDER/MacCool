import SwiftUI

@main
struct MacCoolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(delegate.monitor)
        } label: {
            MenuBarLabel(m: delegate.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var m: Monitor

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: m.mode == .system ? "thermometer.medium" : "fan.fill")
            Text("\(Int(m.cpu.max.rounded()))°")
        }
    }
}

/// Окно с той же панелью: открывается при запуске и при повторном открытии приложения,
/// чтобы его было видно, даже если значок в строке меню спрятался за «чёлкой».
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    private var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Разрешаем только одну копию: если уже запущена — показываем её окно и выходим.
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me }), let url = other.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "MacCool"
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: PanelView().environmentObject(monitor))
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct PanelView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            temperatures
            Divider()
            loadSection
            Divider()
            adviceSection
            Divider()
            if m.hasFans { coolingSection } else {
                Text("У этого мака нет вентиляторов — управлять охлаждением нельзя.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Секции

    private var header: some View {
        HStack {
            Image(systemName: "snowflake").font(.title2).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 0) {
                Text("MacCool").font(.headline)
                Text("Состояние: \(m.thermalStateText)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = m.power {
                Label(String(format: "%.0f Вт", p), systemImage: "bolt.fill")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var temperatures: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            tempRow("Процессор", "cpu", m.cpu)
            tempRow("Графика", "cube", m.gpu)
            tempRow("Память", "memorychip", m.mem)
            tempRow("SSD", "internaldrive", m.ssd)
            tempRow("Батарея", "battery.75percent", m.battery)
            ForEach(m.fans) { fan in
                GridRow {
                    Image(systemName: "fan").frame(width: 18)
                    Text("Вентилятор \(fan.id + 1)")
                    ProgressView(value: fan.percent).tint(fan.manual ? .cyan : .gray)
                    Text("\(Int(fan.rpm)) об/м").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func tempRow(_ title: String, _ icon: String, _ t: TempGroup) -> some View {
        if t.available {
            GridRow {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                ProgressView(value: min(1, max(0, (t.max - 30) / 75))).tint(color(for: t.max))
                Text("\(Int(t.max.rounded()))°").monospacedDigit().bold().foregroundStyle(color(for: t.max))
                    .frame(width: 80, alignment: .trailing)
            }
        }
    }

    private var loadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CPU \(Int(m.cpuLoad))%").monospacedDigit()
                Spacer()
                Text("ОЗУ \(gb(m.memUsed)) из \(gb(m.memTotal))").monospacedDigit()
            }
            .font(.callout.bold())
            ForEach(m.topProcesses) { p in
                HStack {
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(String(format: "%.0f%%", p.cpu)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var adviceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(m.advice.enumerated()), id: \.offset) { _, a in
                Label(a.text, systemImage: icon(for: a.level))
                    .font(.callout)
                    .foregroundStyle(adviceColor(a.level))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var coolingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Охлаждение").font(.headline)
            if !m.helperInstalled {
                Text("Для управления вентиляторами нужен маленький помощник с правами администратора. Пароль спросят один раз.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Установить помощника") { m.installHelper() }
                    .buttonStyle(.borderedProminent)
            } else {
                HStack {
                    modeButton("Авто", .system)
                    modeButton("Усиленно", .percent(50))
                    modeButton("Максимум", .percent(100))
                }
                HStack {
                    Slider(value: $m.customPct, in: 0...100, step: 5)
                    Text("\(Int(m.customPct))%").monospacedDigit().frame(width: 40)
                    Button("Задать") { m.setMode(.percent(Int(m.customPct))) }
                }
                Toggle(isOn: $m.autoBoost) {
                    Text("Сам включать максимум при CPU ≥ \(m.boostThreshold)°")
                }
                .toggleStyle(.switch).controlSize(.small)
                if m.autoBoost {
                    Stepper("Порог: \(m.boostThreshold)°", value: $m.boostThreshold, in: 60...100, step: 5)
                        .font(.caption)
                }
                if m.boostedByRule {
                    Label("Охлаждение включено автоматически", systemImage: "wand.and.stars")
                        .font(.caption).foregroundStyle(.cyan)
                }
            }
            if let err = m.lastError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Запуск при входе", isOn: $m.launchAtLogin)
                .toggleStyle(.checkbox).font(.caption)
            Spacer()
            Menu {
                if m.helperInstalled { Button("Удалить помощника") { m.uninstallHelper() } }
                Button("Выйти") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    // MARK: Helpers

    private func modeButton(_ title: String, _ mode: FanMode) -> some View {
        Button { m.setMode(mode) } label: { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .tint(m.mode == mode ? .cyan : nil)
    }

    private func color(for t: Double) -> Color {
        switch t {
        case ..<60: .green
        case ..<80: .yellow
        case ..<92: .orange
        default: .red
        }
    }

    private func icon(for level: Advice.Level) -> String {
        switch level {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .hot: "flame.fill"
        }
    }

    private func adviceColor(_ level: Advice.Level) -> Color {
        switch level {
        case .ok: .green
        case .info: .primary
        case .warn: .orange
        case .hot: .red
        }
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f ГБ", Double(bytes) / 1_073_741_824)
    }
}
