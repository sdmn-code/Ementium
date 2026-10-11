import AppKit
import ApplicationServices

/// Разрешение «Универсальный доступ»: без него не работают ни event tap, ни AXObserver.
/// Разрешение привязано к подписи приложения — при смене сертификата его придётся выдать заново.
final class PermissionsManager {
    private var pollTask: Task<Void, Never>?

    var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Если доступа нет — показывает системный диалог и ждёт выдачи, проверяя раз в секунду,
    /// чтобы перехват включился без перезапуска.
    func waitForAccessibility(onGranted: @escaping () -> Void) {
        if AXIsProcessTrusted() {
            onGranted()
            return
        }
        // Строковый ключ вместо `kAXTrustedCheckOptionPrompt`: глобальная переменная C не проходит проверку Swift 6.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
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

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
