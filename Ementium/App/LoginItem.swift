import ServiceManagement
import os

/// Автозапуск при входе в систему (`SMAppService.mainApp`). Без него после перезагрузки Пробел снова
/// открывал бы обычный Quick Look, и пользователь не понял бы почему.
enum LoginItem {
    private static let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "login")

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS ждёт подтверждения в «Системные настройки → Основные → Объекты входа».
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Включить или выключить. Возвращает `false`, если система отказала.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            log.error("Автозапуск \(enabled ? "не включился" : "не выключился"): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// При первом запуске автозапуск включается сам — дальше решает пользователь в настройках.
    static func enableOnFirstLaunch(store: UserDefaults = .standard) {
        guard !store.bool(forKey: Preferences.Key.launchAtLoginConfigured) else { return }
        store.set(true, forKey: Preferences.Key.launchAtLoginConfigured)
        set(true)
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
