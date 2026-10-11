import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let interceptionEnabledKey = "interceptionEnabled"

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
                bridge.step(key)
            } else {
                Task { @MainActor in self?.handleViewerKey(action) }
            }
        }
    )
    private var statusMenu: StatusMenuController?
    private var retryTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.interceptionEnabledKey: true])
        let isEnabled = UserDefaults.standard.bool(forKey: Self.interceptionEnabledKey)
        let finderIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderBridge.finderBundleID
        state.update {
            $0.isEnabled = isEnabled
            $0.isFinderFrontmost = finderIsFrontmost
        }

        let menu = StatusMenuController(isEnabled: isEnabled)
        menu.onToggle = { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: Self.interceptionEnabledKey)
            self?.state.update { $0.isEnabled = enabled }
            self?.log.info("Перехват \(enabled ? "включён" : "выключен") из меню")
        }
        menu.onOpenAccessibilitySettings = { [weak self] in self?.permissions.openAccessibilitySettings() }
        statusMenu = menu

        viewer.onFollowingEnded = { [weak self] in self?.bridge.stopFollowing() }
        observeWorkspace()
        permissions.waitForAccessibility { [weak self] in self?.startInterception() }
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
        case .step, .pass, .passAndClose, .swallow:
            break
        }
    }

    /// Закрыть просмотр в режиме «следовать»; мост остановит `viewer.onFollowingEnded`.
    private func endFollowing() {
        viewer.closeFollowing()
    }

    // MARK: - Перехват

    private func startInterception() {
        log.info("Доступ к Универсальному доступу есть, запускаю перехват")
        bridge.start()
        if interceptor.start() {
            statusMenu?.status = .running
            return
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
