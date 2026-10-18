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

    /// Когда последний раз просили активацию: ответ асинхронный, и окно могут закрыть раньше, чем он придёт.
    private(set) var activationRequestedAt = Date.distantPast

    func requestActivation() {
        activationRequestedAt = Date()
        NSApp.activate()
    }

    // Щелчок по окну даёт системе повод разрешить активацию — активируемся: системная палитра цветов
    // и остальное рассчитаны на активное приложение. Не `NSApp.isActive`: пока неактивирующая панель
    // ключевая, он true, хотя впереди другое приложение. Крестику активация не нужна: пришла бы уже
    // после закрытия, и Ementium остался бы впереди без окон.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !NSRunningApplication.current.isActive, !isOnCloseButton(event) {
            requestActivation()
        }
        super.sendEvent(event)
    }

    private func isOnCloseButton(_ event: NSEvent) -> Bool {
        guard let button = standardWindowButton(.closeButton) else { return false }
        return button.convert(button.bounds, to: nil).contains(event.locationInWindow)
    }
}

/// Вкладки окна настроек: сообщает о выбранной — её запоминаем и под неё подгоняем окно.
final class SettingsTabsController: NSTabViewController {
    var onSelect: ((Int) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?(selectedTabViewItemIndex)
    }
}

/// Окно настроек — панель AppKit со вкладками в панели инструментов и формами SwiftUI внутри. Не сцена SwiftUI
/// `Settings`: у агентского приложения открыть её из кода на macOS 14+ можно только недокументированным вызовом.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 520
    private static let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "settings")

    /// Высота содержимого панели — по замеру скриншотов (ru и en): всё видно без прокрутки. Окно не подгоняется
    /// под содержимое само: прокручиваемая `Form` с переносом текста и окно, следующее за её высотой, раскачивают
    /// друг друга бесконечным пересчётом констрейнтов — AppKit роняет приложение. Не влезшее (длинный перевод,
    /// маленький экран) прокручивается.
    private static func height(of pane: SettingsPane, model: SettingsModel) -> CGFloat {
        // Замер на macOS 27 (больший из ru и en) плюс 20 pt снизу; ожидание подтверждения автозапуска —
        // оценка по высоте строки (это состояние не вызвать по желанию).
        switch pane {
        case .general:
            var height: CGFloat = 270
            if !model.isAccessibilityGranted {
                height += 245
            } else if model.justGranted {
                height += 62
            }
            if model.loginItemNeedsApproval { height += 56 }
            return height
        case .viewer: return 828
        case .controls: return 544
        case .about: return 295
        }
    }

    let model: SettingsModel
    private var window: SettingsPanel?
    private var tabs: SettingsTabsController?
    /// Кто был активен до открытия настроек — ему вернём фокус после закрытия.
    private var previousApp: NSRunningApplication?
    /// Вкладку выбирает сам `show()` — это не выбор пользователя, его не запоминаем.
    private var isSelectingPane = false
    /// Окно закрыли раньше, чем пришла активация, которую попросил щелчок, — до этого момента её ждём,
    /// чтобы сразу вернуть фокус (см. `windowWillClose`).
    private var returnFocusDeadline = Date.distantPast
    /// Было ли окно впереди, когда ушли с его рабочего стола (см. `activeSpaceDidChange`).
    private var spaceTracker = SpaceReturnTracker()

    init(model: SettingsModel) {
        self.model = model
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationDidActivate(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidDeactivate(_:)),
                           name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(activeSpaceDidChange(_:)),
                           name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front != NSRunningApplication.current { previousApp = front }

        // Без разрешения — всегда «Основные»: там объяснение и кнопка. Иначе — последняя открытая панель.
        // Читаем до создания окна: создавая вкладки, оно само выбирает первую.
        let saved = UserDefaults.standard.integer(forKey: Preferences.Key.settingsPane)
        let index = model.isAccessibilityGranted ? min(max(saved, 0), SettingsPane.allCases.count - 1) : 0
        let isNew = window == nil
        if isNew { makeWindow() }
        guard let window, let tabs else { return }
        if tabs.selectedTabViewItemIndex != index {
            // Вкладки сообщают о программном выборе сразу, внутри присваивания.
            isSelectingPane = true
            tabs.selectedTabViewItemIndex = index
            isSelectingPane = false
        }
        paneSelected(index, animated: false)
        if isNew {
            window.center()
            // Центрирование не знает о Dock — на невысоком экране окно вернётся в видимую область.
            resizeToPane(animated: false)
        }
        bringToFront()
        // Состояние автозапуска — уже после показа: ответ системы бывает небыстрым.
        Task { self.model.refreshLoginItem() }
    }

    /// Вперёд и с клавиатурой. Активацию система разрешает не всегда (см. `SettingsPanel`) — клавиатуру панель
    /// получит и без неё.
    private func bringToFront() {
        window?.requestActivation()
        orderFront(makeKey: true)
        checkFocusSoon()
    }

    /// Вперёд поверх чужих окон. Окно с другого рабочего стола переезжает на текущий (`moveToActiveSpace`) —
    /// прежний уход с его стола забыт.
    private func orderFront(makeKey: Bool) {
        guard let window else { return }
        // Пока были на другом столе, окно могло плавать над обычными (см. `activeSpaceDidChange`); порядок окон
        // смена уровня не меняет — оно остаётся наверху.
        window.level = .normal
        // Приложение может остаться неактивным — обычный вывод вперёд оставил бы окно под окнами активного.
        window.orderFrontRegardless()
        if makeKey { window.makeKey() }
        spaceTracker.shown()
    }

    private func makeWindow() {
        let tabs = SettingsTabsController()
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: content(of: pane))
            // Размер окна ведём сами (`resizeToPane`). С `preferredContentSize` у панели вкладки подгоняют окно
            // мгновенно и сбивают анимацию, а подгонка под содержимое зацикливается (см. `height(of:model:)`).
            host.sizingOptions = []
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        // Запоминаем выбор пользователя. Выбор из `show()` — нет, и при создании окна, когда вкладки сами
        // выбирают первую, — тоже: окна ещё нет.
        tabs.onSelect = { [weak self] index in
            guard let self, !self.isSelectingPane else { return }
            if self.window?.isVisible == true {
                UserDefaults.standard.set(index, forKey: Preferences.Key.settingsPane)
            }
            self.paneSelected(index, animated: true)
        }
        // Окно не растягивается и не разворачивается: его размер — размер панели (HIG Settings).
        let created = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false
        )
        created.contentViewController = tabs
        created.toolbarStyle = .preference
        // Открытое из меню, пока окно на другом рабочем столе, — на текущем, и поверх полноэкранного приложения.
        created.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.delegate = self
        window = created
        self.tabs = tabs
        observeModel()
    }

    /// Выбрана панель: заголовок — её имя (HIG Settings), размер — её.
    private func paneSelected(_ index: Int, animated: Bool) {
        guard let window, let pane = SettingsPane(rawValue: index) else { return }
        window.title = pane.title
        fitWindowToPane(animated: animated)
    }

    private func content(of pane: SettingsPane) -> AnyView {
        switch pane {
        case .general: AnyView(GeneralPane(model: model))
        case .viewer: AnyView(ViewerPane())
        case .controls: AnyView(ControlsPane())
        case .about: AnyView(AboutPane())
        }
    }

    private func fitWindowToPane(animated: Bool) {
        guard animated else {
            resizeToPane(animated: false)
            return
        }
        // Анимацию размера, начатую внутри смены вкладки, AppKit обрывает на первом кадре — со следующего прохода.
        DispatchQueue.main.async { [weak self] in self?.resizeToPane(animated: true) }
    }

    /// Размер окна — под выбранную панель; верхний край остаётся на месте, окно — в видимой области экрана.
    private func resizeToPane(animated: Bool) {
        guard let window, let tabs, let contentView = window.contentView,
              let pane = SettingsPane(rawValue: tabs.selectedTabViewItemIndex) else { return }
        var frame = window.frame
        let dh = Self.height(of: pane, model: model) - contentView.frame.height
        frame.size.width += Self.width - contentView.frame.width
        frame.size.height += dh
        frame.origin.y -= dh
        // Выше экрана — по его высоте, остальное прокрутит форма; низ ушёл за край или под Dock — выше.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.height = min(frame.height, visible.height)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        guard frame != window.frame else { return }
        if animated, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    /// Разрешение выдали, «Готово» показали, автозапуск ждёт подтверждения — высота «Основных» меняется.
    private func observeModel() {
        withObservationTracking {
            _ = (model.isAccessibilityGranted, model.justGranted, model.loginItemNeedsApproval)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.fitWindowToPane(animated: true)
                self?.observeModel()
            }
        }
    }

    /// Доступ выдали, пока окно открыто, — поднять его: «Готово» иначе осталось бы за Системными настройками.
    /// Клавиатуру не забираем: пользователь, может быть, ещё в Системных настройках.
    func raiseIfVisible() {
        guard let window, window.isVisible else { return }
        orderFront(makeKey: false)
    }

    /// Окно открылось без фокуса клавиатуры — ещё раз и запись в лог: по ней видно, если это повторится.
    /// Только на столе окна: успели уйти на другой — вывод вперёд утащил бы окно туда.
    private func checkFocusSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let window = self.window, window.isVisible, window.isOnActiveSpace,
                  !window.isKeyWindow else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
            // notice, а не info: info система держит только в памяти, через минуты его в журнале уже нет.
            Self.log.notice("Настройки открылись без фокуса (активно: \(front, privacy: .public)) — ещё раз")
            self.orderFront(makeKey: true)
        }
    }

    private static func isEmentium(_ notification: Notification) -> Bool {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard Self.isEmentium(notification), let window else { return }
        if Date() < returnFocusDeadline {
            returnFocusDeadline = .distantPast
            // Активировались ради другого окна (просмотр через «Открыть в программе») — фокус ему.
            let otherWindow = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeKey }
            if !window.isVisible, !otherWindow {
                returnFocus()
                return
            }
        }
        // Палитру открыл тот же щелчок, что попросил активацию, — фокус ей, когда активация пришла.
        if Date() < BackgroundColorWell.paletteFocusDeadline, NSColorPanel.sharedColorPanelExists,
           NSColorPanel.shared.isVisible {
            NSColorPanel.shared.makeKeyAndOrderFront(nil)
        }
        BackgroundColorWell.paletteFocusDeadline = .distantPast
        // Автозапуск могли подтвердить в Системных настройках, пока окно было открыто, — перечитываем.
        // Уже после активации: ответ системы бывает небыстрым.
        if window.isVisible { Task { self.model.refreshLoginItem() } }
    }

    @objc private func applicationDidDeactivate(_ notification: Notification) {
        guard Self.isEmentium(notification) else { return }
        spaceTracker.lostFront(at: Date())
    }

    func windowDidResignKey(_ notification: Notification) {
        spaceTracker.lostFront(at: Date())
    }

    /// Возврат на рабочий стол окна. Система там активирует не Ementium, даже если он был впереди, когда уходили:
    /// агентское приложение она пропускает и выводит поверх окна то, что было до него. Поднимаем окно сами, а чтобы
    /// чужое окно не мелькнуло поверх на кадр-другой, пока нас нет, окно плавает над обычными (`pinIfWasFront`).
    @objc private func activeSpaceDidChange(_ notification: Notification) {
        guard let window, window.isVisible else { return }
        if !window.isOnActiveSpace {
            spaceTracker.left(at: Date(), isFront: NSRunningApplication.current.isActive || window.isKeyWindow)
            pinIfWasFront()
            // Уведомление о потере фокуса может прийти и после ухода — ещё раз, когда придут все.
            DispatchQueue.main.asyncAfter(deadline: .now() + SpaceReturnTracker.window) { [weak self] in
                self?.pinIfWasFront()
            }
        } else if spaceTracker.isAway {
            if spaceTracker.returned() {
                Self.log.notice("Вернулись на рабочий стол настроек — поднимаю окно")
                bringToFront()
            } else {
                window.level = .normal
            }
        }
    }

    private func pinIfWasFront() {
        guard let window, window.isVisible, !window.isOnActiveSpace, spaceTracker.isAway, spaceTracker.wasFront
        else { return }
        window.level = .floating
    }

    func windowWillClose(_ notification: Notification) {
        // «Готово» — один раз: при следующем открытии окна его уже не будет.
        model.justGranted = false
        spaceTracker = SpaceReturnTracker()
        window?.level = .normal
        // Палитра цветов меняет настройку из этого окна — закрывается вместе с ним.
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
        if NSRunningApplication.current.isActive {
            returnFocus()
        } else if let window, Date().timeIntervalSince(window.activationRequestedAt) < 1 {
            // Активацию попросили только что (щёлкнули по переключателю и сразу закрыли), а придёт она уже после
            // закрытия, — тогда и вернём фокус, иначе Ementium остался бы впереди без окон.
            returnFocusDeadline = Date().addingTimeInterval(1)
        }
        // Иначе активации не было и не будет (панель получила клавиатуру без неё) — прежнее приложение и так впереди.
    }

    /// Агентское приложение без окон осталось бы активным — вернём фокус туда, где он был.
    private func returnFocus() {
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        } else {
            NSApp.hide(nil)
        }
    }
}
