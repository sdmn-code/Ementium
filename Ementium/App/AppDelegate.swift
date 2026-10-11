import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let interceptionEnabledKey = "interceptionEnabled"

    private let state = InterceptionState()
    private let permissions = PermissionsManager()
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "app")
    private lazy var viewer = ViewerWindowController(state: state)
    private lazy var bridge = FinderBridge(state: state)
    private lazy var interceptor = KeyInterceptor(state: state) { [weak self] urls, fromFinderView in
        Task { @MainActor in self?.openFromFinder(urls, fromFinderView: fromFinderView) }
    }
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

        observeWorkspace()
        permissions.waitForAccessibility { [weak self] in self?.startInterception() }
    }

    // `open -a Ementium файл…` и «Открыть в программе» в Finder приходят сюда —
    // и при запуске, и в уже работающий процесс.
    func application(_ application: NSApplication, open urls: [URL]) {
        log.info("Открыть \(urls.count) файл(ов): \(urls.map(\.lastPathComponent), privacy: .private)")
        viewer.show(urls: urls)
    }

    private func openFromFinder(_ urls: [URL], fromFinderView: Bool) {
        let bridge = self.bridge
        viewer.show(urls: urls, finderViewItems: fromFinderView ? { @Sendable in await bridge.viewItems() } : nil)
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
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let isFinder = app?.bundleIdentifier == FinderBridge.finderBundleID
        state.update { $0.isFinderFrontmost = isFinder }
        if isFinder { bridge.refreshSoon() }
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
