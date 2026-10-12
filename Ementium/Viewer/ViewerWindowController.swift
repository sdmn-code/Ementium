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
    /// Текущая и соседние картинки, декодированные под экран.
    private let cache = ImageCache()
    /// Кадры анимированной картинки (первый кадр — из кэша, как у обычных).
    private let animator = ImageAnimator()
    /// Текущая картинка в том разрешении, в каком она показана, — от неё решаем, нужно ли больше деталей.
    private var loaded: DecodedImage?
    /// На экране встроенное превью RAW, полная версия ещё грузится.
    private var showsPreview = false
    /// Файл, картинка которого сейчас на экране (пока грузится следующая, видна прежняя).
    private var displayedURL: URL?
    /// Масштаб и место увеличенных картинок — до закрытия просмотра.
    private var zoomMemory = ZoomMemory()
    /// Сведения о снимке по удержанию `⌥`.
    private var infoHold = InfoHoldTracker()
    private var infoTimer: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    /// Уже прочитанные сведения — до закрытия просмотра (листаешь туда-обратно с `⌥`).
    private var infoCache: [URL: [String]] = [:]
    /// Деталь, которую сервис не смог декодировать (таймаут, падение, нет памяти), — не повторять на каждое
    /// движение пальцев, пока просмотр открыт.
    private var detailFailed: Set<URL> = []
    /// Фоновая загрузка оригинала в полном разрешении (при увеличении сверх декодированного).
    private var detailTask: Task<Void, Never>?

    /// Настройки на момент открытия просмотра.
    private var preferences = ViewerPreferences()
    private var directoryTask: Task<Void, Never>?
    /// Пока полный список строится, стрелки не теряются: копим шаги и применяем разом.
    private var isListPending = false
    private var pendingSteps = 0
    private var previousApp: NSRunningApplication?
    /// Источники ожидания для индикатора: Finder ищет следующую картинку / картинка декодируется.
    private var isNavigationBusy = false
    private var isDecoding = false
    /// Отдельно от `isDecoding`: детали и картинка под экран завершаются независимо, и одна не должна
    /// гасить индикатор другой.
    private var isLoadingDetail = false
    /// Размер декодирования под экран (длинная сторона экрана в пикселях) — фиксируется при открытии,
    /// чтобы кэш не получал разные размеры от разных вызовов.
    private var decodeSize = 5120
    private var spinnerDelay: Task<Void, Never>?
    /// Индикатор появляется, только если ожидание затянулось, — иначе он мигал бы при обычном листании.
    private static let spinnerDelayDuration = Duration.milliseconds(300)
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "viewer")

    private static let fadeDuration = 0.15

    var isFollowing: Bool { mode == .following && state == .visible }

    /// `⌘,` в режиме «свой список» (в режиме «следовать» — через перехват): открыть настройки.
    var onOpenSettings: (() -> Void)?

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
        viewerView.onModifiersChanged = { [weak self] modifiers in self?.input(.modifiers(modifiers)) }
        viewerView.onKeyPressed = { [weak self] isArrow in self?.input(.keyPressed(isArrow: isArrow)) }
        viewerView.onZoomChanged = { [weak self] zoom in self?.loadDetailIfNeeded(for: zoom) }

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
        rememberDisplayedZoom()
        displayedURL = nil
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

    /// Режим «следовать»: файл, выделенный в Finder, — только если на экране именно он. Пока новая картинка
    /// декодируется, видна прежняя — удалять в этот момент нельзя: пользователь удалил бы то, чего не видел.
    var displayedFollowedImage: URL? {
        guard isFollowing, let followedURL, displayedURL == followedURL, loaded != nil else { return nil }
        return followedURL
    }

    /// Режим «следовать»: файл, выделенный в Finder (даже если ещё не показан).
    var followedFile: URL? {
        isFollowing ? followedURL : nil
    }

    /// Короткое сообщение внизу экрана («В Корзине», «Здесь нет Корзины…»).
    func showMessage(_ text: String) {
        guard state == .visible else { return }
        viewerView.showMessage(text)
    }

    /// Мост сообщает, что Finder ищет следующую картинку (пропускает документы).
    func setNavigationBusy(_ busy: Bool) {
        isNavigationBusy = busy && isFollowing
        updateSpinner()
    }

    private func updateSpinner() {
        guard isNavigationBusy || isDecoding || isLoadingDetail else {
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
            if isNavigationBusy || isDecoding || isLoadingDetail { viewerView.setSpinning(true) }
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
        rememberDisplayedZoom()
        displayedURL = nil
        viewerView.clear()
        // Пока полный список строится, соседей ещё нет — предзагрузка начнётся, когда он будет готов.
        isListPending = true
        pendingSteps = 0
        present()
        loadCurrent()

        directoryTask?.cancel()
        directoryTask = Task {
            let full = await ImageDirectory.load(opening: urls)
            // Пока строился список, просмотр могли закрыть или открыть другие файлы.
            guard !Task.isCancelled, directory == preview else { return }
            isListPending = false
            if let full { directory = full }
            applyPendingSteps()
            prefetchFromDirectory()
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
        DecoderClient.shared.viewerOpened()
        if state == .hidden {
            // Настройки могли поменять, пока просмотр был закрыт.
            preferences = ViewerPreferences()
            viewerView.apply(preferences)
            zoomMemory.isEnabled = preferences.rememberZoomPerImage
            interception.update {
                $0.spaceClosesViewer = preferences.spaceClosesViewer
                $0.trashEnabled = preferences.trashEnabled
            }
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            panel.setFrame(screen.frame, display: false)
            decodeSize = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
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
            context.duration = fadeDuration
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
        // Через некоторое время сервис декодирования отпускается и завершается — с кэшами декодеров.
        DecoderClient.shared.releaseSoon()
        interception.update {
            $0.isViewerVisible = false
            $0.isFollowingFinder = false
        }
        cache.clear()
        animator.stop()
        detailTask?.cancel()
        detailTask = nil
        loaded = nil
        showsPreview = false
        displayedURL = nil
        zoomMemory.forget()
        run(infoHold.reset())
        infoTask?.cancel()
        infoCache.removeAll()
        detailFailed.removeAll()
        directoryTask?.cancel()
        isNavigationBusy = false
        isDecoding = false
        isLoadingDetail = false
        updateSpinner()
        isListPending = false
        pendingSteps = 0
        directory = nil
        followedURL = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
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
        case .zoomIn, .zoomOut, .zoomFit:
            viewerView.perform(command)
        case .openSettings:
            close(returnFocus: false)
            onOpenSettings?()
        case .trash:
            // Удаление — через Finder, а здесь Finder не знает, что показано.
            if preferences.trashEnabled { viewerView.showMessage("Удаление — когда картинка открыта Пробелом в Finder") }
        case .undo:
            break
        }
    }

    /// Плавное появление и исчезновение — по настройке.
    private var fadeDuration: Double { preferences.animate ? Self.fadeDuration : 0 }

    /// Жест трекпада из перехвата (режим «следовать за Finder»): масштаб в точке под курсором.
    func gesture(_ gesture: ViewerGesture) {
        guard state == .visible else { return }
        let location = NSEvent.mouseLocation
        switch gesture {
        case .magnify(let magnification):
            viewerView.magnify(by: magnification, atScreenPoint: location)
        case .smartMagnify:
            viewerView.smartMagnify(atScreenPoint: location)
        }
    }

    /// Масштаб из перехвата (режим «следовать за Finder»: клавиатура у Finder).
    func zoom(_ command: ViewerCommand) {
        guard state == .visible else { return }
        viewerView.perform(command)
    }

    /// При увеличении сверх декодированного разрешения — декодировать оригинал в фоне (до ~100 Мп),
    /// пока показывая то, что есть. Без этого при 200–400 % было бы мыло.
    private func loadDetailIfNeeded(for zoom: ZoomModel) {
        // Анимация и так в исходном размере — кадры приходят из файла, деталь не нужна.
        guard let url = currentURL, let current = loaded, !current.isAnimated, detailTask == nil,
              !detailFailed.contains(url) else { return }
        let backingScale = panel.screen?.backingScaleFactor ?? 2
        let shownLongSide = max(zoom.imageRect.width, zoom.imageRect.height) * backingScale
        let limit = ImageLoader.fullResolutionLimit(for: current.pixelSize)
        // Уже показано не хуже нужного — или лучше уже не будет.
        guard shownLongSide > CGFloat(current.decodedLongSide) * 1.05,
              current.decodedLongSide < limit else { return }
        // Растр — сразу оригинал. Вектор перерисовываем под нужный масштаб (с запасом), а не до предела:
        // 100 Мп на каждый SVG — это 400 МБ и заметная пауза.
        let target = current.isVector ? min(limit, Int((shownLongSide * 1.5).rounded(.up))) : limit

        isLoadingDetail = true
        updateSpinner()
        detailTask = Task {
            let detailed = try? await DecoderClient.shared.decode(url, maxPixelSize: target)
            guard !Task.isCancelled, currentURL == url else { return }
            detailTask = nil
            isLoadingDetail = false
            updateSpinner()
            guard let detailed else {
                detailFailed.insert(url)
                return
            }
            loaded = detailed
            viewerView.upgrade(detailed.surface)
        }
    }

    private func loadCurrent() {
        guard let url = currentURL else { return }
        animator.stop()
        detailTask?.cancel()
        detailTask = nil
        isLoadingDetail = false
        // `loaded` — всегда картинка текущего файла: по ней решаем, нужны ли детали при увеличении.
        loaded = nil
        showsPreview = false
        // Готовая (предзагруженная) картинка придёт синхронно, прямо из этого вызова.
        cache.request(url, maxPixelSize: decodeSize) { [weak self] update in
            self?.apply(update, for: url)
        }
        // Ничего не пришло сразу — ждём декодирования (индикатор появится, если оно затянется).
        isDecoding = loaded == nil
        updateSpinner()
        // Держишь `⌥` и листаешь — сведения следуют за картинкой.
        if infoHold.state == .shown { updateInfo() }
        log.info("Показ: \(self.loaded == nil ? "декодирование" : "из кэша", privacy: .public) (\(self.mode == .following ? "следовать" : "свой список", privacy: .public))")
        if mode == .ownList { prefetchFromDirectory() }
    }

    private func apply(_ update: ImageCache.Update, for url: URL) {
        // Пока декодировали, пользователь мог перелистнуть дальше.
        guard state == .visible, currentURL == url else { return }
        switch update {
        case .preview(let preview):
            // RAW: сначала встроенное превью (~10 мс), сам RAW под экран — следом, подменой.
            isDecoding = false
            updateSpinner()
            loaded = preview
            showsPreview = true
            display(preview, for: url)
        case .final(let image):
            isDecoding = false
            updateSpinner()
            if showsPreview {
                // Показанное не хуже нового — оставляем: пока смотрели превью, увеличение могло подгрузить
                // оригинал, а у Nikon окончательная версия — то же полноразмерное превью.
                if let current = loaded, current.decodedLongSide >= image.decodedLongSide {
                    if let zoom = viewerView.zoom { loadDetailIfNeeded(for: zoom) }
                    return
                }
                loaded = image
                viewerView.upgrade(image.surface)
            } else {
                loaded = image
                display(image, for: url)
            }
            if image.isAnimated {
                // Кадры подставляются без анимации CoreAnimation и без смены масштаба.
                animator.start(url, maxPixelSize: decodeSize) { [weak self] frame in
                    guard let self, state == .visible, currentURL == url else { return }
                    viewerView.upgrade(frame)
                }
            }
            // Масштаб восстановлен из памяти или увеличили на превью —
            // может понадобиться больше деталей (при «вписать» проверка сразу выйдет).
            if let zoom = viewerView.zoom { loadDetailIfNeeded(for: zoom) }
        case .failed(let error):
            // Превью уже на экране — лучше оно, чем сообщение об ошибке.
            fail(url, error: error, keepShown: showsPreview)
        }
    }

    /// Показать картинку `url`: сначала запомнить масштаб показанной, потом поставить новую —
    /// с её запомненным масштабом или во «вписать».
    /// Та же картинка заново (файл поменяли, пока смотрели) так сохраняет свой масштаб.
    private func display(_ image: DecodedImage, for url: URL) {
        rememberDisplayedZoom()
        viewerView.show(image, placement: zoomMemory.placement(for: url))
        displayedURL = url
    }

    // MARK: - Сведения о снимке

    /// Модификаторы и нажатия: в режиме «свой список» — от панели, в режиме «следовать» — от перехвата.
    func input(_ input: ViewerInput) {
        guard state == .visible else { return }
        switch input {
        case .modifiers(let modifiers): run(infoHold.modifiersChanged(modifiers))
        case .keyPressed(let isArrow): run(infoHold.keyPressed(isArrow: isArrow))
        }
    }

    private func run(_ outputs: [InfoHoldTracker.Output]) {
        for output in outputs {
            switch output {
            case .startTimer:
                infoTimer?.cancel()
                infoTimer = Task {
                    try? await Task.sleep(for: InfoHoldTracker.delay)
                    guard !Task.isCancelled else { return }
                    run(infoHold.timerFired())
                }
            case .cancelTimer:
                infoTimer?.cancel()
                infoTimer = nil
            case .show:
                updateInfo()
            case .hide:
                infoTask?.cancel()
                viewerView.hideInfo()
            }
        }
    }

    /// Сведения о текущей картинке: из памяти сразу, иначе — прочитать (без декодирования, миллисекунды).
    private func updateInfo() {
        guard let url = currentURL else { return }
        infoTask?.cancel()
        if let lines = infoCache[url] {
            viewerView.showInfo(lines)
            return
        }
        infoTask = Task {
            let lines = await DecoderClient.shared.metadata(url)
            guard !Task.isCancelled, state == .visible, currentURL == url, infoHold.state == .shown else { return }
            if let lines {
                infoCache[url] = lines
                viewerView.showInfo(lines)
            } else {
                // Сервис не ответил — хотя бы имя файла; не кэшируем, в следующий раз спросим снова.
                viewerView.showInfo([url.lastPathComponent])
            }
        }
    }

    /// Уходим с показанной картинки: увеличенную запоминаем, во «вписать» — забываем.
    private func rememberDisplayedZoom() {
        guard let displayedURL, let zoom = viewerView.zoom else { return }
        zoomMemory.remember(zoom, for: displayedURL)
    }

    /// Свой список: соседи известны сразу. Пока полный список строится, соседей нет — позовём ещё раз.
    private func prefetchFromDirectory() {
        guard let directory, !isListPending else { return }
        let images = directory.images
        let neighbors = PrefetchWindow.neighbors(
            of: directory.index, count: images.count, url: { images[$0] }, isImage: { _ in true }
        )
        cache.prefetch(neighbors, around: directory.current, maxPixelSize: decodeSize)
    }

    /// Режим «следовать»: Finder встал на `current`, мост прочитал соседей в порядке окна.
    func followedNeighbors(_ neighbors: [URL], around current: URL) {
        guard isFollowing, current == followedURL else { return }
        cache.prefetch(neighbors, around: current, maxPixelSize: decodeSize)
    }

    private func fail(_ url: URL, error: Error, keepShown: Bool) {
        isDecoding = false
        updateSpinner()
        // Имя файла — скрыто настройками приватности логов, остальное — открыто: по нему и ищем причину.
        let details = ImageLoader.failureDescription(url, error: error)
        log.error("Не удалось декодировать \(url.lastPathComponent, privacy: .private) — \(details, privacy: .public)")
        guard !keepShown else { return }
        animator.stop()
        loaded = nil
        rememberDisplayedZoom()
        displayedURL = nil
        viewerView.showError(fileName: url.lastPathComponent)
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        rememberPrevious(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func rememberPrevious(_ app: NSRunningApplication?) {
        guard let app, app != NSRunningApplication.current else { return }
        previousApp = app
    }
}
