import AppKit
import Observation
import SwiftUI
import os

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
        (launchAtLogin, loginItemNeedsApproval) = LoginItem.state
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.set(enabled)
        refreshLoginItem()
    }

    func refreshLoginItem() {
        (launchAtLogin, loginItemNeedsApproval) = LoginItem.state
    }
}

/// Окно настроек — панель, которая получает клавиатуру, не активируя приложение (как окно просмотра).
/// Из меню в строке меню macOS не даёт агентскому приложению активироваться, пока пользователь не щёлкнул
/// по его окну (WindowServer: «activation count being 0»), — обычное окно открывалось без фокуса.
final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    // Щелчок по окну даёт системе повод разрешить активацию — активируемся: системная палитра цветов
    // и остальное рассчитаны на активное приложение (у неактивного палитра не открывалась).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !NSApp.isActive { NSApp.activate() }
        super.sendEvent(event)
    }
}

/// Окно настроек — панель AppKit с интерфейсом SwiftUI внутри. Не сцена SwiftUI `Settings`:
/// у агентского приложения открыть её из кода на macOS 14+ можно только недокументированным вызовом.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 480
    private static let preferredHeight: CGFloat = 720
    private static let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "settings")

    let model: SettingsModel
    private var window: NSWindow?
    /// Кто был активен до открытия настроек — ему вернём фокус после закрытия.
    private var previousApp: NSRunningApplication?

    init(model: SettingsModel) {
        self.model = model
        super.init()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front != NSRunningApplication.current { previousApp = front }
        // Активацию система разрешает не всегда (см. `SettingsPanel`); разрешила — как обычное окно,
        // нет — клавиатуру всё равно получит панель.
        NSApp.activate()

        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            // Размер окна не следует за содержимым: прокручиваемая `Form` с переносом текста и окно, которое
            // подгоняется под её высоту, раскачивают друг друга бесконечным пересчётом констрейнтов — AppKit
            // роняет приложение. Поэтому размер задан явно, а не влезшее прокручивается внутри.
            hosting.sizingOptions = []
            let created = SettingsPanel(
                contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.preferredHeight),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false
            )
            created.contentViewController = hosting
            created.hidesOnDeactivate = false
            created.title = String(localized: "Ementium Settings")
            let screenHeight = NSScreen.main?.visibleFrame.height ?? Self.preferredHeight
            created.setContentSize(NSSize(width: Self.width, height: min(Self.preferredHeight, screenHeight - 40)))
            created.contentMinSize = NSSize(width: Self.width, height: 320)
            created.contentMaxSize = NSSize(width: Self.width, height: .greatestFiniteMagnitude)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        // Приложение может остаться неактивным — обычный вывод вперёд оставил бы окно под окнами активного.
        window?.orderFrontRegardless()
        window?.makeKey()
        // Состояние автозапуска — уже после показа: ответ системы бывает небыстрым.
        Task { self.model.refreshLoginItem() }
        checkFocusSoon()
    }

    /// Окно открылось без фокуса клавиатуры — ещё раз и запись в лог: по ней видно, если это повторится.
    private func checkFocusSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let window = self.window, window.isVisible, !window.isKeyWindow else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
            Self.log.info("Настройки открылись без фокуса (активно: \(front, privacy: .public)) — ещё раз")
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    // Агентское приложение без окон осталось бы активным — вернём фокус туда, где он был. Не активировались
    // (панель получила клавиатуру без активации) — возвращать нечего: прежнее приложение и так активно.
    func windowWillClose(_ notification: Notification) {
        guard NSApp.isActive else { return }
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        } else {
            NSApp.hide(nil)
        }
    }
}
