import AppKit
import os

/// Окно просмотра: принимает клавиатуру, но не активирует приложение (как Spotlight),
/// поэтому активным остаётся то приложение, из которого открыли просмотр.
final class ViewerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Полноэкранный просмотр поверх всех окон.
final class ViewerWindowController: NSObject, NSWindowDelegate {
    private enum State {
        case hidden
        case visible
        /// Идёт затухание; по его окончании окно уберётся, если просмотр не открыли снова.
        case closing
    }

    private let panel: ViewerPanel
    private let viewerView = ViewerView(frame: .zero)
    private let interception: InterceptionState
    private var state = State.hidden
    private var directory: ImageDirectory?
    private var loadTask: Task<Void, Never>?
    private var directoryTask: Task<Void, Never>?
    /// Пока полный список строится, стрелки не теряются: копим шаги и применяем разом.
    private var isListPending = false
    private var pendingSteps = 0
    private var previousApp: NSRunningApplication?
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "viewer")

    private static let fadeDuration = 0.15

    init(state interception: InterceptionState) {
        self.interception = interception
        panel = ViewerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        panel.contentView = viewerView
        panel.delegate = self
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Выше строки меню и Dock.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none

        viewerView.onCommand = { [weak self] command in self?.handle(command) }

        // `open -a` активирует Ementium, поэтому запоминаем, кто был активен до него,
        // чтобы вернуть фокус после закрытия.
        rememberPrevious(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    /// Открывает просмотр. Если он уже открыт — заменяет содержимое.
    ///
    /// Выделенная картинка показывается сразу, а список для листания строится в фоне:
    /// каталог может быть большим или на сетевом диске, а список окна Finder читается сотнями AX-запросов.
    ///
    /// - Parameter finderViewItems: файлы из окна Finder в его порядке — для «Недавних», поиска и
    ///   других виртуальных окон. Если не задан или текущего файла в окне нет — листается каталог файла.
    func show(urls: [URL], finderViewItems: (@Sendable () async -> [URL])? = nil) {
        guard let preview = ImageDirectory(preview: urls) else {
            log.error("Среди открытых файлов нет изображений")
            NSSound.beep()
            return
        }
        directory = preview
        // Новый набор файлов: старая картинка не должна мелькать, пока декодируется новая.
        viewerView.clear()
        present()
        loadCurrent()

        isListPending = true
        pendingSteps = 0
        directoryTask?.cancel()
        directoryTask = Task {
            var full: ImageDirectory?
            if let finderViewItems, urls.count == 1 {
                let items = await finderViewItems()
                full = await ImageDirectory.load(ordered: items, current: preview.current)
                if full == nil {
                    log.info("Файла нет в списке окна Finder (\(items.count) эл.), листаю каталог")
                }
            }
            if full == nil {
                full = await ImageDirectory.load(opening: urls)
            }
            // Пока строился список, просмотр могли закрыть или открыть другие файлы.
            guard !Task.isCancelled, directory == preview else { return }
            isListPending = false
            if let full { directory = full }
            applyPendingSteps()
        }
    }

    private func navigate(by step: Int) {
        if isListPending {
            pendingSteps += step
            return
        }
        if directory?.move(by: step) == true { loadCurrent() }
    }

    private func applyPendingSteps() {
        let steps = pendingSteps
        pendingSteps = 0
        if steps != 0, directory?.move(by: steps) == true { loadCurrent() }
    }

    private func present() {
        if state == .hidden {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            panel.setFrame(screen.frame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        // Из .closing продолжаем с текущей прозрачности, без мигания.
        state = .visible
        // Пока просмотр открыт, Пробел должен доходить до него, а не перехватываться снова.
        interception.update { $0.isViewerVisible = true }
        panel.makeKey()
        panel.makeFirstResponder(viewerView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    /// - Parameter returnFocus: вернуть фокус приложению, из которого открыли просмотр.
    ///   Не нужно, если пользователь сам ушёл в другое приложение. При открытии из перехвата
    ///   Ementium не активируется вовсе (Finder остаётся активным), и возвращать нечего.
    private func close(returnFocus: Bool) {
        guard state == .visible else { return }
        state = .closing
        interception.update { $0.isViewerVisible = false }
        loadTask?.cancel()
        directoryTask?.cancel()
        isListPending = false
        pendingSteps = 0
        directory = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // За время затухания просмотр могли открыть снова.
                guard let self, self.state == .closing else { return }
                self.state = .hidden
                self.panel.orderOut(nil)
                self.viewerView.clear()
            }
        }
        guard returnFocus, NSApp.isActive else { return }
        if let app = previousApp, !app.isTerminated {
            app.activate()
        } else {
            // Вернуть фокус некому — уступаем его, чтобы не остаться активными без окон.
            NSApp.hide(nil)
        }
    }

    // ⌘Tab, Spotlight, клик по уведомлению: клавиши уйдут в другое приложение,
    // и висящий поверх всего оверлей было бы нечем закрыть.
    func windowDidResignKey(_ notification: Notification) {
        close(returnFocus: false)
    }

    private func handle(_ command: ViewerCommand) {
        switch command {
        case .next:
            navigate(by: 1)
        case .previous:
            navigate(by: -1)
        case .close:
            close(returnFocus: true)
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func loadCurrent() {
        guard let url = directory?.current else { return }
        let screen = panel.screen ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let frame = screen?.frame.size ?? CGSize(width: 2560, height: 1600)
        let maxPixelSize = Int(max(frame.width, frame.height) * scale)

        loadTask?.cancel()
        loadTask = Task {
            do {
                let loaded = try await ImageLoader.load(url, maxPixelSize: maxPixelSize)
                // Пока декодировали, пользователь мог перелистнуть дальше.
                guard !Task.isCancelled, directory?.current == url else { return }
                viewerView.show(loaded)
            } catch {
                guard !Task.isCancelled, directory?.current == url else { return }
                log.error("Не удалось декодировать \(url.lastPathComponent, privacy: .private)")
                viewerView.showError(fileName: url.lastPathComponent)
            }
        }
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        rememberPrevious(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func rememberPrevious(_ app: NSRunningApplication?) {
        guard let app, app != NSRunningApplication.current else { return }
        previousApp = app
    }
}
