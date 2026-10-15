import Foundation

/// Управляет вентиляторами через setuid-помощник maccoolctl.
/// Помощник ставится один раз (с паролем администратора) в /Library/PrivilegedHelperTools.
enum FanController {
    static let installedPath = "/Library/PrivilegedHelperTools/maccoolctl"

    static var bundledPath: String? {
        Bundle.main.path(forResource: "maccoolctl", ofType: nil)
    }

    /// Установлен ли помощник, принадлежит ли root, есть ли setuid и совпадает ли с версией из приложения.
    static var isInstalled: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: installedPath),
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue,
              perms & 0o4000 != 0 else { return false }
        if let bundled = bundledPath,
           FileManager.default.contentsEqual(atPath: bundled, andPath: installedPath) == false {
            return false
        }
        return true
    }

    /// Устанавливает помощника. macOS попросит пароль администратора.
    static func install() -> String? {
        guard let src = bundledPath else { return "Помощник не найден внутри приложения" }
        let dst = installedPath
        let cmd = "mkdir -p /Library/PrivilegedHelperTools && cp -f '\(src)' '\(dst)' && chown root:wheel '\(dst)' && chmod 4755 '\(dst)'"
        return runAsAdmin(cmd)
    }

    static func uninstall() -> String? {
        _ = run(["auto"])
        return runAsAdmin("rm -f '\(installedPath)'")
    }

    private static func runAsAdmin(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error { return error[NSAppleScript.errorMessage] as? String ?? "Не удалось" }
        return nil
    }

    /// Запуск помощника. Возвращает текст ошибки или nil.
    @discardableResult
    static func run(_ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: installedPath) else { return "Помощник не установлен" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: installedPath)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return msg.isEmpty ? "Ошибка \(p.terminationStatus)" : msg.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setAuto() -> String? { run(["auto"]) }
    static func setPercent(_ pct: Int) -> String? { pct >= 100 ? run(["max"]) : run(["set", String(pct)]) }
}
