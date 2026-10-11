import AppKit

enum InterceptionStatus {
    case waitingForPermission
    case running
    case failed
}

/// Иконка в строке меню: статус перехвата, выключатель, настройки и выход.
final class StatusMenuController: NSObject, NSMenuDelegate {
    var status = InterceptionStatus.waitingForPermission {
        didSet { updateIcon() }
    }
    var isEnabled: Bool {
        didSet { updateIcon() }
    }
    var onToggle: ((Bool) -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    /// Иконку можно скрыть в настройках; настройки тогда — повторным запуском или `⌘,` в просмотре.
    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        super.init()
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Ementium")
        menu.delegate = self
        item.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        // Бледная иконка — перехват сейчас не работает.
        item.button?.appearsDisabled = !(status == .running && isEnabled)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusText = switch status {
        case .waitingForPermission: "Нет доступа к «Универсальному доступу»"
        case .failed: "Не удалось включить перехват"
        case .running: isEnabled ? "Перехват Пробела работает" : "Перехват выключен"
        }
        menu.addItem(NSMenuItem(title: statusText, action: nil, keyEquivalent: ""))

        if status != .running {
            let settings = NSMenuItem(title: "Открыть настройки доступа…", action: #selector(openSettings), keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)
        }

        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Перехватывать Пробел в Finder", action: #selector(toggle), keyEquivalent: "")
        toggle.target = self
        toggle.state = isEnabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Настройки…", action: #selector(openPreferences), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Выйти из Ementium", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggle() {
        isEnabled.toggle()
        onToggle?(isEnabled)
    }

    @objc private func openSettings() {
        onOpenAccessibilitySettings?()
    }

    @objc private func openPreferences() {
        onOpenSettings?()
    }
}
