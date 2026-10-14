import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = InterceptionState()
    private let permissions = PermissionsManager()
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "app")
    private lazy var viewer = ViewerWindowController(state: state)
    private lazy var bridge = FinderBridge(
        state: state,
        onShow: { [weak self] url in
            // Главная очередь сохраняет порядок: при быстром листании старая картинка не покажется после новой.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.viewer.followed(url) }
            }
        },
        onBusy: { [weak self] busy in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.viewer.setNavigationBusy(busy) }
            }
        },
        onNeighbors: { [weak self] neighbors, current in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.viewer.followedNeighbors(neighbors, around: current) }
            }
        },
        onTrash: { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleTrash(event) }
            }
        }
    )
    private lazy var interceptor = KeyInterceptor(
        state: state,
        onAbsorb: { [weak self] urls in
            Task { @MainActor in self?.openFromFinder(urls) }
        },
        onViewerKey: { [weak self, bridge] action in
            // Шаг — сразу в мост, без захода на главный поток: каждая миллисекунда видна при листании.
            if case .step(let key) = action {
                // Раньше шага: его ответ моста не должен потеряться как «прежнее смахивание».
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.viewer.dropSwipeLead() }
                }
                bridge.step(key)
            } else {
                Task { @MainActor in self?.handleViewerKey(action) }
            }
        },
        onViewerGesture: { [weak self] gesture in
            // Главная очередь сохраняет порядок жестов: масштаб меняется плавно, без скачков назад.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.viewer.gesture(gesture) }
            }
        },
        onViewerInput: { [weak self] input in
            // Главная очередь сохраняет порядок: «⌥ нажат» не обгонит «⌥ отпущен».
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.viewer.input(input) }
            }
        }
    )
    private var statusMenu: StatusMenuController?
    private var retryTask: Task<Void, Never>?
    private lazy var settings = SettingsWindowController(model: SettingsModel(isAccessibilityGranted: permissions.isAccessibilityGranted))

    /// Тесты Xcode запускают само приложение как «хозяина» — ни перехвата, ни автозапуска, ни окон.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        Preferences.register()
        let store = UserDefaults.standard
        let isEnabled = store.bool(forKey: Preferences.Key.interceptionEnabled)
        let finderIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderBridge.finderBundleID
        state.update {
            $0.isEnabled = isEnabled
            $0.isFinderFrontmost = finderIsFrontmost
        }

        let menu = StatusMenuController(isEnabled: isEnabled)
        menu.onToggle = { enabled in
            // Остальное сделает наблюдатель за настройками — так же, как при переключении в окне настроек.
            UserDefaults.standard.set(enabled, forKey: Preferences.Key.interceptionEnabled)
        }
        menu.onOpenAccessibilitySettings = { [weak self] in self?.permissions.openAccessibilitySettings() }
        menu.onOpenSettings = { [weak self] in self?.showSettings() }
        menu.isVisible = store.bool(forKey: Preferences.Key.showMenuBarIcon)
        statusMenu = menu

        settings.model.onRequestAccessibility = { [weak self] in self?.permissions.requestAccessibility() }
        settings.model.onOpenAccessibilitySettings = { [weak self] in self?.permissions.openAccessibilitySettings() }
        viewer.onFollowingEnded = { [weak self] in self?.bridge.stopFollowing() }
        viewer.onOpenSettings = { [weak self] in self?.showSettings() }
        viewer.onFollowResync = { [weak self] in self?.bridge.rereadNeighbors() }
        viewer.onFollowSelect = { [weak self] url in
            // Как и для стрелок с клавиатуры: только пока Finder активен.
            guard let self, self.state.snapshot.isFinderFrontmost else { return false }
            self.bridge.select(swipedTo: url)
            return true
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange(_:)), name: UserDefaults.didChangeNotification, object: nil
        )
        observeWorkspace()
        LoginItem.enableOnFirstLaunch()
        DecoderClient.shared.shouldStayWarm = { [weak self] in self?.state.snapshot.isFinderFrontmost ?? false }
        if finderIsFrontmost { DecoderClient.shared.warmUp() }

        // Нет доступа (первый запуск или его отозвали) — окно с объяснением вместо внезапного системного диалога.
        if !permissions.isAccessibilityGranted {
            showSettings()
        }
        permissions.waitForAccessibility { [weak self] in
            guard let self else { return }
            let started = self.startInterception()
            if !self.settings.model.isAccessibilityGranted {
                self.settings.model.isAccessibilityGranted = true
                // «Готово» — тому, кто выдал доступ при открытом окне, и только если перехват заработал:
                // через несколько дней или при сбое оно бы только запутало.
                self.settings.model.justGranted = started && self.settings.isVisible
                // «Готово» иначе осталось бы за Системными настройками, где только что выдали доступ.
                self.settings.raiseIfVisible()
            }
        }
    }

    // Повторный запуск уже работающего Ementium (из Программ, Spotlight) — открыть настройки.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isRunningTests else { return false }
        showSettings()
        return false
    }

    func showSettings() {
        settings.show()
    }

    /// Уведомление приходит на том потоке, где поменяли `UserDefaults`, — не обязательно на главном:
    /// декодер RAW регистрирует свои значения по умолчанию на фоновом. Поэтому сначала — на главный.
    @objc nonisolated private func preferencesDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.applyPreferences() }
    }

    /// Настройки поменялись — в окне настроек или в меню иконки.
    private func applyPreferences() {
        let store = UserDefaults.standard
        let enabled = store.bool(forKey: Preferences.Key.interceptionEnabled)
        if state.snapshot.isEnabled != enabled {
            state.update { $0.isEnabled = enabled }
            statusMenu?.isEnabled = enabled
            log.info("Перехват \(enabled ? "включён" : "выключен")")
        }
        let showIcon = store.bool(forKey: Preferences.Key.showMenuBarIcon)
        if statusMenu?.isVisible != showIcon {
            statusMenu?.isVisible = showIcon
        }
    }

    // `open -a Ementium файл…` и «Открыть в программе» в Finder приходят сюда —
    // и при запуске, и в уже работающий процесс.
    func application(_ application: NSApplication, open urls: [URL]) {
        log.info("Открыть \(urls.count) файл(ов): \(urls.map(\.lastPathComponent), privacy: .private)")
        viewer.show(urls: urls)
    }

    /// Пробел в Finder. Один файл — листаем вслед за выделением Finder (его порядок, его окно);
    /// несколько — по своему списку из выделенных, как Quick Look.
    private func openFromFinder(_ urls: [URL]) {
        if urls.count == 1, let url = urls.first {
            // Пока Пробел шёл до главного потока, пользователь мог уйти из Finder (⌘Tab) — тогда режим
            // «следовать» глотал бы клавиши в другом приложении.
            guard state.snapshot.isFinderFrontmost else { return }
            // Сочетания могли переназначить в Системных настройках — перечитываем при каждом открытии.
            let shortcuts = SystemShortcuts.load()
            state.update { $0.systemShortcuts = shortcuts }
            viewer.showFollowing(url)
            if viewer.isFollowing {
                bridge.startFollowing(at: url)
            }
        } else {
            viewer.show(urls: urls)
        }
    }

    private func handleViewerKey(_ action: ViewerKeyAction) {
        switch action {
        case .close:
            endFollowing()
        case .quit:
            NSApp.terminate(nil)
        case .zoom(let command):
            viewer.zoom(command)
        case .openSettings:
            endFollowing()
            showSettings()
        case .trash:
            guard viewer.isFollowing else { return }
            // Дальше ведёт Finder: его ответ (следующая картинка) не должен потеряться как «прежнее смахивание».
            viewer.dropSwipeLead()
            guard let url = viewer.displayedFollowedImage else {
                viewer.showMessage(String(localized: "Image is still loading"))
                return
            }
            // Защищённый файл, нет прав, нет Корзины — Finder задал бы вопрос под оверлеем; не трогаем файл.
            Task {
                if let problem = await TrashCheck.problem(url) {
                    viewer.showMessage(problem.message)
                } else if viewer.displayedFollowedImage == url {
                    bridge.trash(url)
                }
            }
        case .trashOff:
            viewer.showMessage(String(localized: "Moving to Trash is off — turn it on in Settings"))
        case .undoTrash:
            viewer.dropSwipeLead()
            bridge.undoTrash()
        case .edge(let first):
            viewer.dropSwipeLead()
            bridge.jumpToEdge(first: first)
        case .rotate(let clockwise):
            viewer.rotate(clockwise: clockwise)
        case .copy:
            viewer.copyCurrent()
        case .openInApp:
            viewer.openCurrentInApp()
        case .step, .pass, .passAndClose, .swallow:
            break
        }
    }

    private func handleTrash(_ event: FinderBridge.TrashEvent) {
        switch event {
        case .moved(let deleted, let next):
            // Событие от прошлого сеанса просмотра (закрыли и открыли снова, пока оно шло) — не наше. Или, пока
            // шло удаление, смахнули дальше: просмотр сверится с Finder сам — пусть знает, где теперь выделение.
            guard viewer.followedFile == deleted else {
                if let next { viewer.finderMoved(to: next) }
                return
            }
            if let next {
                viewer.followed(next)
                viewer.showMessage(String(localized: "Moved to Trash"))
            } else {
                // Картинок в окне не осталось.
                endFollowing()
            }
        case .restored(let url):
            viewer.followed(url)
            viewer.showMessage(String(localized: "Restored"))
        case .slow:
            viewer.showMessage(String(localized: "Finder isn't responding — check the Finder window"))
        case .failed(let undo):
            viewer.showMessage(undo ? String(localized: "Couldn't restore") : String(localized: "Couldn't delete"))
        case .notHere:
            viewer.showMessage(String(localized: "Can't delete here — delete in Finder"))
        case .cancelled:
            viewer.showMessage(String(localized: "Selection changed — press ⌘⌫ again"))
        case .nothingToUndo:
            viewer.showMessage(String(localized: "Nothing to restore"))
        case .alreadyBack:
            viewer.showMessage(String(localized: "The file is already back"))
        }
    }

    /// Закрыть просмотр в режиме «следовать»; мост остановит `viewer.onFollowingEnded`.
    private func endFollowing() {
        viewer.closeFollowing()
    }

    // MARK: - Перехват

    /// false — tap не создался; повторяем в фоне, пока не получится.
    @discardableResult
    private func startInterception() -> Bool {
        log.info("Доступ к Универсальному доступу есть, запускаю перехват")
        bridge.start()
        if interceptor.start() {
            statusMenu?.status = .running
            return true
        }
        // Tap не создался при выданном доступе — возможно, нужен ещё «Мониторинг ввода».
        statusMenu?.status = .failed
        if !CGPreflightListenEventAccess() {
            log.info("Запрашиваю «Мониторинг ввода»")
            CGRequestListenEventAccess()
        }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if self.interceptor.start() {
                    self.statusMenu?.status = .running
                    return
                }
            }
        }
        return false
    }

    // MARK: - Finder

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationDidActivate(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(finderDidRestart(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(finderDidTerminate(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let isFinder = app?.bundleIdentifier == FinderBridge.finderBundleID
        state.update { $0.isFinderFrontmost = isFinder }
        if isFinder {
            bridge.refreshSoon()
            // Пробел вероятен — сервис декодирования поднимаем заранее, чтобы не ждать его запуска.
            DecoderClient.shared.warmUp()
        } else if viewer.isFollowing {
            // ⌘Tab, Spotlight, клик по уведомлению: Finder больше не получает наши стрелки.
            endFollowing()
        }
    }

    /// Finder упал или завершился во время просмотра — листать больше нечем.
    @objc private func finderDidTerminate(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == FinderBridge.finderBundleID else { return }
        state.update { $0.isFinderFrontmost = false }
        endFollowing()
    }

    @objc private func finderDidRestart(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == FinderBridge.finderBundleID else { return }
        log.info("Finder перезапущен, переподключаюсь")
        // Новому Finder нужно время, чтобы поднять свои окна и AX-дерево.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.bridge.reattach()
        }
    }
}
