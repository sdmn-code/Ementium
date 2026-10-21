import AppKit
import VisionKit
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

    /// Пересоздаётся, если WindowServer «потерял» окно (`rebuildPanel`).
    private var panel: ViewerPanel
    /// Проверка после показа: панель действительно на экране.
    private var panelCheck: Task<Void, Never>?
    private let viewerView = ViewerView(frame: .zero)
    private let interception: InterceptionState
    private var state = State.hidden
    private var mode = Mode.ownList
    private var directory: ImageDirectory?
    private var followedURL: URL?
    /// Соседи показанной картинки в режиме «следовать» (от моста) — для смахивания.
    private var followNeighbors: (around: URL, neighbors: PrefetchWindow.Neighbors)?
    /// Смахивание опережает Finder: показана `swipeLead`, а мост ещё выделяет её. Прочие его сообщения
    /// (прежние смахивания) пропускаем, иначе быстрое смахивание мигнёт назад. Не выделил за
    /// `swipeLeadTime` (был занят) — показываем то, что выделено в Finder.
    private var swipeLead: URL?
    private var swipeLeadCheck: Task<Void, Never>?
    private static let swipeLeadTime: Duration = .seconds(2)
    /// Где, по последнему сообщению моста, стоит выделение Finder, и последние соседи от моста (как есть,
    /// без пересчёта) — к ним возвращается `settleSwipeLead`.
    private var finderURL: URL?
    private var finderNeighbors: (around: URL, neighbors: PrefetchWindow.Neighbors)?
    /// Листаем к началу списка — предзагрузка готовит картинки с той стороны.
    private var travelsBackward = false
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
    /// Live Text по удержанию `⌘`: распознавание показанной картинки, кнопки VisionKit и «Поделиться».
    private var liveHold = LiveTextHoldTracker()
    private var liveTimer: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private let liveAnalyzer = LiveTextAnalyzer()
    /// Что распознано: поверхность, поворот и часть картинки — по ним видно, распознавать ли заново (подгрузилась
    /// деталь, повернули, увеличили или сдвинули видимое).
    private struct LiveKey: Equatable {
        let surface: ObjectIdentifier
        let quarterTurns: Int
        let crop: CGRect
    }
    private var liveKey: LiveKey?
    private var isAnalyzing = false
    /// Масштаб и сдвиг улеглись — в режиме распознать видимую часть заново.
    private var liveViewSettle: Task<Void, Never>?
    /// `⌘L`: открыть «Поиск по изображению», когда распознавание закончится.
    private var lookUpPending = false
    /// Открытое меню «Поделиться» и работающий сервис (окна AirDrop — свои, их не трогаем).
    private var sharePicker: NSSharingServicePicker?
    private(set) var isSharing = false
    /// Работающая служба — чтобы при закрытии просмотра отменить её (`SharingSheet.dismiss`).
    private var sharingService: NSSharingService?
    /// Щелчки по просмотру — для окон VisionKit (карточка контакта, просмотр ссылки).
    private var mouseMonitor: Any?
    /// Окна VisionKit, уже записанные в журнал.
    private var loggedAuxiliaryWindows: Set<ObjectIdentifier> = []
    /// Всплывающие окна VisionKit — карточка контакта (`DDActionViewController`).
    private var popovers: [NSPopover] = []
    /// Просмотр ссылки показывает другой процесс; в режиме «следовать» — окном уровня 101, под панелью: его номер,
    /// пока оно открыто.
    private var foreignPreview: Int?
    private var foreignPreviewWatch: Task<Void, Never>?
    /// Закрыть просмотр ссылки уже попросили — окно ещё гаснет.
    private var linkPreviewClosing = false
    /// Щелчок, закрывший просмотр ссылки, поглощён — поглотить и его отпускание.
    private var swallowsMouseUp = false
    /// Что вернуть по `⌘Z` — действия над файлами в этом сеансе просмотра.
    private var sessionUndo = SessionUndo()
    /// Слайд-шоу (`S`): автомат, его таймер и запрет сна дисплея; следующая смена кадра — растворением.
    private var slideshow = SlideshowClock(interval: .seconds(4))
    private var slideshowTimer: Task<Void, Never>?
    private var slideshowStallWatch: Task<Void, Never>?
    /// Сколько шагов подряд край в режиме «следовать» не подтверждён мостом (см. `followEdgeNeighbors`).
    private var slideshowEdgeWaits = 0
    /// Сколько ждать картинку после шага в режиме «следовать» (не считая декодирования), прежде чем шагнуть заново.
    private static let slideshowStallTime = Duration.seconds(4)
    private var slideshowActivity: NSObjectProtocol?
    private var crossfadeNext = false
    /// Метки: имена цветных тегов на языке системы (порядок меню Finder) — определяются при открытии просмотра.
    private var tagNamesTask: Task<[String?], Never>?
    private var resolvedTagNames: [String?]?
    /// Теги показанной и соседних картинок — читаются заранее, вместе с предзагрузкой: точки меняются в том же
    /// кадре, что и картинка.
    private var tagCache: [URL: [String]] = [:]
    private var tagReads: [URL: Task<Void, Never>] = [:]
    /// Нажатия цифр и `⌘Z` — строго по очереди: прочитать, переключить, записать; `⌘Z` не обгоняет запись.
    private var tagQueue: Task<Void, Never>?
    /// Сеанс меток: закрыли или открыли новое поверх — хвост прежней очереди ничего не пишет и не запоминает.
    private var tagSession = 0
    /// Зажатая стрелка: точки покажутся через 0,3 с после последнего повтора.
    private var tagDotsRelease: Task<Void, Never>?
    /// Режим «следовать»: метку записали — мост проверит выделение Finder (группировка, смарт-список тега).
    /// `removed` — снятые метки: файл может уйти из смарт-списка тега.
    var onTagged: ((_ url: URL, _ removed: [String]) -> Void)?
    /// Режим «следовать»: `⌘Z` вернул метки файлу, которого нет на экране, — мост покажет его снова.
    var onTagRestored: ((URL) -> Void)?
    /// `⌘Z` дошёл до удаления — его отменяет мост Finder.
    var onUndoTrash: ((URL) -> Void)?
    /// Режим «следовать»: панель взяла клавиатуру на время щелчка по «пилюле» — вернуть, когда появится просмотр
    /// ссылки (или по таймеру).
    private var keyboardLoan: Task<Void, Never>?

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

    /// Появление и исчезновение просмотра (настройка «Плавное появление и исчезновение»): за 0,15 с затухание
    /// на тёмном оверлее было незаметно.
    private static let fadeDuration = 0.35

    var isFollowing: Bool { mode == .following && state == .visible }

    /// Режим «следовать»: смахнули на картинку — выделить её в Finder. `false` — не отправлено
    /// (Finder уже не активен).
    var onFollowSelect: ((URL) -> Bool)?
    /// Вернулись к выделению Finder — мосту прочитать соседей заново.
    var onFollowResync: (() -> Void)?
    /// Слайд-шоу в режиме «следовать»: к первой картинке окна Finder (зацикливание, старт с последней). `false` —
    /// не отправлено (Finder уже не активен).
    var onFollowEdge: ((_ first: Bool) -> Bool)?

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
        panel = Self.makePanel()
        super.init()

        panel.contentView = viewerView
        panel.delegate = self

        viewerView.onCommand = { [weak self] command in self?.handle(command) }
        viewerView.swipeNeighbor = { [weak self] forward in self?.swipeNeighbor(forward: forward) ?? .none }
        viewerView.onSwipe = { [weak self] forward in self?.manualSwiped(forward: forward) ?? false }
        viewerView.onSlideshowKey = { [weak self] key in self?.slideshowKey(key) }
        viewerView.onKeyPressed = { [weak self] isArrow in self?.input(.keyPressed(isArrow: isArrow)) }
        viewerView.onArrowHeld = { [weak self] in self?.input(.arrowHeld) }
        viewerView.onZoomChanged = { [weak self] zoom in self?.loadDetailIfNeeded(for: zoom) }
        viewerView.onShare = { [weak self] in self?.share() }
        viewerView.onLiveTextLatch = { [weak self] latched in self?.liveTextLatched(latched) }
        viewerView.onViewChanged = { [weak self] in self?.liveViewChanged() }

        // `open -a` активирует Ementium, поэтому запоминаем, кто был активен до него,
        // чтобы вернуть фокус после закрытия.
        rememberPrevious(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    private static func makePanel() -> ViewerPanel {
        let panel = ViewerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
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
        return panel
    }

    /// Открывает просмотр, который листается вслед за выделением Finder.
    func showFollowing(_ url: URL) {
        runSlideshow(slideshow.reset())
        resetLiveText()
        directoryTask?.cancel()
        isListPending = false
        pendingSteps = 0
        directory = nil
        mode = .following
        followedURL = url
        finderURL = url
        finderNeighbors = nil
        followNeighbors = nil
        dropSwipeLead()
        travelsBackward = false
        rememberDisplayedZoom()
        displayedURL = nil
        viewerView.clear()
        present()
        loadCurrent()
    }

    /// Finder выделил другую картинку.
    func followed(_ url: URL) {
        finderURL = url
        if let swipeLead, url != swipeLead { return }
        dropSwipeLead()
        follow(url)
    }

    /// Finder выделил `url` сам (после удаления), а просмотр уже ушёл смахиванием — запомнить, где выделение:
    /// к нему вернётся `settleSwipeLead`, если смахивание не дойдёт.
    func finderMoved(to url: URL) {
        guard isFollowing else { return }
        finderURL = url
    }

    /// Пользователь нажал стрелку (Home/End, ⌘⌫, ⌘Z) — дальше ведёт Finder, смахивание больше не ждём.
    func dropSwipeLead() {
        swipeLead = nil
        swipeLeadCheck?.cancel()
        swipeLeadCheck = nil
    }

    /// Finder так и не дошёл до показанной смахиванием картинки — показать то, что выделено в нём:
    /// иначе Esc, `⌘⌫` и стрелки работали бы не с той картинкой, что на экране.
    private func settleSwipeLead() {
        guard swipeLead != nil else { return }
        dropSwipeLead()
        guard let finderURL, finderURL != followedURL else { return }
        log.info("Смахивание: Finder не дошёл до показанной картинки — возвращаемся к его выделению")
        let shown = followNeighbors
        follow(finderURL)
        // Соседи той, где стоит Finder: последние от моста или пересчитанные от показанной — иначе смахивать
        // было бы некуда, пока мост не пришлёт новых (а сам он их не пришлёт: в Finder ничего не менялось).
        if let finderNeighbors, finderNeighbors.around == finderURL {
            followNeighbors = finderNeighbors
        } else if let shown, let back = shown.neighbors.recentered(around: shown.around, to: finderURL) {
            followNeighbors = (finderURL, back)
        }
        prefetchFollowNeighbors()
        onFollowResync?()
    }

    private func follow(_ url: URL) {
        guard isFollowing, url != followedURL else { return }
        if let known = followNeighbors, known.around == followedURL {
            if url == known.neighbors.previous { travelsBackward = true }
            if url == known.neighbors.next { travelsBackward = false }
        }
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
        guard isNavigationBusy || isDecoding || isLoadingDetail || isAnalyzing else {
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
            if isNavigationBusy || isDecoding || isLoadingDetail || isAnalyzing { viewerView.setSpinning(true) }
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
        runSlideshow(slideshow.reset())
        resetLiveText()
        mode = .ownList
        followedURL = nil
        travelsBackward = false
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

    /// `true` — перешли и начали показ новой картинки.
    @discardableResult
    private func navigate(by step: Int) -> Bool {
        travelsBackward = step < 0
        if isListPending {
            pendingSteps += step
            return false
        }
        guard directory?.move(by: step) == true else { return false }
        loadCurrent()
        return true
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
                $0.tagsEnabled = preferences.tags
            }
            tagNamesTask = preferences.tags ? Task { await FileTagger.colorTagNames() } : nil
            slideshow = SlideshowClock(interval: .seconds(preferences.slideshowInterval))
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            panel.setFrame(screen.frame, display: false)
            decodeSize = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            if !panel.isOnActiveSpace { rebuildPanel(reason: "не на текущем рабочем столе") }
            verifyPanelOnScreen()
        }
        // Из .closing продолжаем с текущей прозрачности, без мигания.
        state = .visible
        panel.ignoresMouseEvents = false
        watchAuxiliaryWindows()
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
        // Гаснущая панель ещё лежит поверх всех окон — клики и прокрутка должны уходить сквозь неё.
        panel.ignoresMouseEvents = true
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
        runLive(liveHold.reset())
        forgetLiveText()
        lookUpPending = false
        panelCheck?.cancel()
        panelCheck = nil
        runSlideshow(slideshow.reset())
        sharePicker?.close()
        sharePicker = nil
        // Лист AirDrop — дочернее окно панели: со скрытием панели он только прячется и всплывает в следующем
        // просмотре (⌘Tab во время AirDrop). Отменяем саму службу.
        if isSharing, let sharingService {
            let dismissed = SharingSheet.dismiss(sharingService)
            log.notice("«Поделиться»: просмотр закрыт во время службы, отмена — \(dismissed ? "да" : "нечем", privacy: .public)")
        }
        sharingService = nil
        isSharing = false
        panel.level = .screenSaver
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didUpdateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSPopover.didShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: nil)
        popovers.forEach { $0.close() }
        popovers.removeAll()
        foreignPreviewWatch?.cancel()
        foreignPreviewWatch = nil
        foreignPreview = nil
        linkPreviewClosing = false
        swallowsMouseUp = false
        returnKeyboard()
        sessionUndo.clear()
        forgetTags()
        liveViewSettle?.cancel()
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
        finderURL = nil
        finderNeighbors = nil
        followNeighbors = nil
        dropSwipeLead()
        travelsBackward = false
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
        // Клавиатура ушла в другое окно Ementium — окно AirDrop, карточку VisionKit: просмотр остаётся. Новое
        // ключевое окно известно уже после этого уведомления — проверяем следующим проходом.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == .visible, self.mode == .ownList, !self.panel.isKeyWindow else { return }
            if let key = NSApp.keyWindow, key !== self.panel { return }
            self.close(returnFocus: false)
        }
    }

    private func handle(_ command: ViewerCommand) {
        switch command {
        case .next, .previous:
            crossfadeNext = false
            let moved = navigateWrapping(forward: command == .next)
            slideshowManualStep(imagePending: moved && isDecoding)
        case .close:
            if closeLiveWindows() { return }
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
            viewerView.showMessage(preferences.trashEnabled
                ? String(localized: "Deleting works when the image was opened with Space in Finder")
                : String(localized: "Moving to Trash is off — turn it on in Settings"))
        case .undo:
            undo()
        case .first, .last:
            if isListPending { return }
            if directory?.moveToEdge(first: command == .first) == true { loadCurrent() }
        case .rotateClockwise, .rotateCounterclockwise:
            rotate(clockwise: command == .rotateClockwise)
        case .copy:
            copyCurrent()
        case .openInApp:
            openCurrentInApp()
        case .lookUp:
            lookUp()
        case .share:
            share()
        case .tag(let number):
            toggleTag(number)
        case .slideshow:
            toggleSlideshow()
        }
    }

    // MARK: - Отмена

    /// Действие над файлом сделано — `⌘Z` его отменит.
    func recordUndo(_ entry: SessionUndo.Entry) {
        guard state == .visible else { return }
        sessionUndo.record(entry)
    }

    /// `⌘Z` в обоих режимах: отменить последнее действие сеанса.
    func undo() {
        guard state == .visible else { return }
        // Через очередь меток: цифра, сразу ⌘Z — запись об этой метке появится в истории раньше, чем её снимут.
        enqueueTagWork { session in
            guard let entry = self.sessionUndo.undo() else {
                self.showMessage(String(localized: "Nothing to restore"))
                return
            }
            switch entry {
            case .trash(let url):
                self.onUndoTrash?(url)
            case .tags(let url, let before):
                await self.restoreTags(before, at: url, session: session)
            case .move, .copy:
                break  // перемещение в папки — следующая функция
            }
        }
    }

    // MARK: - Метки

    /// `1`–`7` — переключить метку (цветной тег Finder) на показанном файле. Метки складываются; сообщения об успехе
    /// нет — метку видно по точкам; ошибки — плашкой.
    func toggleTag(_ number: Int) {
        guard state == .visible, preferences.tags, (1...7).contains(number) else { return }
        guard let url = displayedTagFile else {
            showMessage(String(localized: "Image is still loading"))
            return
        }
        enqueueTagWork { session in
            guard let name = await self.tagNames()[number - 1] else {
                self.showMessage(String(localized: "Label unavailable: add the color tag back in Finder settings"))
                return
            }
            guard self.tagSession == session else { return }
            do {
                let result = try await FileTagger.toggle(name, at: url)
                guard self.state == .visible, self.tagSession == session else { return }
                self.recordUndo(.tags(url: url, before: result.before))
                self.tagsChanged(result.after, of: url)
                if self.mode == .following { self.onTagged?(url, TagToggle.contains(result.after, name) ? [] : [name]) }
            } catch {
                self.showTagFailure(error)
            }
        }
    }

    /// `⌘Z` по метке: вернуть теги файла, какими были до нажатия. Файл не на экране (пролистали дальше, ушёл из
    /// смарт-списка тега) — показать его снова, как при отмене удаления: в «следовать» через мост, в своём списке сразу.
    private func restoreTags(_ tags: [String], at url: URL, session: Int) async {
        do {
            // Что снимается: прежние теги из памяти, которых нет в возвращаемых (мост подождёт Finder).
            let removed = (tagCache[url] ?? []).filter { !TagToggle.contains(tags, $0) }
            let after = try await FileTagger.restore(tags, at: url)
            guard state == .visible, tagSession == session else { return }
            tagsChanged(after, of: url)
            if mode == .following {
                // Как отмена удаления: вернувшийся файл выделяется в Finder и показывается.
                if url == followedURL { onTagged?(url, removed) } else { onTagRestored?(url) }
            } else if url != displayedURL, let directory, let target = directory.images.firstIndex(of: url),
                      self.directory?.move(by: target - directory.index) == true {
                // Свой список — так же: показать файл, которому вернули метки.
                loadCurrent()
            }
        } catch {
            showTagFailure(error)
        }
    }

    /// Нажатия по очереди: две цифры подряд не должны прочитать один и тот же список и затереть друг друга.
    /// `work` получает сеанс — после каждого ожидания свериться, что он ещё тот.
    private func enqueueTagWork(_ work: @escaping @MainActor (_ session: Int) async -> Void) {
        let previous = tagQueue
        let session = tagSession
        tagQueue = Task {
            await previous?.value
            guard self.state == .visible, self.tagSession == session else { return }
            await work(session)
        }
    }

    /// Файл, который на экране: в своём списке — текущий, если он уже показан.
    private var displayedTagFile: URL? {
        if mode == .following { return displayedFollowedImage }
        guard let url = displayedURL, url == directory?.current, loaded != nil else { return nil }
        return url
    }

    private func tagNames() async -> [String?] {
        if let resolvedTagNames { return resolvedTagNames }
        let task = tagNamesTask ?? Task { await FileTagger.colorTagNames() }
        tagNamesTask = task
        let names = await task.value
        if state == .visible { resolvedTagNames = names }
        return names
    }

    private func showTagFailure(_ error: Error) {
        guard state == .visible else { return }
        switch FileTagger.failure(error) {
        case .noPermission: showMessage(String(localized: "Can't change labels of this file"))
        case .readOnlyVolume: showMessage(String(localized: "The disk is read-only"))
        case .missing: showMessage(String(localized: "File not found"))
        case .other: showMessage(String(localized: "Couldn't set the label"))
        }
    }

    /// Теги файла поменялись (метка, `⌘Z`): точки и строка «Метки» в карточке — сразу.
    private func tagsChanged(_ tags: [String], of url: URL) {
        // Чтение, начатое до записи, принесло бы прежний список.
        tagReads[url]?.cancel()
        tagReads[url] = nil
        tagCache[url] = tags
        if url == displayedURL { showTagDots(for: url) }
        if infoHold.state == .shown, url == currentURL { updateInfo() }
    }

    /// Цветные метки файла — индексы цветов в порядке меню Finder и имена, в порядке тегов файла.
    private func colorLabels(of url: URL) -> [(color: Int, name: String)]? {
        guard let tags = tagCache[url], let names = resolvedTagNames else { return nil }
        return tags.compactMap { tag in
            names.firstIndex { $0.map { TagToggle.same($0, tag) } ?? false }.map { ($0, tag) }
        }
    }

    /// Точки показанного файла: известны — сразу; нет — прежние убираются, новые придут после чтения (неверные
    /// точки не показываются никогда).
    private func showTagDots(for url: URL) {
        guard preferences.tags, let labels = colorLabels(of: url) else {
            viewerView.setTagDots([], names: [])
            if preferences.tags { prefetchTags([url], prune: false) }
            return
        }
        viewerView.setTagDots(labels.map { FileTagger.menuOrderNSColors[$0.color] }, names: labels.map(\.name))
    }

    /// Строка «Метки: Красный, Синий» для карточки сведений — пока она открыта, точки спрятаны.
    private func tagInfoLines(for url: URL) -> [String] {
        guard preferences.tags, let labels = colorLabels(of: url), !labels.isEmpty else { return [] }
        return [String(format: String(localized: "Labels: %@"), labels.map(\.name).joined(separator: ", "))]
    }

    /// Прочитать теги картинок, которых ещё нет в памяти. `prune` — пришло окно соседей целиком: помнятся только
    /// показанная и они.
    private func prefetchTags(_ urls: [URL], prune: Bool = true) {
        guard state == .visible, preferences.tags else { return }
        if prune {
            let keep = Set(urls).union([displayedURL].compactMap { $0 })
            tagCache = tagCache.filter { keep.contains($0.key) }
        }
        for url in urls where tagCache[url] == nil && tagReads[url] == nil {
            tagReads[url] = Task {
                let tags = (try? await FileTagger.tags(of: url)) ?? []
                if self.resolvedTagNames == nil { _ = await self.tagNames() }
                guard !Task.isCancelled, self.state == .visible else { return }
                self.tagReads[url] = nil
                // Пока читали, метку уже поставили — свежий список в памяти, прочитанный устарел.
                guard self.tagCache[url] == nil else { return }
                self.tagCache[url] = tags
                if url == self.displayedURL { self.showTagDots(for: url) }
                if self.infoHold.state == .shown, url == self.currentURL { self.updateInfo() }
            }
        }
    }

    /// Зажата стрелка: точки прячутся, показ — через 0,3 с после последнего повтора.
    private func holdTagDots() {
        viewerView.holdTagDots(true)
        tagDotsRelease?.cancel()
        tagDotsRelease = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.viewerView.holdTagDots(false)
        }
    }

    private func forgetTags() {
        tagSession += 1
        tagQueue?.cancel()
        tagNamesTask?.cancel()
        tagNamesTask = nil
        resolvedTagNames = nil
        tagReads.values.forEach { $0.cancel() }
        tagReads.removeAll()
        tagCache.removeAll()
        tagQueue = nil
        tagDotsRelease?.cancel()
        tagDotsRelease = nil
        viewerView.holdTagDots(false)
        viewerView.setTagDots([], names: [])
    }

    // MARK: - Поворот, копирование, открытие

    /// Повернуть показ (файл не меняется); поворот запомнится вместе с масштабом картинки.
    func rotate(clockwise: Bool) {
        guard state == .visible else { return }
        viewerView.rotate(clockwise: clockwise)
        // Рамки текста распознаны для прежнего поворота — в режиме распознаём заново, иначе забываем.
        forgetLiveText()
        if liveHold.isActive { analyzeLiveText() }
    }

    /// `⌘C` — выделенный текст (Live Text), а без него — файл в буфер обмена, как в Finder: в Finder вставится
    /// копия файла, в мессенджеры — вложение.
    func copyCurrent() {
        guard state == .visible, let url = currentURL else { return }
        let pasteboard = NSPasteboard.general
        let text = viewerView.selectedLiveText
        pasteboard.clearContents()
        if !text.isEmpty {
            pasteboard.setString(text, forType: .string)
            viewerView.showMessage(String(localized: "Text copied"))
        } else {
            pasteboard.writeObjects([url as NSURL])
            viewerView.showMessage(String(localized: "Copied"))
        }
    }

    /// `⌘O` — закрыть просмотр и открыть файл в приложении по умолчанию.
    func openCurrentInApp() {
        guard state == .visible, let url = currentURL else { return }
        close(returnFocus: false)
        NSWorkspace.shared.open(url)
    }

    /// Плавное появление и исчезновение — по настройке.
    private var fadeDuration: Double { preferences.animate ? Self.fadeDuration : 0 }

    /// Жест трекпада из перехвата (режим «следовать за Finder»): масштаб в точке под курсором.
    func gesture(_ gesture: ViewerGesture) {
        guard state == .visible else { return }
        // В слайд-шоу масштаба нет.
        if slideshow.isActive { return slideshowBlocked() }
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
            // В режиме Live Text — распознать детали: мелкий текст на большом снимке виден только в них.
            if liveHold.isActive { analyzeLiveText() }
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
                if liveHold.isActive { analyzeLiveText() }
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
        // Новая картинка: режим Live Text и распознанное — от прежней.
        runLive(liveHold.reset())
        forgetLiveText()
        lookUpPending = false
        // В слайд-шоу — всегда «вписать»: увеличение там не работает, а запомненное увело бы картинку из кадра. Запоминать
        // «вписать» тоже нельзя — затёрло бы масштаб, который пользователь оставил картинке до слайд-шоу.
        if !slideshow.isActive { rememberDisplayedZoom() }
        let crossfade = crossfadeNext
        crossfadeNext = false
        viewerView.show(image, placement: slideshow.isActive ? .fit : zoomMemory.placement(for: url), crossfade: crossfade)
        displayedURL = url
        showTagDots(for: url)
        slideshowEdgeWaits = 0
        runSlideshow(slideshow.imageShown())
    }

    // MARK: - Live Text, поиск по изображению, «Поделиться»

    private func runLive(_ outputs: [LiveTextHoldTracker.Output]) {
        for output in outputs {
            switch output {
            case .startTimer:
                liveTimer?.cancel()
                liveTimer = Task {
                    try? await Task.sleep(for: LiveTextHoldTracker.delay)
                    guard !Task.isCancelled else { return }
                    runLive(liveHold.timerFired())
                }
            case .cancelTimer:
                liveTimer?.cancel()
                liveTimer = nil
            case .enter:
                viewerView.setLiveMode(true)
                analyzeLiveText()
            case .exit:
                lookUpPending = false
                viewerView.setLiveMode(false)
            }
        }
    }

    /// Кнопка Live Text: подсветка включена — режим держится и без `⌘`.
    private func liveTextLatched(_ latched: Bool) {
        guard state == .visible else { return }
        runLive(liveHold.setLatched(latched, commandHeld: NSEvent.modifierFlags.contains(.command)))
    }

    /// Распознать показанное, если ещё не распознано (или с тех пор подгрузилась деталь, повернули). Анимацию —
    /// нет.
    private func analyzeLiveText() {
        guard let current = loaded, !current.isAnimated, let zoom = viewerView.zoom else {
            finishLookUp()
            return
        }
        let surface = ObjectIdentifier(current.surface)
        let visible = viewerView.visibleImageUnitRect
        if let liveKey, liveKey.surface == surface, liveKey.quarterTurns == zoom.quarterTurns,
           Self.liveCropCovers(liveKey.crop, visible: visible) {
            // Вернулись к распознанному, пока распознавалось другое, — то устарело.
            if liveTask != nil {
                liveTask?.cancel()
                liveTask = nil
                isAnalyzing = false
                updateSpinner()
            }
            finishLookUp()
            return
        }
        let key = LiveKey(surface: surface, quarterTurns: zoom.quarterTurns, crop: Self.liveCrop(for: visible))
        liveTask?.cancel()
        isAnalyzing = true
        updateSpinner()
        liveTask = Task {
            let analysis = await liveAnalyzer.analyze(current.surface, crop: key.crop, quarterTurns: key.quarterTurns)
            // Отменил тот, кто сменил картинку или поворот, — он же сбросил индикатор.
            guard !Task.isCancelled else { return }
            liveTask = nil
            isAnalyzing = false
            updateSpinner()
            guard state == .visible, loaded === current, viewerView.zoom?.quarterTurns == key.quarterTurns else { return }
            guard let analysis else {
                // Не запоминаем: следующее нажатие `⌘` попробует снова.
                log.notice("Live Text: распознать не удалось")
                finishLookUp()
                return
            }
            liveKey = key
            viewerView.setLiveAnalysis(analysis, crop: key.crop)
            finishLookUp()
        }
    }

    /// Что распознавать: картинку целиком, если видно почти всю, иначе видимую часть с запасом 10 % по краям.
    nonisolated static func liveCrop(for visible: CGRect?) -> CGRect {
        guard let visible, visible.width * visible.height < 0.8 else { return ViewerView.unitRect }
        let margin = max(visible.width, visible.height) * 0.1
        return visible.insetBy(dx: -margin, dy: -margin).intersection(ViewerView.unitRect)
    }

    /// Распознанное годится: видимое внутри распознанного, а увеличили не настолько, чтобы мелкий текст стал
    /// распознаваться лучше (распознанная часть больше нужной не более чем вдвое по стороне).
    nonisolated static func liveCropCovers(_ crop: CGRect, visible: CGRect?) -> Bool {
        let needed = liveCrop(for: visible)
        guard crop.insetBy(dx: -0.001, dy: -0.001).contains(needed) else { return false }
        return max(crop.width / needed.width, crop.height / needed.height) <= 2
    }

    /// Масштаб или сдвиг: в режиме — распознать видимое заново, когда движение уляжется.
    private func liveViewChanged() {
        guard liveHold.isActive else { return }
        liveViewSettle?.cancel()
        liveViewSettle = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, state == .visible, liveHold.isActive else { return }
            analyzeLiveText()
        }
    }

    /// Другая картинка или поворот: распознанное больше не ложится на экран.
    /// Новый просмотр поверх открытого (Пробел, `open -a`): режим `⌘`, распознанное и одолженная клавиатура — от
    /// прежнего. До смены режима: `returnKeyboard` смотрит на него. История отмены — тоже от прежнего сеанса
    /// (мост свою историю удалений начинает заново в `startFollowing`).
    private func resetLiveText() {
        sessionUndo.clear()
        forgetTags()
        runLive(liveHold.reset())
        lookUpPending = false
        forgetLiveText()
        returnKeyboard()
    }

    private func forgetLiveText() {
        liveTask?.cancel()
        liveTask = nil
        if isAnalyzing {
            isAnalyzing = false
            updateSpinner()
        }
        liveKey = nil
        closeLiveCards()
        viewerView.setLiveAnalysis(nil)
    }

    /// Карточки и просмотр ссылки относятся к распознанному: со сменой картинки, поворотом и закрытием просмотра
    /// закрываются. Просмотр ссылки — окно другого процесса, со сменой анализа и скрытием панели он не закрывается
    /// (висел поверх всего, пока не нажмёшь `⌘` в следующем просмотре).
    private func closeLiveCards() {
        closeCards(popovers)
        if viewerView.hasLiveAnalysis { DataDetectorBubbles.close() }
    }

    /// `⌘L` — «Поиск по изображению»: режим (кнопки VisionKit) фиксируется, после распознавания нажимается его
    /// кнопка поиска. Открыть поиск напрямую VisionKit не даёт.
    func lookUp() {
        guard state == .visible else { return }
        lookUpPending = true
        let outputs = liveHold.latch()
        runLive(outputs)
        // Режим уже был включён — распознанное могло быть готово.
        if outputs.isEmpty { analyzeLiveText() }
    }

    private func finishLookUp() {
        guard lookUpPending else { return }
        lookUpPending = false
        guard viewerView.hasLookUpResults else {
            viewerView.showMessage(String(localized: "Look Up found nothing"))
            return
        }
        // Кнопки VisionKit появляются с анимацией — нажимать после неё.
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard state == .visible, liveHold.isActive else { return }
            if !viewerView.pressLookUp() { viewerView.showMessage(String(localized: "Look Up found nothing")) }
        }
    }

    /// `⌘S` и кнопка рядом с кнопками VisionKit — меню «Поделиться» с показанным файлом.
    func share() {
        guard state == .visible, sharePicker == nil, !isSharing, let url = currentURL else { return }
        let picker = NSSharingServicePicker(items: [url as NSURL])
        picker.delegate = self
        sharePicker = picker
        // Меню — окно уровня 101: под панелью уровня .screenSaver его не видно, а невидимое оно забирало бы клики.
        // На время меню панель — над строкой меню и Dock, но под меню.
        setPanelLevel(.statusBar, reason: "меню «Поделиться»")
        picker.show(relativeTo: viewerView.shareAnchor, of: viewerView, preferredEdge: .minY)
    }

    /// Сервис не сообщил, что закончил (AirDrop закрыли, ничего не отправив): его окна были и исчезли — значит,
    /// закончил. Иначе панель осталась бы обычного уровня до конца просмотра.
    private func watchSharingWindows() {
        Task {
            var sawWindows = false
            while isSharing, state == .visible {
                if !auxiliaryWindows().isEmpty {
                    sawWindows = true
                } else if sawWindows {
                    log.notice("«Поделиться»: окна сервиса закрылись без ответа")
                    finishSharing()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Меню закрыли или сервис закончил: панель — снова поверх всего, своему списку — клавиатура. Пока меню было
    /// открыто, отпускание `⌘` уходило ему — сверяем режим Live Text с тем, что держат сейчас.
    private func finishSharing() {
        isSharing = false
        sharingService = nil
        guard state == .visible else { return }
        setPanelLevel(.screenSaver, reason: "«Поделиться» закончено")
        if mode == .ownList {
            panel.makeKey()
            panel.makeFirstResponder(viewerView)
        } else if NSRunningApplication.current.isActive,
                  let finder = NSRunningApplication.runningApplications(withBundleIdentifier: FinderBridge.finderBundleID).first {
            // AirDrop сделал Ementium активным — Finder снова впереди, иначе стрелки не доходили бы до перехвата.
            log.notice("«Поделиться» закончено: возвращаю активность Finder")
            finder.activate()
        }
        input(.modifiers(HoldModifiers(NSEvent.modifierFlags)))
    }

    // MARK: - Окна VisionKit

    /// Карточка контакта, просмотр ссылки: VisionKit открывает свои окна, и под панелью уровня .screenSaver их бы
    /// не было видно — поднимаем их над ней после каждого события (отпускание мыши VisionKit забирает себе). Пока
    /// такое окно открыто, щелчок по просмотру только закрывает его (повторный щелчок по «пилюле» — как в Quick Look).
    /// Заодно — модификаторы своего списка: после щелчка по тексту клавиатура у оверлея, до просмотра они не доходят.
    private func watchAuxiliaryWindows() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .flagsChanged]) { [weak self] event in
            let type = event.type
            let inPanel = event.window != nil && event.window === self?.panel
            let location = event.locationInWindow
            let modifiers = HoldModifiers(event.modifierFlags)
            let swallow = MainActor.assumeIsolated {
                self?.monitored(type, at: location, inPanel: inPanel, modifiers: modifiers) ?? false
            }
            return swallow ? nil : event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidUpdate(_:)), name: NSApplication.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(popoverDidShow(_:)), name: NSPopover.didShowNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(popoverDidClose(_:)), name: NSPopover.didCloseNotification, object: nil
        )
    }

    // Уведомления о всплывающих окнах приходят на главном потоке; объект достаём до перехода на главный актор.
    @objc nonisolated private func popoverDidShow(_ notification: Notification) {
        let shown = notification.object as? NSPopover
        MainActor.assumeIsolated {
            guard state == .visible, let popover = shown,
                  popover.contentViewController?.view.window?.parent === panel else { return }
            popovers.append(popover)
            let content = popover.contentViewController.map { String(describing: type(of: $0)) } ?? "-"
            log.notice("Карточка VisionKit: \(content, privacy: .public)")
        }
    }

    @objc nonisolated private func popoverDidClose(_ notification: Notification) {
        let closed = notification.object as? NSPopover
        MainActor.assumeIsolated {
            popovers.removeAll { $0 === closed || !$0.isShown }
            // Свой список: пока карточка была открыта, клавиатура и отпускание `⌘` могли уйти ей.
            guard state == .visible, mode == .ownList, popovers.isEmpty else { return }
            if !panel.isKeyWindow {
                panel.makeKey()
                panel.makeFirstResponder(viewerView)
            }
            input(.modifiers(HoldModifiers(NSEvent.modifierFlags)))
        }
    }

    private func monitored(_ type: NSEvent.EventType, at location: NSPoint, inPanel: Bool, modifiers: HoldModifiers) -> Bool {
        // Отпускание поглощённого щелчка — тоже: без нажатия оно досталось бы виду, который о щелчке не знает.
        if type == .leftMouseUp {
            defer { swallowsMouseUp = false }
            return swallowsMouseUp && inPanel
        }
        guard state == .visible, inPanel else { return false }
        if type == .flagsChanged {
            // Режим «следовать» — модификаторы присылает перехват (клавиатура у Finder).
            if mode == .ownList { input(.modifiers(modifiers)) }
            return false
        }
        guard !isSharing, sharePicker == nil else { return false }
        // Просмотр ссылки открыт — щелчок по просмотру только закрывает его, как карточку контакта; по той же
        // «пилюле» — тоже (иначе VisionKit закрывал и тут же открывал его снова). Поглощается целиком, с
        // отпусканием: в нашем окне у просмотра ссылки нет своего распознавателя, сбивать нечего (прототип
        // LiveTextProbe, pilltest, LINKTOGGLE).
        if closeLinkPreview() {
            swallowsMouseUp = true
            return true
        }
        let dataHit = viewerView.isLiveActionHit(atWindowPoint: location)
        if mode == .following, dataHit { lendKeyboard() }
        let shown = popovers.filter(\.isShown)
        if !shown.isEmpty {
            // Щелчок мимо карточки не поглощаем: его забирает сама карточка (так NSPopover закрывается щелчком
            // мимо). Поглощённый сбивал её учёт щелчков, и следующий щелчок по «пилюле» пропадал (прототип
            // LiveTextProbe, pilltest). Закрываем сами, после щелчка: делегат карточки на щелчок мимо закрываться
            // отказывается.
            DispatchQueue.main.async { [weak self] in self?.closeCards(shown) }
            return false
        }
        // Окно закрывающейся карточки ещё видно, а в списке карточек её уже нет: щелчок по нему не поглощать.
        let open = auxiliaryWindows().filter { !String(describing: Swift.type(of: $0)).contains("Popover") }
        guard open.isEmpty else {
            for window in open { dismiss(window) }
            swallowsMouseUp = true
            return true
        }
        // Просмотр ссылки открывает только щелчок по данным: от прочих щелчков чужое окно (HUD, Spotlight) за него
        // принять нельзя.
        if dataHit { watchForeignPreview(since: Self.onScreenWindowNumbers()) }
        return false
    }

    /// После каждого события приложения: появилось окно VisionKit — поднять. Только пока просмотр открыт;
    /// уведомление приходит на главном потоке, но селектору изоляция не видна — проверяем сами.
    @objc nonisolated private func applicationDidUpdate(_ notification: Notification) {
        MainActor.assumeIsolated { raiseAuxiliaryWindows() }
    }

    /// Видимые окна Ementium, кроме просмотра, настроек, палитры, меню, подсказок, иконки в строке меню и карточек
    /// (их закрываем через `NSPopover`).
    private func auxiliaryWindows() -> [NSWindow] {
        let popoverWindows = popovers.compactMap { $0.contentViewController?.view.window }
        return NSApp.windows.filter { window in
            guard window.isVisible, window !== panel, !(window is SettingsPanel), !(window is NSColorPanel),
                  !popoverWindows.contains(where: { $0 === window }) else { return false }
            let name = String(describing: type(of: window))
            return !["StatusBar", "Menu", "ToolTip"].contains { name.contains($0) }
        }
    }

    private func raiseAuxiliaryWindows() {
        guard state == .visible, !isSharing, sharePicker == nil else { return }
        for window in auxiliaryWindows() {
            let id = ObjectIdentifier(window)
            if !loggedAuxiliaryWindows.contains(id) {
                loggedAuxiliaryWindows.insert(id)
                let parent = window.parent.map { String(describing: type(of: $0)) } ?? "-"
                log.notice("Окно VisionKit: \(String(describing: type(of: window)), privacy: .public), уровень \(window.level.rawValue, privacy: .public), родитель \(parent, privacy: .public)")
            }
            if window.level < panel.level {
                window.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
            }
        }
    }

    private nonisolated static func onScreenWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private nonisolated static func onScreenWindowNumbers() -> Set<Int> {
        Set(onScreenWindows().compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    /// Просмотр ссылки система ставит у окна и над ним, только если окно ключевое. В режиме «следовать» панель
    /// ключевой не бывает — окно уходило в левый нижний угол экрана, под панель. Поэтому на время щелчка по «пилюле»
    /// или распознанным данным панель берёт клавиатуру (неактивирующая — Finder остаётся впереди) и отдаёт её, как
    /// только окно ссылки появилось, иначе через 2 с. Клавиши в режиме «следовать» и так разбирает перехват; окно
    /// ссылки и карточка контакта возврат клавиатуры переживают (прототип LiveTextProbe, pilltest, KEYTRICK).
    private func lendKeyboard() {
        keyboardLoan?.cancel()
        panel.acceptsKeyboard = true
        panel.makeKey()
        log.notice("Режим «следовать»: панель берёт клавиатуру на время щелчка по данным")
        keyboardLoan = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.returnKeyboard()
        }
    }

    private func returnKeyboard() {
        guard let loan = keyboardLoan else { return }
        loan.cancel()
        keyboardLoan = nil
        guard mode == .following else { return }
        panel.acceptsKeyboard = false
        // Ключевая неактивирующая панель делает Ementium «активным» в глазах AppKit, хотя впереди Finder:
        // deactivate возвращает клавиатуру ему.
        NSApp.deactivate()
        log.notice("Режим «следовать»: клавиатура снова у Finder")
    }

    /// Закрыть карточки VisionKit. `performClose` делегат карточки отклоняет, кнопка «Отменить» — в другом процессе
    /// (карточка — удалённый вид), поэтому только `close`.
    private func closeCards(_ cards: [NSPopover]) {
        for card in cards where card.isShown {
            log.notice("Закрываю карточку VisionKit")
            card.close()
        }
    }

    /// Просмотр ссылки показывает другой процесс (`com.apple.quicklook.ui.helper`) окном на уровень выше окна, к
    /// которому он привязан, — если оно ключевое (для режима «следовать» — `lendKeyboard`). Иначе окно — уровня 101,
    /// под панелью .screenSaver, а поднять чужое окно нельзя: пока оно открыто, панель опускается до .statusBar — над
    /// строкой меню и Dock, но под ним (как для меню «Поделиться»).
    private func watchForeignPreview(since before: Set<Int>) {
        if foreignPreview != nil {
            // Прежнее окно гаснет по нашей просьбе (щелчок по «пилюле» сразу после закрытия) — следим за новым.
            guard linkPreviewClosing else { return }
            forgetForeignPreview()
        }
        foreignPreviewWatch?.cancel()
        foreignPreviewWatch = Task {
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, state == .visible, !isSharing else { return }
                guard let window = Self.newForeignWindow(since: before) else { continue }
                foreignPreview = window.number
                returnKeyboard()
                let bundle = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier ?? "?"
                log.notice("Окно другого процесса после щелчка: \(window.owner, privacy: .public) (\(bundle, privacy: .public)), уровень \(window.layer, privacy: .public)")
                // Под панелью (режим «следовать», если панель не стала ключевой) — панель ниже, пока оно открыто.
                if window.layer < panel.level.rawValue { setPanelLevel(.statusBar, reason: "просмотр ссылки") }
                while !Task.isCancelled, state == .visible, Self.onScreenWindowNumbers().contains(window.number) {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                // Отменили — за окном уже следит новое наблюдение или просмотр закрыт.
                guard !Task.isCancelled else { return }
                log.notice("Окно другого процесса закрылось")
                forgetForeignPreview()
                return
            }
        }
    }

    /// Окно просмотра ссылки закрылось (или за ним больше не следим): панель — снова поверх всего.
    private func forgetForeignPreview() {
        foreignPreviewWatch?.cancel()
        foreignPreviewWatch = nil
        foreignPreview = nil
        linkPreviewClosing = false
        if state == .visible, !isSharing, sharePicker == nil { setPanelLevel(.screenSaver, reason: "просмотр ссылки закрыт") }
    }

    /// Открыта карточка контакта или просмотр ссылки — `Esc` и Пробел закрывают только их, второе нажатие — просмотр
    /// (так в своём списке: там `Esc` достаётся им самим, а в режиме «следовать» его забирает перехват). `true` —
    /// было что закрыть.
    func closeLiveWindows() -> Bool {
        guard state == .visible else { return false }
        let cards = popovers.filter(\.isShown)
        guard cards.isEmpty else {
            closeCards(cards)
            return true
        }
        return closeLinkPreview()
    }

    /// Просмотр ссылки открыт — закрыть только его (клавишей — `closeLiveWindows`, щелчком по просмотру — из
    /// монитора). `true` — был открыт и закрывается.
    @discardableResult
    private func closeLinkPreview() -> Bool {
        guard state == .visible, foreignPreview != nil, !linkPreviewClosing else { return false }
        // Нечем закрыть (частного метода нет) — пусть `Esc` закрывает просмотр, а щелчок проходит как раньше.
        guard DataDetectorBubbles.close() else { return false }
        linkPreviewClosing = true
        log.notice("Закрываю просмотр ссылки")
        return true
    }

    private nonisolated static func newForeignWindow(
        since before: Set<Int>
    ) -> (number: Int, pid: pid_t, owner: String, layer: Int)? {
        let own = Int(ProcessInfo.processInfo.processIdentifier)
        for info in onScreenWindows() {
            guard let number = info[kCGWindowNumber as String] as? Int, !before.contains(number),
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid != own else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer > NSWindow.Level.statusBar.rawValue else { continue }
            return (number, pid_t(pid), info[kCGWindowOwnerName as String] as? String ?? "?", layer)
        }
        return nil
    }

    /// Панель показана, но WindowServer не выводит её на экран: после двух суток работы окно выпало со всех рабочих
    /// столов (причина не найдена — возможно, сон или полноэкранное приложение), и просмотр открывался невидимым.
    /// При нулевой прозрачности и здоровая панель числится не на экране — поэтому проверяем, когда она проявилась.
    /// Не на экране — пересоздать.
    private func verifyPanelOnScreen() {
        panelCheck?.cancel()
        let number = panel.windowNumber
        panelCheck = Task {
            try? await Task.sleep(for: .seconds(fadeDuration + 0.3))
            guard !Task.isCancelled, state == .visible, panel.windowNumber == number,
                  !Self.onScreenWindowNumbers().contains(number) else { return }
            rebuildPanel(reason: "WindowServer не выводит окно на экран")
            // Сразу после вывода WindowServer окно ещё не числит на экране.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, state == .visible else { return }
            let shown = Self.onScreenWindowNumbers().contains(panel.windowNumber)
            log.notice("Панель просмотра после пересоздания на экране: \(shown ? "да" : "нет", privacy: .public)")
        }
    }

    /// Новое окно на место «потерянного» — с тем же видом, рамкой, уровнем и прозрачностью; было выведено —
    /// выводится и новое.
    private func rebuildPanel(reason: String) {
        let old = panel
        let wasShown = old.isVisible
        log.notice("Панель просмотра: пересоздаю окно \(old.windowNumber, privacy: .public) — \(reason, privacy: .public)")
        old.delegate = nil
        old.orderOut(nil)
        let fresh = Self.makePanel()
        fresh.contentView = viewerView
        fresh.delegate = self
        fresh.setFrame(old.frame, display: false)
        fresh.level = old.level
        fresh.alphaValue = old.alphaValue
        fresh.acceptsKeyboard = old.acceptsKeyboard
        fresh.ignoresMouseEvents = old.ignoresMouseEvents
        panel = fresh
        guard wasShown else { return }
        panel.orderFrontRegardless()
        if state == .visible, mode == .ownList {
            panel.makeKey()
            panel.makeFirstResponder(viewerView)
        }
    }

    /// Уровень панели — с причиной в журнале: панель опускается под меню «Поделиться», окна сервисов и просмотр
    /// ссылки и должна вернуться наверх, иначе поверх просмотра видны строка меню и Dock.
    private func setPanelLevel(_ level: NSWindow.Level, reason: String) {
        guard panel.level != level else { return }
        panel.level = level
        log.notice("Панель просмотра: уровень \(level.rawValue, privacy: .public) — \(reason, privacy: .public)")
    }

    /// Закрыть окно VisionKit. Карточку, показанную как представление контроллера, — штатно; иначе — само окно.
    /// Esc не подходит: карточка его не обрабатывает, и система пищит.
    private func dismiss(_ window: NSWindow) {
        if let content = window.contentViewController, content.presentingViewController != nil {
            log.notice("Закрываю окно VisionKit \(String(describing: type(of: window)), privacy: .public): dismiss")
            content.dismiss(nil)
        } else {
            log.notice("Закрываю окно VisionKit \(String(describing: type(of: window)), privacy: .public): close")
            window.close()
        }
    }

    // MARK: - Сведения о снимке

    /// Модификаторы и нажатия: в режиме «свой список» — от панели, в режиме «следовать» — от перехвата.
    func input(_ input: ViewerInput) {
        // В слайд-шоу сведения по `⌥` и Live Text по `⌘` не работают — молча: `⌘` нажимают перед любым сочетанием.
        guard state == .visible, !slideshow.isActive else { return }
        switch input {
        case .modifiers(let modifiers):
            run(infoHold.modifiersChanged(modifiers))
            runLive(liveHold.modifiersChanged(modifiers))
        case .keyPressed(let isArrow):
            run(infoHold.keyPressed(isArrow: isArrow))
            runLive(liveHold.keyPressed())
        case .arrowHeld:
            holdTagDots()
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
            viewerView.showInfo(lines + tagInfoLines(for: url))
            return
        }
        infoTask = Task {
            let lines = await DecoderClient.shared.metadata(url)
            guard !Task.isCancelled, state == .visible, currentURL == url, infoHold.state == .shown else { return }
            if let lines {
                infoCache[url] = lines
                viewerView.showInfo(lines + tagInfoLines(for: url))
            } else {
                // Сервис не ответил — хотя бы имя файла; не кэшируем, в следующий раз спросим снова.
                viewerView.showInfo([url.lastPathComponent] + tagInfoLines(for: url))
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
        let neighbors = PrefetchWindow.sides(
            of: directory.index, count: images.count, url: { images[$0] }, isImage: { _ in true },
            forward: PrefetchWindow.forward, backward: PrefetchWindow.forward
        )
        let order = neighbors.prefetchOrder(backwards: travelsBackward)
        cache.prefetch(order, around: directory.current, maxPixelSize: decodeSize)
        prefetchTags([directory.current].compactMap { $0 } + order)
    }

    /// Режим «следовать»: Finder встал на `current`, мост прочитал соседей в порядке окна.
    func followedNeighbors(_ neighbors: PrefetchWindow.Neighbors, around current: URL) {
        guard isFollowing, let followedURL else { return }
        finderURL = current
        finderNeighbors = (current, neighbors)
        if current == followedURL {
            followNeighbors = (current, neighbors)
            log.debug("Соседи от Finder: для показанной ←\(neighbors.backward.count, privacy: .public) →\(neighbors.forward.count, privacy: .public)")
        } else {
            // Смахивания обогнали Finder: соседи промежуточной картинки — пересчитать от показанной.
            guard let shifted = neighbors.recentered(around: current, to: followedURL) else {
                log.debug("Соседи от Finder: устарели — показанная дальше, чем они достают")
                return
            }
            let known = followNeighbors.flatMap { $0.around == followedURL ? $0.neighbors : nil }
            let merged = known.map { shifted.merged(with: $0) } ?? shifted
            followNeighbors = (followedURL, merged)
            log.debug("Соседи от Finder: для прежней, пересчитаны ←\(merged.backward.count, privacy: .public) →\(merged.forward.count, privacy: .public)")
        }
        prefetchFollowNeighbors()
    }

    private func prefetchFollowNeighbors() {
        guard let followNeighbors, followNeighbors.around == followedURL else { return }
        let order = followNeighbors.neighbors.prefetchOrder(backwards: travelsBackward)
        cache.prefetch(order, around: followNeighbors.around, maxPixelSize: decodeSize)
        prefetchTags([followNeighbors.around] + order)
    }

    // MARK: - Смахивание

    /// Соседний файл в сторону смахивания: свой список — из `ImageDirectory`, «следовать» — от моста
    /// (пока соседи не прочитаны — некуда, картинка отпружинит).
    private func neighborURL(forward: Bool) -> URL? {
        switch mode {
        case .ownList:
            guard let directory, !isListPending else { return nil }
            let index = directory.index + (forward ? 1 : -1)
            if directory.images.indices.contains(index) { return directory.images[index] }
            // Слайд-шоу с зацикливанием: за последней — первая, перед первой — последняя.
            guard slideshowWraps, directory.images.count > 1 else { return nil }
            return forward ? directory.images.first : directory.images.last
        case .following:
            guard let followNeighbors, followNeighbors.around == followedURL else { return nil }
            return forward ? followNeighbors.neighbors.next : followNeighbors.neighbors.previous
        }
    }

    private func swipeNeighbor(forward: Bool) -> ViewerView.SwipeNeighbor {
        guard state == .visible else { return .none }
        // Слайд-шоу с зацикливанием, край окна Finder: соседа за краем мы не знаем — въезжает пустой фон, картинку
        // покажет ответ моста.
        guard let url = neighborURL(forward: forward) else { return canWrapFollowing(forward: forward) ? .pending : .none }
        return cache.image(for: url).map { .image($0) } ?? .pending
    }

    /// Смахивание довели до конца. `false` — не перелистнули (просмотр закрывают, сосед уже не тот,
    /// Finder не активен): на экране остаётся прежняя картинка.
    private func swiped(forward: Bool) -> Bool {
        guard state == .visible else { return false }
        switch mode {
        case .ownList:
            return navigateWrapping(forward: forward)
        case .following:
            if neighborURL(forward: forward) == nil, canWrapFollowing(forward: forward) {
                return onFollowEdge?(forward) == true
            }
            guard let url = neighborURL(forward: forward), let current = followedURL,
                  let known = followNeighbors?.neighbors,
                  // Finder выделит её же; показываем сразу, не дожидаясь его ответа.
                  onFollowSelect?(url) == true else { return false }
            swipeLead = url
            swipeLeadCheck?.cancel()
            swipeLeadCheck = Task { [weak self] in
                try? await Task.sleep(for: Self.swipeLeadTime)
                guard !Task.isCancelled else { return }
                self?.settleSwipeLead()
            }
            follow(url)
            // Пока мост не прочитал соседей новой картинки (сотни мс) — сдвинуть известных, иначе быстрое
            // смахивание следом упрётся в «некуда». Ответ моста их заменит.
            followNeighbors = (url, known.recentered(around: current, to: url) ?? PrefetchWindow.Neighbors())
            prefetchFollowNeighbors()
            return true
        }
    }

    /// Смахивание пальцами — ручной шаг: в слайд-шоу отсчёт заново.
    private func manualSwiped(forward: Bool) -> Bool {
        crossfadeNext = false
        let moved = swiped(forward: forward)
        if moved { slideshowManualStep(imagePending: isDecoding) }
        return moved
    }

    // MARK: - Слайд-шоу

    /// `S`: включить или выключить. Сведения, Live Text и увеличение в слайд-шоу не работают — начинаем с чистого
    /// показа во «вписать». На последней картинке без зацикливания — с первой, иначе показ сразу бы и кончился.
    func toggleSlideshow() {
        guard state == .visible else { return }
        guard !slideshow.isActive else { return runSlideshow(slideshow.toggle(imageOnScreen: true)) }
        run(infoHold.reset())
        runLive(liveHold.reset())
        _ = closeLiveWindows()
        // Увеличенную или повёрнутую — во «вписать» без поворота, как пойдут следующие; её масштаб запомнен.
        if let image = loaded, let zoom = viewerView.zoom, !zoom.isFit || zoom.quarterTurns != 0 {
            rememberDisplayedZoom()
            viewerView.show(image, placement: .fit)
        }
        let jumped = !preferences.slideshowLoops && jumpToFirstFromLast()
        // На экране — картинка или ошибка «не удалось открыть» (декодирование закончено): отсчёт сразу. Прыжок к первой
        // в своём списке мог показать её синхронно (из кэша) — тоже. В «следовать» её покажет ответ моста.
        let onScreen = !isDecoding && currentURL != nil && !(jumped && mode == .following)
        runSlideshow(slideshow.toggle(imageOnScreen: onScreen))
    }

    /// Пробел в слайд-шоу.
    func slideshowPause() {
        guard state == .visible else { return }
        runSlideshow(slideshow.pauseToggle())
    }

    /// Нажатие или жест, которые в слайд-шоу не работают.
    func slideshowBlocked() {
        guard state == .visible else { return }
        runSlideshow(slideshow.blocked(at: Date()))
    }

    /// Стрелка (в режиме «следовать» — из перехвата) или смахивание: отсчёт заново, кадр — без растворения.
    func slideshowManualStep(imagePending: Bool = false) {
        guard state == .visible, slideshow.isActive else { return }
        crossfadeNext = false
        runSlideshow(slideshow.manualStep(imagePending: imagePending))
        if imagePending { watchSlideshowStall() }
    }

    private func slideshowKey(_ key: SlideshowKey) {
        switch key {
        case .toggle: toggleSlideshow()
        case .pause: slideshowPause()
        case .navigate(let command): handle(command)
        case .blocked: slideshowBlocked()
        case .ignore: break
        }
    }

    /// Стоим на последней картинке — к первой. `true` — перешли.
    private func jumpToFirstFromLast() -> Bool {
        switch mode {
        case .ownList:
            guard let directory, !isListPending, directory.images.count > 1,
                  directory.index == directory.images.count - 1,
                  self.directory?.moveToEdge(first: true) == true else { return false }
            loadCurrent()
            return true
        case .following:
            guard let known = confirmedFollowNeighbors, known.next == nil, known.previous != nil,
                  onFollowEdge?(true) == true else { return false }
            watchSlideshowStall()
            return true
        }
    }

    /// Слайд-шоу с зацикливанием: ручное листание тоже переходит с последней на первую и обратно.
    private var slideshowWraps: Bool { slideshow.isActive && preferences.slideshowLoops }

    /// Свой список: шаг вперёд или назад, в слайд-шоу с зацикливанием — через край. `true` — перешли.
    private func navigateWrapping(forward: Bool) -> Bool {
        if slideshowWraps, !isListPending, let directory, directory.images.count > 1,
           directory.index == (forward ? directory.images.count - 1 : 0),
           self.directory?.moveToEdge(first: forward) == true {
            travelsBackward = !forward
            loadCurrent()
            return true
        }
        return navigate(by: forward ? 1 : -1)
    }

    /// Режим «следовать»: показанная — крайняя в окне Finder (в эту сторону картинок нет, в другую есть), и слайд-шоу
    /// с зацикливанием — шаг через край пойдёт прыжком к первой (последней).
    /// Соседи — прочитанные мостом для показанной, а нет их — известные для неё (ручное нажатие на краю не должно
    /// упираться в неответивший мост).
    private func canWrapFollowing(forward: Bool) -> Bool {
        guard mode == .following, slideshowWraps,
              let known = confirmedFollowNeighbors
                ?? followNeighbors.flatMap({ $0.around == followedURL ? $0.neighbors : nil }) else { return false }
        return forward ? known.next == nil && known.previous != nil : known.previous == nil && known.next != nil
    }

    /// Стрелка в режиме «следовать» во время слайд-шоу: на краю с зацикливанием — прыжок через край вместо стрелки
    /// Finder (`true` — ушло прыжком). `forward` — `→` или `↓`.
    func slideshowArrowWraps(forward: Bool) -> Bool {
        guard state == .visible, canWrapFollowing(forward: forward) else { return false }
        return onFollowEdge?(forward) == true
    }

    /// Соседи показанной, прочитанные мостом для неё (а не сдвинутые после смахивания — те с каждым шагом короче, и
    /// «соседа нет» там значит лишь «ещё не прочитан»).
    private var confirmedFollowNeighbors: PrefetchWindow.Neighbors? {
        guard let followedURL, let followNeighbors, followNeighbors.around == followedURL,
              finderNeighbors?.around == followedURL else { return nil }
        return followNeighbors.neighbors
    }

    /// Режим «следовать»: шаг отдан мосту (прыжок к первой) или ручной шаг ждёт картинку. Мост не ответил, Finder
    /// занят — без сторожа слайд-шоу ждало бы вечно; пока картинка декодируется, ждём её.
    private func watchSlideshowStall() {
        slideshowStallWatch?.cancel()
        slideshowStallWatch = Task {
            var waited = Duration.zero
            while waited < Self.slideshowStallTime {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, state == .visible, slideshow.phase == .waiting else { return }
                if !isDecoding { waited += .milliseconds(500) }
            }
            log.info("Слайд-шоу: картинка не появилась — шаг заново")
            runSlideshow(slideshow.advanceFailed())
        }
    }

    private func runSlideshow(_ outputs: [SlideshowClock.Output]) {
        for output in outputs {
            switch output {
            case .startTimer(let delay):
                slideshowTimer?.cancel()
                slideshowTimer = Task {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, state == .visible else { return }
                    runSlideshow(slideshow.timerFired())
                }
            case .cancelTimer:
                slideshowTimer?.cancel()
                slideshowTimer = nil
                if !slideshow.isActive {
                    slideshowStallWatch?.cancel()
                    slideshowStallWatch = nil
                }
            case .advance:
                slideshowAdvance()
            case .message(let message):
                showMessage(Self.text(of: message))
            case .indicator(let indicator):
                viewerView.showSlideshowIndicator(indicator)
            case .keepDisplayAwake(let awake):
                keepDisplayAwake(awake)
            case .active(let active):
                log.info("Слайд-шоу \(active ? "включено" : "выключено", privacy: .public)")
                interception.update { $0.isSlideshow = active }
                viewerView.setSlideshow(active)
                if !active { crossfadeNext = false }
                // Курсор — до движения мыши; в режиме «следовать» сменить его нельзя (фоновое приложение).
                if active, mode == .ownList { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
    }

    private enum SlideStep {
        case moved
        /// Соседи ещё не известны или список строится — повторить.
        case unknown
        /// Картинка одна — отсчёт заново.
        case alone
        case end
    }

    /// Таймер истёк — следующая картинка, растворением (при «Уменьшить движение» — сразу).
    private func slideshowAdvance() {
        crossfadeNext = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if mode == .ownList { NSCursor.setHiddenUntilMouseMoves(true) }
        // Пальцы на трекпаде или смахивание доезжает — подождать: иначе шаг под пальцами, а смахивание — ещё один.
        let step = viewerView.isSwiping ? .unknown : nextSlide()
        log.info("Слайд-шоу: шаг — \(String(describing: step), privacy: .public)")
        if step != .moved { crossfadeNext = false }
        switch step {
        case .moved: if mode == .following { watchSlideshowStall() }
        case .unknown: runSlideshow(slideshow.advanceFailed())
        case .alone: runSlideshow(slideshow.imageShown())
        case .end: runSlideshow(slideshow.reachedEnd())
        }
    }

    /// Шаг вперёд по порядку списка или окна Finder. В режиме «следовать» — путём смахивания: соседа показываем
    /// сразу и выделяем в Finder через AX (стрелки не годятся — в «Списке» `→` никуда не ведёт).
    private func nextSlide() -> SlideStep {
        let loops = preferences.slideshowLoops
        switch mode {
        case .ownList:
            guard let directory, !isListPending else { return .unknown }
            if directory.index + 1 < directory.images.count { return navigate(by: 1) ? .moved : .unknown }
            guard loops else { return .end }
            guard directory.images.count > 1, self.directory?.moveToEdge(first: true) == true else { return .alone }
            loadCurrent()
            return .moved
        case .following:
            guard let known = followNeighbors, known.around == followedURL else {
                _ = waitForFollowNeighbors(reason: "соседи показанной не прочитаны")
                return .unknown
            }
            if known.neighbors.next != nil { return swiped(forward: true) ? .moved : .unknown }
            guard let edge = followEdgeNeighbors(known.neighbors) else { return .unknown }
            guard loops else { return .end }
            guard edge.previous != nil else { return .alone }
            return onFollowEdge?(true) == true ? .moved : .unknown
        }
    }

    /// Край окна Finder для автоматического шага: соседи, прочитанные мостом для показанной. Мост их не прислал (Finder
    /// ещё занят после стрелок) — попросить перечитать; не прислал и за `slideshowEdgeWaitLimit` повторов (~3 с) —
    /// довериться известным: иначе слайд-шоу стояло бы на последней картинке вечно.
    private func followEdgeNeighbors(_ known: PrefetchWindow.Neighbors) -> PrefetchWindow.Neighbors? {
        if let confirmed = confirmedFollowNeighbors {
            slideshowEdgeWaits = 0
            return confirmed
        }
        guard waitForFollowNeighbors(reason: "край не подтверждён мостом") else { return nil }
        log.notice("Слайд-шоу: мост не подтвердил край — шаг по известным соседям")
        return known
    }

    private static let slideshowEdgeWaitLimit = 6

    /// Соседей ждём — в первый раз просим мост перечитать их. `true` — ждали `slideshowEdgeWaitLimit` повторов (~3 с),
    /// хватит.
    private func waitForFollowNeighbors(reason: String) -> Bool {
        slideshowEdgeWaits += 1
        if slideshowEdgeWaits == 1 {
            log.notice("Слайд-шоу: \(reason, privacy: .public) — перечитываю соседей")
            onFollowResync?()
        }
        guard slideshowEdgeWaits >= Self.slideshowEdgeWaitLimit else { return false }
        slideshowEdgeWaits = 0
        return true
    }

    /// Пока слайд-шоу идёт, дисплей не засыпает; на паузе и после — как обычно.
    private func keepDisplayAwake(_ awake: Bool) {
        if awake, slideshowActivity == nil {
            slideshowActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Slideshow"
            )
        } else if !awake, let activity = slideshowActivity {
            ProcessInfo.processInfo.endActivity(activity)
            slideshowActivity = nil
        }
    }

    private static func text(of message: SlideshowClock.Message) -> String {
        switch message {
        case .finished: String(localized: "Slideshow finished")
        case .blocked: String(localized: "Not available in slideshow — press S to exit")
        }
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
        // Слайд-шоу не встаёт на битом файле: через интервал — дальше.
        crossfadeNext = false
        runSlideshow(slideshow.imageShown())
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        rememberPrevious(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func rememberPrevious(_ app: NSRunningApplication?) {
        guard let app, app != NSRunningApplication.current else { return }
        previousApp = app
    }
}

extension ViewerWindowController: NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        sharePicker = nil
        guard let service else {
            finishSharing()
            return
        }
        guard state == .visible else { return }
        // Окна сервисов — обычного уровня: AirDrop — окна Ementium, «Сообщения» и «Почта» — другое приложение
        // (просмотр тогда закроется сам: Finder или панель теряют клавиатуру). На время сервиса панель — обычная.
        isSharing = true
        sharingService = service
        // Название службы может быть именем контакта (подсказки получателей) — в журнал скрыто.
        log.info("«Поделиться»: \(service.title, privacy: .private)")
        setPanelLevel(.normal, reason: "служба «Поделиться»")
        watchSharingWindows()
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        self
    }

    func sharingService(
        _ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        panel
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finishSharing()
        // У «Добавить в Фото» своего окна нет — без подсказки не видно, что получилось.
        if sharingService.title == NSSharingService(named: .addToIPhoto)?.title {
            showMessage(String(localized: "Added to Photos"))
        }
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        finishSharing()
        // Отменили мы сами, закрывая просмотр (`SharingSheet.dismiss`, ответ — код 4097): сообщать некому.
        guard state == .visible else { return }
        let error = error as NSError
        guard !(error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError) else { return }
        showMessage(String(localized: "Couldn't share"))
    }
}

/// Отмена работающей службы «Поделиться» — частным `-[NSSharingService dismissWithCompletion:]`: окна AirDrop
/// закрываются, служба отвечает `didFailToShareItems` (прототип: просто спрятанное окно-источник лист не отменяет,
/// он возвращается с окном). Метод частный: на другой версии macOS его может не быть — тогда `false`.
enum SharingSheet {
    @discardableResult
    static func dismiss(_ service: NSSharingService) -> Bool {
        let selector = NSSelectorFromString("dismissWithCompletion:")
        // Та же сигнатура, что на macOS 27: ничего не возвращает, один аргумент — блок. Иначе вызов вслепую.
        guard service.responds(to: selector),
              let method = class_getInstanceMethod(type(of: service), selector),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding).replacing(/\d/, with: "") == "v@:@?" else { return false }
        // Блок — пустой, а не nil: вызывает ли его служба без проверки, неизвестно.
        typealias Dismiss = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(service.method(for: selector), to: Dismiss.self)(service, selector, {})
        return true
    }
}
