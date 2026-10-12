import AppKit
import ApplicationServices
import os

/// Связь с Finder через Accessibility: держит снимок фокуса и выделения в `InterceptionState`,
/// а в режиме «следовать за Finder» листает — отправляет Finder стрелки и сообщает просмотру,
/// какую картинку он выделил. Устройство AX у Finder выяснено прототипами в `Prototypes/`.
///
/// Всё, кроме публичных методов-обёрток, выполняется на собственном потоке: AX-запросы к занятому
/// Finder длятся до сотен миллисекунд и не должны блокировать ни главный поток, ни перехват клавиш.
nonisolated final class FinderBridge: @unchecked Sendable {
    static let finderBundleID = "com.apple.finder"

    /// Чем закончилось удаление или возврат файла (вызывается на потоке моста).
    enum TrashEvent: Sendable, Equatable {
        /// `deleted` в Корзине; `next` — что теперь выделено и показывать (`nil` — картинок не осталось).
        case moved(deleted: URL, next: URL?)
        /// `⌘Z`: файл вернулся и выделен.
        case restored(URL)
        /// Finder не ответил за 3 с — возможно, спрашивает что-то в окне под оверлеем. Ждём дальше.
        case slow(undo: Bool)
        /// Так и не ответил.
        case failed(undo: Bool)
        /// Здесь удалить нельзя (рабочий стол, группы в «значках»).
        case notHere
        /// Выделение в Finder изменилось, пока готовились, — ничего не отправлено.
        case cancelled
        /// `⌘Z`, а в этом сеансе ничего не удаляли.
        case nothingToUndo
        /// Файл уже на месте — `⌘Z` не отправлен.
        case alreadyBack(URL)
    }

    private struct TrashOperation {
        let url: URL
        let target: URL?
        let isUndo: Bool
        let started = Date()
        var isSlow = false
    }

    private let state: InterceptionState
    /// Finder выделил картинку, которую нужно показать (вызывается на потоке моста).
    private let onShow: @Sendable (URL) -> Void
    /// Finder ищет следующую картинку — пропускает не-изображения (для индикатора ожидания).
    private let onBusy: @Sendable (Bool) -> Void
    /// Соседние картинки показанной в порядке предзагрузки и сама показанная (вызывается на потоке моста).
    private let onNeighbors: @Sendable ([URL], URL) -> Void
    private let onTrash: @Sendable (TrashEvent) -> Void
    private let thread = RunLoopThread(name: "Ementium.FinderBridge")
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "finder")

    // Только на потоке моста.
    private var observer: AXObserver?
    private var finderApp: AXUIElement?
    private var finderPID: pid_t = 0
    private var debounce: Timer?
    private var viewKind = FinderViewKind.other
    /// Элемент вида с выделением (список, колонка, коллекция) — по нему заглядываем вперёд.
    private var viewElement: AXUIElement?
    /// Нажатие, пришедшее во время прыжка: выполним, когда картинка покажется.
    private var queuedStep: ArrowKey?
    /// Не `nil`, пока просмотр открыт в режиме «следовать за Finder».
    private var navigation: FinderNavigation?
    private var edgeTimer: Timer?
    /// Счётчик отправленных стрелок — чтобы понять, сдвинулся ли Finder за время таймаута.
    private var sentKeys = 0
    private var isBusy = false
    /// Чтение соседей для предзагрузки — после того как Finder постоял на картинке.
    private var neighborTimer: Timer?
    /// Последние отправленные соседи — одинаковые не шлём повторно.
    private var lastNeighbors: (shown: URL, neighbors: [URL])?
    /// Счётчик нажатий стрелок. Увеличивается на потоке перехвата **до** постановки шага в очередь моста,
    /// чтобы чтение соседей, которое идёт на потоке моста, увидело нажатие и прервалось.
    private let stepCount = OSAllocatedUnfairLock(initialState: 0)
    /// Удалённые в этом сеансе просмотра — `⌘Z` возвращает только их (иначе отменили бы чужое действие в Finder).
    private var trashed: [URL] = []
    /// Идёт удаление или возврат: ждём, пока файл исчезнет (появится).
    private var trashOperation: TrashOperation?
    private var trashTimer: Timer?
    /// `⌘⌫`, отложенный до того, как долетят отправленные стрелки.
    private var pendingTrash: Timer?
    /// Когда Finder в последний раз получил от нас стрелку.
    private var lastKeyPost = Date.distantPast

    /// Без открытого просмотра ждём, пока выделение перестанет меняться (зажатая стрелка в Finder).
    private static let debounceInterval = 0.05
    /// Если Finder не сдвинул выделение за это время — край списка. Finder отвечает за 20–70 мс,
    /// в колонках до 180 мс (замер FinderFollowProbe).
    private static let edgeTimeout = 0.3
    /// На каждую стрелку пачки — запас: в колонках Finder тратит ~20 мс на шаг (прототип burst).
    private static let edgeTimeoutPerJumpStep = 0.04
    /// Дальше не заглядываем: ~1–2 мс на элемент, а поток моста в это время занят.
    private static let lookaheadLimit = 1000
    /// Соседей читаем, когда листание остановилось: при зажатой стрелке шаги идут чаще, и каждый отменяет чтение.
    private static let neighborDelay = 0.15
    /// Соседей ищем недалеко: предзагрузка — не листание, держать поток моста ради неё долго нельзя.
    private static let neighborLimit = 50
    /// Finder удаляет и возвращает файл за 0,2–1,5 с (прототип FinderTrashProbe): дольше 3 с — предупреждаем,
    /// после 12 с — сдаёмся.
    private static let trashSlow = 3.0
    private static let trashGiveUp = 12.0
    /// Finder отвечает на стрелку за 20–180 мс — после этого выделение уже не сдвинется.
    private static let keysSettleTime = 0.35
    /// Цель после удаления ищем не дальше: поиск идёт до отправки ⌘⌫, держать его долго нельзя.
    private static let trashTargetLimit = 200

    private static let notifications = [
        kAXFocusedUIElementChangedNotification,
        kAXSelectedRowsChangedNotification,
        kAXSelectedChildrenChangedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    init(
        state: InterceptionState,
        onShow: @escaping @Sendable (URL) -> Void,
        onBusy: @escaping @Sendable (Bool) -> Void,
        onNeighbors: @escaping @Sendable ([URL], URL) -> Void,
        onTrash: @escaping @Sendable (TrashEvent) -> Void
    ) {
        self.state = state
        self.onShow = onShow
        self.onBusy = onBusy
        self.onNeighbors = onNeighbors
        self.onTrash = onTrash
    }

    func start() {
        thread.perform { self.attach() }
    }

    /// Finder перезапустился — у него новый pid, старая подписка мертва.
    func reattach() {
        thread.perform { self.attach() }
    }

    /// Finder стал активным: уведомления о фокусе приходят не всегда, обновим снимок сами.
    func refreshSoon() {
        state.update { $0.isFinderStateStale = true }
        thread.perform { self.scheduleRefresh() }
    }

    /// Просмотр открыт на `url` и дальше листается вслед за выделением Finder.
    func startFollowing(at url: URL) {
        thread.perform {
            self.navigation = FinderNavigation(showing: url)
            self.queuedStep = nil
            self.edgeTimer?.invalidate()
            self.lastNeighbors = nil
            self.trashed.removeAll()
            self.cancelTrash()
            self.scheduleNeighbors()
        }
    }

    /// Просмотр закрыт. Если Finder стоит на не-изображении, сначала вернём выделение на картинку.
    func stopFollowing() {
        thread.perform {
            self.queuedStep = nil
            self.neighborTimer?.invalidate()
            self.trashed.removeAll()
            self.cancelTrash()
            self.execute(self.navigation?.finish() ?? [])
            self.forgetNavigationIfDone()
        }
    }

    /// `⌘⌫` в просмотре: переместить показанную картинку в Корзину через Finder.
    /// Проверка «можно ли» (Корзина, защита, права) — до вызова, у вызывающего.
    func trash(_ url: URL) {
        thread.perform { self.performTrash(url) }
    }

    /// `⌘Z` в просмотре: вернуть последнюю удалённую в этом сеансе.
    func undoTrash() {
        thread.perform { self.performUndoTrash() }
    }

    /// Пользователь нажал стрелку в просмотре (вызывается с потока перехвата).
    func step(_ key: ArrowKey) {
        stepCount.withLock { $0 += 1 }
        thread.perform { self.performStep(key) }
    }

    // MARK: - Поток моста: подписка

    private func attach() {
        detach()
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderBundleID).first else {
            log.info("Finder не запущен")
            return
        }
        let pid = finder.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        // Подвисший Finder не должен держать поток моста дольше секунды.
        AXUIElementSetMessagingTimeout(app, 1.0)

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<FinderBridge>.fromOpaque(refcon).takeUnretainedValue().scheduleRefresh()
        }
        var created: AXObserver?
        let error = AXObserverCreate(pid, callback, &created)
        guard error == .success, let created else {
            log.error("AXObserverCreate: \(error.rawValue)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            let result = AXObserverAddNotification(created, app, name as CFString, refcon)
            if result != .success {
                log.error("Подписка \(name): \(result.rawValue)")
            }
        }
        thread.add(AXObserverGetRunLoopSource(created))
        observer = created
        finderApp = app
        finderPID = pid
        log.info("Подписка на Finder (pid \(pid))")
        refresh()
    }

    private func detach() {
        debounce?.invalidate()
        debounce = nil
        if let observer {
            thread.remove(AXObserverGetRunLoopSource(observer))
        }
        observer = nil
        finderApp = nil
        finderPID = 0
        state.update { $0.isFinderStateStale = true }
    }

    private func scheduleRefresh() {
        state.update { $0.isFinderStateStale = true }
        debounce?.invalidate()
        // При открытом просмотре — без ожидания: иначе при зажатой стрелке картинка застынет до отпускания.
        let interval = navigation == nil ? Self.debounceInterval : 0
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.current.add(timer, forMode: .default)
        debounce = timer
    }

    // MARK: - Поток моста: снимок

    private func refresh() {
        guard let finderApp else { return }
        guard let focused = element(attribute(finderApp, kAXFocusedUIElementAttribute)) else {
            // Нет фокуса (нет окон) — выделения тоже нет.
            publish(isTextField: false, selection: [])
            return
        }
        if isEditableText(focused) {
            publish(isTextField: true, selection: [])
            return
        }
        viewKind = kind(of: focused)
        viewElement = focused
        let items = elements(attribute(focused, kAXSelectedRowsAttribute))
            ?? elements(attribute(focused, kAXSelectedChildrenAttribute))
            ?? []
        let selection = items.compactMap { findURL($0, depth: 2) }
        publish(isTextField: false, selection: selection)

        // Пустое выделение бывает промежуточным (колонки перестраиваются), несколько файлов — не наш шаг.
        // Пока идёт удаление или возврат, выделение Finder ставит сам как придётся — цель выделим мы.
        if navigation != nil, trashOperation == nil, selection.count == 1 {
            let url = selection[0]
            let outputs = navigation?.selectionChanged(to: url, isImage: ImageDirectory.isImage(url)) ?? []
            execute(outputs)
            forgetNavigationIfDone()
            runQueuedStepIfLanded()
            scheduleNeighbors()
        }
    }

    // MARK: - Поток моста: шаг пользователя

    private func performStep(_ key: ArrowKey) {
        // Перелистнули — отложенное удаление показанной картинки больше не к месту.
        pendingTrash?.invalidate()
        pendingTrash = nil
        guard let current = navigation, !current.isFinishing, trashOperation == nil else { return }
        neighborTimer?.invalidate()
        // Пока пачка в полёте, Finder стоит где-то посреди документов: заглянув оттуда, мы отправили бы
        // вторую пачку и перелетели цель. Откладываем нажатие до показа картинки.
        if current.isJumping {
            queuedStep = key
            return
        }
        let direction = viewKind.finderKey(for: key)
        switch lookahead(direction) {
        case .jump(let keys, let target)?:
            execute(navigation?.jump(keys, direction: direction, to: target) ?? [], timeoutSteps: keys.count)
        case .nothingAhead?:
            navigation?.stay()
        case nil:
            execute(navigation?.userStep(direction) ?? [])
        }
        publishBusy()
    }

    /// Долетели до последнего подгруженного элемента — Finder подгрузил следующие, ищем картинку снова.
    /// Дальше элементов нет — возвращаемся к ближайшей картинке позади (это показанная).
    private func continueLookahead(_ direction: ArrowKey) {
        switch lookahead(direction) {
        case .jump(let keys, let target)?:
            execute(navigation?.jump(keys, direction: direction, to: target) ?? [], timeoutSteps: keys.count)
        case .nothingAhead?, nil:
            if case .jump(let keys, let target)? = lookahead(direction.opposite) {
                execute(navigation?.jump(keys, direction: direction.opposite, to: target) ?? [], timeoutSteps: keys.count)
            } else {
                navigation?.stay()
            }
        }
    }

    private func runQueuedStepIfLanded() {
        guard let key = queuedStep, let navigation, !navigation.isJumping else { return }
        queuedStep = nil
        performStep(key)
    }

    private enum Lookahead {
        case jump(keys: [ArrowKey], target: URL)
        case nothingAhead
    }

    /// Ищет ближайшую картинку в сторону `direction` среди элементов вида и прокладывает к ней путь.
    /// Если среди подгруженных (значки, галерея) картинки нет — путь к последнему подгруженному элементу:
    /// Finder прокрутит и подгрузит следующие (`.lookAgain`). `nil` — заглянуть нельзя (рабочий стол,
    /// группы в значках, выделенный не найден) — тогда шагаем по одному.
    private func lookahead(_ direction: ArrowKey) -> Lookahead? {
        guard let (items, positions, start) = displayedItems() else { return nil }

        let step = direction.isForward ? 1 : -1
        var index = start
        var count = 0
        var lastFile: (index: Int, url: URL, count: Int)?
        while true {
            index += step
            guard items.indices.contains(index) else {
                // «Список» и колонка отдают все элементы — их краю можно верить. В значках и галерее
                // подгруженные элементы заходят за видимую часть с запасом, а выделенный Finder держит
                // на экране: если за ним нет ни одного подгруженного файла — это конец папки. Слепую
                // стрелку слать нельзя: в значках Finder трактует → по сетке и из короткого последнего
                // ряда уводит на значок в ряду выше (так и получался цикл e-img ↔ c-img).
                guard let lastFile, viewKind == .icons || viewKind == .gallery else { return .nothingAhead }
                return path(to: lastFile.index, from: start, count: lastFile.count, positions: positions, direction: direction)
                    .map { .jump(keys: $0, target: lastFile.url) }
            }
            // Строки без файла (заголовки групп) Finder стрелкой пропускает — их не считаем.
            guard let url = findURL(items[index], depth: 2) else { continue }
            count += 1
            if count > Self.lookaheadLimit { return nil }
            lastFile = (index, url, count)
            if ImageDirectory.isImage(url) {
                return path(to: index, from: start, count: count, positions: positions, direction: direction)
                    .map { .jump(keys: $0, target: url) }
            }
        }
    }

    /// Элементы вида в экранном порядке, их положения (только для значков и галереи) и индекс выделенного.
    /// `nil` — заглянуть нельзя (рабочий стол, группы в значках, выделенный не найден).
    private func displayedItems() -> (items: [AXUIElement], positions: [CGPoint?], selected: Int)? {
        guard let viewElement, let (items, positions) = orderedItems(),
              let selected = elements(attribute(viewElement, kAXSelectedRowsAttribute))?.first
                ?? elements(attribute(viewElement, kAXSelectedChildrenAttribute))?.first,
              let start = items.firstIndex(where: { CFEqual($0, selected) }) else { return nil }
        return (items, positions, start)
    }

    /// Элементы вида в экранном порядке и их положения (только для значков и галереи).
    private func orderedItems() -> (items: [AXUIElement], positions: [CGPoint?])? {
        guard [.list, .columns, .gallery, .icons].contains(viewKind), let viewElement else { return nil }
        var items: [AXUIElement]
        var positions: [CGPoint?] = []
        if let rows = elements(attribute(viewElement, kAXRowsAttribute)) {
            items = rows
        } else {
            let children = elements(attribute(viewElement, kAXChildrenAttribute)) ?? []
            // Значки и галерея: элементы лежат внутри секций (AXList). Несколько секций — группировка,
            // у каждой своя сетка; путь между ними не прокладываем.
            let sections = children.filter { attribute($0, kAXRoleAttribute) as? String == kAXListRole }
            if viewKind == .icons, sections.count > 1 { return nil }
            items = sections.isEmpty ? children : sections.flatMap { elements(attribute($0, kAXChildrenAttribute)) ?? [] }
        }
        if viewKind == .icons || viewKind == .gallery {
            // Экранный порядок в AX не гарантирован — упорядочиваем по положению на экране.
            let unordered = items.map(position)
            let order = IconGridPath.displayOrder(of: unordered, rowMajor: viewKind == .icons)
            items = order.map { items[$0] }
            positions = order.map { unordered[$0] }
        }
        return (items, positions)
    }

    // MARK: - Поток моста: удаление в Корзину

    /// `⌘⌫` удаляет то, что выделено в Finder, поэтому всё проверяется прямо перед отправкой:
    /// ничего не в полёте, Finder активен, выделен ровно показанный файл.
    private func performTrash(_ url: URL) {
        pendingTrash?.invalidate()
        pendingTrash = nil
        // Пользователь успел перелистнуть — удалять уже нечего, молча.
        guard trashOperation == nil, let navigation, navigation.isSettled, navigation.shown == url else { return }
        // Стрелка ещё может быть в очереди Finder: ⌘⌫ после неё удалил бы соседний файл. Ждём и проверяем заново.
        let wait = Self.keysSettleTime - Date().timeIntervalSince(lastKeyPost)
        if wait > 0 {
            let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in self?.performTrash(url) }
            RunLoop.current.add(timer, forMode: .default)
            pendingTrash = timer
            return
        }
        guard isFinderReady, let focused = focusedViewElement() else { return }
        viewKind = kind(of: focused)
        viewElement = focused
        guard let (items, _, index) = displayedItems(), findURL(items[index], depth: 2) == url else {
            onTrash(.notHere)
            return
        }
        // Цель — до удаления: после него элементы окна перестроятся, а выделение Finder непредсказуемо.
        let target = TrashTarget.choose(
            deleting: index, count: items.count,
            url: { self.findURL(items[$0], depth: 2) }, isImage: ImageDirectory.isImage, limit: Self.trashTargetLimit
        )
        // Поиск цели занял время — фокус и выделение перечитываем прямо перед отправкой.
        guard isFinderReady, let again = focusedViewElement(), CFEqual(again, focused),
              selectedItems(of: focused).count == 1,
              selectedItems(of: focused).first.flatMap({ findURL($0, depth: 2) }) == url,
              Date().timeIntervalSince(lastKeyPost) >= Self.keysSettleTime else {
            log.error("Удаление отменено: выделение в Finder изменилось")
            onTrash(.cancelled)
            return
        }
        neighborTimer?.invalidate()
        edgeTimer?.invalidate()
        queuedStep = nil
        trashOperation = TrashOperation(url: url, target: target, isUndo: false)
        postCommand(Self.deleteKey)
        startTrashPolling()
    }

    private func performUndoTrash() {
        guard trashOperation == nil, navigation != nil, isFinderReady else { return }
        guard let url = trashed.last else {
            onTrash(.nothingToUndo)
            return
        }
        trashed.removeLast()
        // Файл уже на месте (вернули иначе или на его место положили другой) — ⌘Z отменил бы что-то чужое.
        if FileManager.default.fileExists(atPath: url.path) {
            onTrash(.alreadyBack(url))
            return
        }
        neighborTimer?.invalidate()
        edgeTimer?.invalidate()
        queuedStep = nil
        trashOperation = TrashOperation(url: url, target: nil, isUndo: true)
        postCommand(Self.zKey)
        startTrashPolling()
    }

    /// Finder активен и просмотр открыт в режиме «следовать»: иначе клавиши Finder слать нельзя.
    private var isFinderReady: Bool {
        let snapshot = state.snapshot
        return snapshot.isViewerVisible && snapshot.isFollowingFinder && snapshot.isFinderFrontmost
    }

    private func focusedViewElement() -> AXUIElement? {
        guard let finderApp else { return nil }
        return element(attribute(finderApp, kAXFocusedUIElementAttribute))
    }

    private func selectedItems(of view: AXUIElement) -> [AXUIElement] {
        elements(attribute(view, kAXSelectedRowsAttribute)) ?? elements(attribute(view, kAXSelectedChildrenAttribute)) ?? []
    }

    private func startTrashPolling() {
        trashTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.pollTrash() }
        RunLoop.current.add(timer, forMode: .default)
        trashTimer = timer
    }

    private func pollTrash() {
        guard var operation = trashOperation else {
            cancelTrash()
            return
        }
        let exists = FileManager.default.fileExists(atPath: operation.url.path)
        let elapsed = Date().timeIntervalSince(operation.started)
        if operation.isUndo ? exists : !exists {
            finishTrash()
        } else if elapsed > Self.trashGiveUp {
            // Не возвращаем запись в стек вслепую: что сделал Finder, мы не знаем.
            log.error("Finder не \(operation.isUndo ? "вернул" : "удалил", privacy: .public) файл за \(Self.trashGiveUp) с")
            cancelTrash()
            onTrash(.failed(undo: operation.isUndo))
        } else if elapsed > Self.trashSlow, !operation.isSlow {
            // Обычно 0,2–1,5 с. Дольше — возможно, Finder что-то спрашивает в окне под оверлеем. Ждём дальше:
            // поздно удалённый файл всё равно засчитаем.
            operation.isSlow = true
            trashOperation = operation
            onTrash(.slow(undo: operation.isUndo))
        }
    }

    private func finishTrash() {
        guard let operation = trashOperation else { return }
        cancelTrash()
        // Окно перестроилось — заново берём элемент вида с фокусом.
        if let focused = focusedViewElement() {
            viewKind = kind(of: focused)
            viewElement = focused
        }
        let shown: URL?
        if operation.isUndo {
            shown = operation.url
        } else {
            trashed.append(operation.url)
            shown = operation.target
        }
        if let shown {
            select(shown)
            navigation = FinderNavigation(showing: shown)
            lastNeighbors = nil
            // Finder перестраивает вид асинхронно и может поставить своё выделение уже после нашего — проверим ещё раз.
            let check = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in self?.reselectIfNeeded(shown) }
            RunLoop.current.add(check, forMode: .default)
            scheduleNeighbors()
        }
        onTrash(operation.isUndo ? .restored(operation.url) : .moved(deleted: operation.url, next: shown))
    }

    private func reselectIfNeeded(_ url: URL) {
        guard trashOperation == nil, navigation?.shown == url, let viewElement,
              selectedItems(of: viewElement).first.flatMap({ findURL($0, depth: 2) }) != url else { return }
        select(url)
    }

    private func cancelTrash() {
        trashTimer?.invalidate()
        trashTimer = nil
        trashOperation = nil
        pendingTrash?.invalidate()
        pendingTrash = nil
    }

    /// Выделить файл в Finder через AX — так же надёжно во всех видах (прототип FinderTrashProbe).
    private func select(_ url: URL) {
        guard let viewElement, let (items, _) = orderedItems(),
              let item = items.first(where: { findURL($0, depth: 2) == url }) else {
            log.error("Не нашёл в окне Finder файл, который нужно выделить")
            return
        }
        let key = elements(attribute(viewElement, kAXRowsAttribute)) != nil ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute
        let result = AXUIElementSetAttributeValue(viewElement, key as CFString, [item] as CFArray)
        if result != .success { log.error("Finder не дал выделить файл: \(result.rawValue)") }
    }

    // MARK: - Поток моста: соседи для предзагрузки

    private func scheduleNeighbors() {
        neighborTimer?.invalidate()
        guard navigation != nil else { return }
        let timer = Timer(timeInterval: Self.neighborDelay, repeats: false) { [weak self] _ in
            self?.readNeighbors()
        }
        RunLoop.current.add(timer, forMode: .default)
        neighborTimer = timer
    }

    /// Finder стоит на показанной картинке и никуда не летит — читаем соседей в порядке окна.
    /// Новое нажатие стрелки прерывает чтение: листание важнее предзагрузки.
    private func readNeighbors() {
        guard let navigation, navigation.isSettled, queuedStep == nil else { return }
        let ticket = stepCount.withLock { $0 }
        guard let (items, _, selected) = displayedItems(),
              // Выделение в Finder могло сдвинуться, а уведомление ещё не обработано — соседи были бы не те.
              findURL(items[selected], depth: 2) == navigation.shown else { return }
        var interrupted = false
        let neighbors = PrefetchWindow.neighbors(
            of: selected, count: items.count,
            url: { index in
                if interrupted || self.stepCount.withLock({ $0 }) != ticket {
                    interrupted = true
                    return nil
                }
                return self.findURL(items[index], depth: 2)
            },
            isImage: ImageDirectory.isImage,
            limit: Self.neighborLimit
        )
        guard !interrupted else { return }
        if let last = lastNeighbors, last.shown == navigation.shown, last.neighbors == neighbors { return }
        lastNeighbors = (navigation.shown, neighbors)
        onNeighbors(neighbors, navigation.shown)
    }

    /// Клавиши до элемента `target`: в списке, колонках и галерее — `count` одинаковых стрелок,
    /// в значках — путь по сетке по координатам значков.
    private func path(to target: Int, from start: Int, count: Int, positions: [CGPoint?], direction: ArrowKey) -> [ArrowKey]? {
        guard viewKind == .icons else { return Array(repeating: direction, count: count) }
        guard let from = positions[start], let to = positions[target] else { return nil }
        let known = positions.compactMap { $0 }
        return IconGridPath.keys(
            from: from, to: to,
            rowYs: Array(Set(known.map(\.y))), colXs: Array(Set(known.map(\.x)))
        )
    }

    private func position(of element: AXUIElement) -> CGPoint? {
        guard let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func publish(isTextField: Bool, selection: [URL]) {
        let hasImage = selection.contains(where: ImageDirectory.isImage)
        state.update {
            $0.isTextFieldFocused = isTextField
            $0.selection = selection
            $0.selectionHasImage = hasImage
            $0.isFinderStateStale = false
        }
    }

    private func forgetNavigationIfDone() {
        if navigation == nil || navigation?.isDone == true {
            navigation = nil
            edgeTimer?.invalidate()
        }
        publishBusy()
    }

    /// Занят — пока пачка в полёте или автомат шагает/возвращается, а Finder стоит на не-изображении.
    private func publishBusy() {
        let busy = navigation.map {
            !$0.isFinishing && ($0.isJumping || ($0.mode != .idle && !$0.lastObservedIsImage))
        } ?? false
        guard busy != isBusy else { return }
        isBusy = busy
        onBusy(busy)
    }

    // MARK: - Поток моста: листание

    private func execute(_ outputs: [FinderNavigation.Output], timeoutSteps: Int = 1) {
        var didSend = false
        for output in outputs {
            switch output {
            case .send(let key):
                post(key)
                didSend = true
            case .show(let url):
                onShow(url)
            case .lookAgain(let direction):
                continueLookahead(direction)
            }
        }
        guard didSend else { return }
        edgeTimer?.invalidate()
        let timeout = Self.edgeTimeout + Double(max(timeoutSteps - 1, 0)) * Self.edgeTimeoutPerJumpStep
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            self?.edgeTimeoutFired()
        }
        RunLoop.current.add(timer, forMode: .default)
        edgeTimer = timer
    }

    private func edgeTimeoutFired() {
        guard navigation != nil else { return }
        // Таймеры run loop срабатывают раньше источников: уведомление о сдвиге могло уже лежать в очереди.
        // Перечитываем выделение и объявляем край, только если Finder так и не сдвинулся.
        let before = sentKeys
        refresh()
        guard sentKeys == before else { return }
        execute(navigation?.timedOut() ?? [])
        forgetNavigationIfDone()
        runQueuedStepIfLanded()
    }

    private static let deleteKey: CGKeyCode = 51
    private static let zKey: CGKeyCode = 6

    /// ⌘-сочетание напрямую процессу Finder (⌘⌫, ⌘Z) — с меткой, чтобы перехват его пропустил.
    private func postCommand(_ keyCode: CGKeyCode) {
        guard finderApp != nil, finderPID != 0 else { return }
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: KeyInterceptor.syntheticEventMarker)
            event.postToPid(finderPID)
        }
    }

    /// Стрелка напрямую процессу Finder: ни наш перехват, ни чужие её не видят.
    /// Отдельное состояние источника — чтобы зажатые пользователем модификаторы не подмешались.
    private func post(_ key: ArrowKey) {
        guard finderApp != nil, finderPID != 0 else { return }
        sentKeys += 1
        lastKeyPost = Date()
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: isDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: KeyInterceptor.syntheticEventMarker)
            event.postToPid(finderPID)
        }
    }

    // MARK: - AX

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func element(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elements(_ value: AnyObject?) -> [AXUIElement]? {
        guard let array = value as? [AXUIElement], !array.isEmpty else { return nil }
        return array
    }

    /// Вид окна по сфокусированному элементу (идентификаторы — из прототипа FinderAXProbe).
    private func kind(of element: AXUIElement) -> FinderViewKind {
        switch attribute(element, kAXIdentifierAttribute) as? String {
        case "ListView": return .list
        case "IconView": return .icons
        case "GalleryView": return .gallery
        default:
            // Колонка — список без идентификатора.
            return attribute(element, kAXRoleAttribute) as? String == kAXListRole ? .columns : .other
        }
    }

    /// Поле переименования, строка поиска, «Переход к папке»: роль текстового поля и изменяемое значение.
    private func isEditableText(_ element: AXUIElement) -> Bool {
        guard let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return false }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// Путь к файлу лежит в `AXURL` у элемента выделения или его потомка: в значках и галерее —
    /// у картинки внутри группы, в списке — у текстового поля внутри ячейки строки.
    private func findURL(_ element: AXUIElement, depth: Int) -> URL? {
        if let url = attribute(element, kAXURLAttribute) as? URL, url.isFileURL {
            return url
        }
        guard depth > 0, let children = elements(attribute(element, kAXChildrenAttribute)) else { return nil }
        for child in children {
            if let url = findURL(child, depth: depth - 1) { return url }
        }
        return nil
    }
}
