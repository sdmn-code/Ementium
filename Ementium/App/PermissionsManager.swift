import AppKit
import ApplicationServices

/// Разрешение «Универсальный доступ»: без него не работают ни event tap, ни AXObserver.
/// Разрешение привязано к подписи приложения — при смене сертификата его придётся выдать заново.
final class PermissionsManager {
    private var pollTask: Task<Void, Never>?

    var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Ждёт выдачи доступа, проверяя раз в секунду, чтобы перехват включился без перезапуска.
    /// Системный диалог сам не показывается — его вызывает кнопка «Разрешить» в окне настроек,
    /// где сначала объяснено, зачем доступ нужен.
    func waitForAccessibility(onGranted: @escaping () -> Void) {
        if AXIsProcessTrusted() {
            onGranted()
            return
        }
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if AXIsProcessTrusted() {
                    onGranted()
                    return
                }
            }
        }
    }

    /// Системный диалог «Ementium хочет управлять компьютером…» с кнопкой «Открыть Системные настройки».
    func requestAccessibility() {
        // Строковый ключ вместо `kAXTrustedCheckOptionPrompt`: глобальная переменная C не проходит проверку Swift 6.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
