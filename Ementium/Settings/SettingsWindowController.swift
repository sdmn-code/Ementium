import AppKit
import Observation
import SwiftUI

/// Состояние окна настроек, которое не лежит в `UserDefaults`: разрешение и автозапуск
/// (их правду знает система), и действия, которые выполняет приложение.
@Observable
final class SettingsModel {
    var isAccessibilityGranted: Bool
    /// Доступ выдали, пока окно было открыто, — показываем «Готово».
    var justGranted = false
    var launchAtLogin: Bool
    var loginItemNeedsApproval: Bool

    @ObservationIgnored var onRequestAccessibility: () -> Void = {}
    @ObservationIgnored var onOpenAccessibilitySettings: () -> Void = {}

    init(isAccessibilityGranted: Bool) {
        self.isAccessibilityGranted = isAccessibilityGranted
        launchAtLogin = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.set(enabled)
        refreshLoginItem()
    }

    func refreshLoginItem() {
        launchAtLogin = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.requiresApproval
    }
}

/// Окно настроек — обычное окно AppKit с интерфейсом SwiftUI внутри. Не сцена SwiftUI `Settings`:
/// у агентского приложения открыть её из кода на macOS 14+ можно только недокументированным вызовом.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 480
    private static let preferredHeight: CGFloat = 720

    let model: SettingsModel
    private var window: NSWindow?
    /// Кто был активен до открытия настроек — ему вернём фокус после закрытия.
    private var previousApp: NSRunningApplication?

    init(model: SettingsModel) {
        self.model = model
        super.init()
    }

    func show() {
        model.refreshLoginItem()
        let front = NSWorkspace.shared.frontmostApplication
        if front != NSRunningApplication.current { previousApp = front }

        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            // Размер окна не следует за содержимым: прокручиваемая `Form` с переносом текста и окно, которое
            // подгоняется под её высоту, раскачивают друг друга бесконечным пересчётом констрейнтов — AppKit
            // роняет приложение. Поэтому размер задан явно, а не влезшее прокручивается внутри.
            hosting.sizingOptions = []
            let created = NSWindow(contentViewController: hosting)
            created.title = String(localized: "Ementium Settings")
            created.styleMask = [.titled, .closable, .resizable]
            let screenHeight = NSScreen.main?.visibleFrame.height ?? Self.preferredHeight
            created.setContentSize(NSSize(width: Self.width, height: min(Self.preferredHeight, screenHeight - 40)))
            created.contentMinSize = NSSize(width: Self.width, height: 320)
            created.contentMaxSize = NSSize(width: Self.width, height: .greatestFiniteMagnitude)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // Агентское приложение без окон осталось бы активным — вернём фокус туда, где он был.
    func windowWillClose(_ notification: Notification) {
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        } else {
            NSApp.hide(nil)
        }
    }
}
