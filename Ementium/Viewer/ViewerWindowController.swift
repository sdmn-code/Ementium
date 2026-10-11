import AppKit
import os

/// Окно просмотра. Не активирует приложение (как Spotlight), поэтому активным остаётся то,
/// из которого открыли просмотр. В режиме «следовать за Finder» не берёт и клавиатуру.
final class ViewerPanel: NSPanel {
    var acceptsKeyboard = true
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// Полноэкранный просмотр поверх всех окон.
///
/// Два режима:
/// - **следовать за Finder** — один файл, открытый Пробелом. Клавиатура остаётся у Finder, стрелки
///   уходят в Finder через перехват, а просмотр показывает то, что Finder выделил (`followed`).
///   Порядок листания — всегда порядок окна Finder.
/// - **свой список** — несколько выделенных файлов или `open -a`: панель берёт клавиатуру и листает
///   `ImageDirectory` сама.
final class ViewerWindowController: NSObject, NSWindowDelegate {
    private enum Mode {
        case ownList
        case following
    }

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
    private var mode = Mode.ownList
    private var directory: ImageDirectory?
    private var followedURL: URL?
    private var loadTask: Task<Void, Never>?
    private var directoryTask: Task<Void, Never>?
    /// Пока полный список строится, стрелки не теряются: копим шаги и применяем разом.
    private var isListPending = false
    private var pendingSteps = 0
    private var previousApp: NSRunningApplication?
    /// Источники ожидания для индикатора: Finder ищет следующую картинку / картинка декодируется.
    private var isNavigationBusy = false
    private var isDecoding = false
    private var spinnerDelay: Task<Void, Never>?
    /// Индикатор появляется, только если ожидание затянулось, — иначе он мигал бы при обычном листании.
    private static let spinnerDelayDuration = Duration.milliseconds(300)
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "viewer")

    private static let fadeDuration = 0.15

    var isFollowing: Bool { mode == .following && state == .visible }

    /// Просмотр вышел из режима «следовать» — закрылся или переключился на свой список.
    /// Мост должен перестать листать Finder.
    var onFollowingEnded: (() -> Void)?

    private var currentURL: URL? {
        mode == .following ? followedURL : directory?.current
    }

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

    /// Открывает просмотр, который листается вслед за выделением Finder.
    func showFollowing(_ url: URL) {
        directoryTask?.cancel()
        isListPending = false
        pendingSteps = 0
        directory = nil
        mode = .following
        followedURL = url
        viewerView.clear()
        present()
        loadCurrent()
    }

    /// Finder выделил другую картинку.
    func followed(_ url: URL) {
        guard isFollowing, url != followedURL else { return }
        followedURL = url
        loadCurrent()
    }

    /// Мост сообщает, что Finder ищет следующую картинку (пропускает документы).
    func setNavigationBusy(_ busy: Bool) {
        isNavigationBusy = busy && isFollowing
        updateSpinner()
    }

    private func updateSpinner() {
        guard isNavigationBusy || isDecoding else {
            spinnerDelay?.cancel()
            spinnerDelay = nil
            viewerView.setSpinning(false)
            return
        }
        guard spinnerDelay == nil, !viewerView.isSpinning else { return }
        spinnerDelay = Task {
            try? await Task.sleep(for: Self.spinnerDelayDuration)
            guard !Task.isCancelled else { return }
            spinnerDelay = nil
            if isNavigationBusy || isDecoding { viewerView.setSpinning(true) }
        }
    }

    /// Закрывает просмотр в режиме «следовать за Finder» (Esc, Пробел или Finder перестал быть активным).
    func closeFollowing() {
        guard isFollowing else { return }
        close(returnFocus: false)
    }

    /// Открывает просмотр со своим списком. Если он уже открыт — заменяет содержимое.
    ///
    /// Выделенная картинка показывается сразу, а список для листания строится в фоне:
    /// каталог может быть большим или на сетевом диске.
    func show(urls: [URL]) {
        guard let preview = ImageDirectory(preview: urls) else {
            log.error("Среди открытых файлов нет изображений")
            NSSound.beep()
            return
        }
        if isFollowing { onFollowingEnded?() }
        mode = .ownList
        followedURL = nil
        directory = preview
        // Новый набор файлов: старая картинка не должна мелькать, пока декодируется новая.
        viewerView.clear()
        present()
        loadCurrent()

        isListPending = true
        pendingSteps = 0
        directoryTask?.cancel()
        directoryTask = Task {
            let full = await ImageDirectory.load(opening: urls)
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
        let following = mode == .following
        // Пока просмотр открыт, Пробел должен закрывать его, а не открывать снова;
        // в режиме «следовать» все нажатия разбирает перехват.
        interception.update {
            $0.isViewerVisible = true
            $0.isFollowingFinder = following
        }
        panel.acceptsKeyboard = !following
        if !following {
            panel.makeKey()
            panel.makeFirstResponder(viewerView)
        }
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
        if mode == .following { onFollowingEnded?() }
        state = .closing
        interception.update {
            $0.isViewerVisible = false
            $0.isFollowingFinder = false
        }
        loadTask?.cancel()
        directoryTask?.cancel()
        isNavigationBusy = false
        isDecoding = false
        updateSpinner()
        isListPending = false
        pendingSteps = 0
        directory = nil
        followedURL = nil
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
    // В режиме «следовать» панель не бывает ключевой — там закрывает AppDelegate, когда Finder неактивен.
    func windowDidResignKey(_ notification: Notification) {
        guard mode == .ownList else { return }
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
        guard let url = currentURL else { return }
        let screen = panel.screen ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let frame = screen?.frame.size ?? CGSize(width: 2560, height: 1600)
        let maxPixelSize = Int(max(frame.width, frame.height) * scale)

        loadTask?.cancel()
        isDecoding = true
        updateSpinner()
        loadTask = Task {
            do {
                let loaded = try await ImageLoader.load(url, maxPixelSize: maxPixelSize)
                // Пока декодировали, пользователь мог перелистнуть дальше.
                guard !Task.isCancelled, currentURL == url else { return }
                isDecoding = false
                updateSpinner()
                viewerView.show(loaded)
            } catch {
                guard !Task.isCancelled, currentURL == url else { return }
                isDecoding = false
                updateSpinner()
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
