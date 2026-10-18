import AppKit
import IOSurface
import VisionKit
import os

/// Затемнённый фон и изображение. Большие изображения вписываются в экран, маленькие показываются
/// в естественном размере и не растягиваются. Масштаб — клавишами и жестами трекпада, сдвиг увеличенной
/// картинки — перетаскиванием и прокруткой. Геометрия — в `ZoomModel`.
final class ViewerView: NSView {
    var onCommand: ((ViewerCommand) -> Void)?
    /// Масштаб изменился — контроллер решает, не пора ли декодировать картинку в большем разрешении.
    var onZoomChanged: ((ZoomModel) -> Void)?
    /// Режим «свой список»: нажатия — для сведений о снимке по `⌥` и Live Text по `⌘` (модификаторы ловит
    /// монитор контроллера: после щелчка по тексту клавиатура у оверлея VisionKit, а не у просмотра).
    var onKeyPressed: ((_ isArrow: Bool) -> Void)?
    /// Стрелка зажата (автоповтор) — свой список; в режиме «следовать» об этом сообщает перехват.
    var onArrowHeld: (() -> Void)?
    /// Кнопка «Поделиться» рядом с кнопками VisionKit.
    var onShare: (() -> Void)?
    /// Кнопка Live Text (подсветить весь текст) — фиксирует режим, `⌘` можно отпустить.
    var onLiveTextLatch: ((Bool) -> Void)?
    /// Масштаб, сдвиг или поворот изменили — в режиме Live Text контроллер распознаёт видимую часть заново.
    var onViewChanged: (() -> Void)?

    /// Соседняя картинка для смахивания (`true` — следующая).
    enum SwipeNeighbor {
        /// Листать некуда — край.
        case none
        /// Есть, но ещё не декодирована — въезжает пустой фон.
        case pending
        case image(DecodedImage)

        var exists: Bool {
            if case .none = self { return false }
            return true
        }
    }
    var swipeNeighbor: ((_ forward: Bool) -> SwipeNeighbor)?
    /// Смахивание довели до конца — контроллер листает. `false` — не перелистнул.
    var onSwipe: ((_ forward: Bool) -> Bool)?

    private let imageLayer = CALayer()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// Индикатор ожидания: Finder пропускает документы между картинками или картинка долго декодируется.
    private let spinnerBackground = NSView()
    private let spinner = NSProgressIndicator()
    /// Плашка масштаба: «200 %» или «Вписать» внизу экрана на секунду.
    private let zoomBadge = NSView()
    private let zoomLabel = NSTextField(labelWithString: "")
    private var zoomBadgeHide: Task<Void, Never>?
    /// Смахивание: соседняя картинка въезжает в этом слое; текущая сдвинута на `swipeOffset`.
    private let neighborLayer = CALayer()
    private var swipe: SwipeTracker?
    private var swipeNeighbors: (next: SwipeNeighbor, previous: SwipeNeighbor) = (.none, .none)
    private var swipeOffset: CGFloat = 0
    private var isSwipeAnimating = false
    /// Чем закончится идущая анимация смахивания — чтобы новое смахивание могло сразу её довести.
    private var animatingDecision: (decision: SwipeTracker.Decision, forward: Bool, generation: Int)?
    private var swipeGeneration = 0
    /// После смахивания трекпад ещё с секунду шлёт инерцию — её глотаем до конца, иначе она сдвинула бы
    /// новую картинку, если та открылась с запомненным масштабом.
    private var swallowsSwipeMomentum = false
    private let swipeLog = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "swipe")
    /// Сколько раз показывали новую картинку — так смахивание понимает, показал ли контроллер следующую сразу.
    private var shownCount = 0
    /// Сведения о снимке — карточка в углу, пока удерживается `⌥`.
    private let infoPanel = NSVisualEffectView()
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private var infoConstraints: [InfoPanelPosition: [NSLayoutConstraint]] = [:]
    private var infoPosition = InfoPanelPosition.topRight
    private var animatesInfo = true
    private var isInfoShown = false
    /// Точки меток показанного файла — в правом верхнем углу экрана (не картинки: не ездят при масштабе и
    /// смахивании).
    private let tagDots = NSStackView()
    private var tagColors: [NSColor] = []
    /// Зажата стрелка — точки спрятаны до остановки.
    private var tagDotsHeld = false
    /// Live Text: оверлей VisionKit ровно на картинке — масштабируется и сдвигается с ней, `contentsRect` — вся
    /// его площадь, поворот задаёт анализ. Так рамки текста совпадают при любом масштабе и повороте; оверлей на весь
    /// экран при увеличении съезжает (прототип `LiveTextProbe`).
    private let liveOverlay = ImageAnalysisOverlayView()
    /// Распознанная часть картинки — в долях неповёрнутой картинки от левого верхнего угла; вся — `unitRect`.
    /// Оверлей лежит на ней: при увеличении распознаётся видимая часть, и мелкий текст становится крупнее.
    private var liveCrop = ViewerView.unitRect
    private let shareButton = NSButton()
    private static let shareSize: CGFloat = 26
    /// Режим Live Text (удержание `⌘`): кнопки видны, перетаскивание выделяет текст, а не двигает картинку.
    private(set) var isLiveMode = false

    private(set) var zoom: ZoomModel?
    private var isDragging = false
    /// Настройки, применённые при последнем открытии просмотра.
    private var fitFraction: CGFloat = 1
    private var upscalesSmallImages = false
    private var spaceClosesViewer = true
    private var lastDragPoint: CGPoint = .zero

    private static let zoomAnimationDuration = 0.15

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        apply(ViewerPreferences())

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        neighborLayer.contentsGravity = .resizeAspect
        neighborLayer.minificationFilter = .trilinear
        neighborLayer.isHidden = true
        layer?.addSublayer(neighborLayer)
        // До подписей и индикатора — они должны быть поверх.
        setUpLiveText()

        messageLabel.font = .systemFont(ofSize: 15)
        // Фон всегда тёмный, поэтому цвет фиксированный, а не системный (в светлой теме тот тёмный).
        messageLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
        ])

        // Подложка, чтобы индикатор был виден и на светлой картинке.
        spinnerBackground.wantsLayer = true
        spinnerBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        spinnerBackground.layer?.cornerRadius = 14
        spinnerBackground.isHidden = true
        spinnerBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinnerBackground)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinnerBackground.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinnerBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinnerBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinnerBackground.widthAnchor.constraint(equalToConstant: 64),
            spinnerBackground.heightAnchor.constraint(equalToConstant: 64),
            spinner.centerXAnchor.constraint(equalTo: spinnerBackground.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: spinnerBackground.centerYAnchor),
        ])

        zoomBadge.wantsLayer = true
        zoomBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        zoomBadge.layer?.cornerRadius = 10
        zoomBadge.alphaValue = 0
        zoomBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomBadge)
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        zoomLabel.textColor = .white
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomBadge.addSubview(zoomLabel)
        NSLayoutConstraint.activate([
            zoomBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            zoomBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -48),
            zoomLabel.leadingAnchor.constraint(equalTo: zoomBadge.leadingAnchor, constant: 14),
            zoomLabel.trailingAnchor.constraint(equalTo: zoomBadge.trailingAnchor, constant: -14),
            zoomLabel.topAnchor.constraint(equalTo: zoomBadge.topAnchor, constant: 7),
            zoomLabel.bottomAnchor.constraint(equalTo: zoomBadge.bottomAnchor, constant: -7),
        ])

        setUpInfoPanel()
        setUpTagDots()
    }

    private func setUpInfoPanel() {
        infoPanel.material = .hudWindow
        infoPanel.blendingMode = .withinWindow
        infoPanel.state = .active
        infoPanel.wantsLayer = true
        infoPanel.layer?.cornerRadius = 12
        infoPanel.layer?.masksToBounds = true
        infoPanel.alphaValue = 0
        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(infoPanel)
        infoLabel.textColor = .white
        infoLabel.maximumNumberOfLines = 0
        infoLabel.preferredMaxLayoutWidth = 320
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.addSubview(infoLabel)
        NSLayoutConstraint.activate([
            infoLabel.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor, constant: -16),
            infoLabel.topAnchor.constraint(equalTo: infoPanel.topAnchor, constant: 12),
            infoLabel.bottomAnchor.constraint(equalTo: infoPanel.bottomAnchor, constant: -12),
            infoPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 352),
        ])
        let margin: CGFloat = 24
        infoConstraints = [
            .topRight: [infoPanel.topAnchor.constraint(equalTo: topAnchor, constant: margin),
                        infoPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin)],
            .topLeft: [infoPanel.topAnchor.constraint(equalTo: topAnchor, constant: margin),
                       infoPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin)],
            .bottomLeft: [infoPanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
                          infoPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin)],
            .bottomRight: [infoPanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
                           infoPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin)],
        ]
        NSLayoutConstraint.activate(infoConstraints[infoPosition] ?? [])
    }

    private func setUpLiveText() {
        liveOverlay.delegate = self
        liveOverlay.preferredInteractionTypes = []
        liveOverlay.isSupplementaryInterfaceHidden = true
        // Кнопки VisionKit — в 8 pt от краёв видимой части картинки, справа — место под «Поделиться».
        liveOverlay.supplementaryInterfaceContentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 8 + Self.shareSize + 8)
        liveOverlay.isHidden = true
        addSubview(liveOverlay)
        shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: String(localized: "Share"))
        shareButton.bezelStyle = .glass
        shareButton.borderShape = .circle
        shareButton.isHidden = true
        shareButton.target = self
        shareButton.action = #selector(sharePressed)
        addSubview(shareButton)
    }

    @objc private func sharePressed() {
        onShare?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    // MARK: - Содержимое

    var isSpinning: Bool { !spinnerBackground.isHidden }

    func setSpinning(_ spinning: Bool) {
        guard spinning != isSpinning else { return }
        spinnerBackground.isHidden = !spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// Настройки просмотра: фон (цвет и затемнение), «вписать», Пробел.
    func apply(_ preferences: ViewerPreferences) {
        let color = preferences.color
        layer?.backgroundColor = CGColor(
            srgbRed: color.red, green: color.green, blue: color.blue, alpha: preferences.dimming
        )
        fitFraction = preferences.screenFraction
        upscalesSmallImages = preferences.upscaleSmallImages
        spaceClosesViewer = preferences.spaceClosesViewer
        animatesInfo = preferences.animate
        if preferences.infoPosition != infoPosition {
            NSLayoutConstraint.deactivate(infoConstraints[infoPosition] ?? [])
            infoPosition = preferences.infoPosition
            NSLayoutConstraint.activate(infoConstraints[infoPosition] ?? [])
        }
        if var current = zoom {
            current.setFitOptions(fraction: fitFraction, upscalesSmallImages: upscalesSmallImages)
            zoom = current
            applyZoom(animated: false)
        }
    }

    /// Новая картинка: во «вписать» или с запомненными масштабом и местом этой картинки.
    func show(_ loaded: DecodedImage, placement: ZoomPlacement) {
        let size = loaded.isVector ? Self.vectorSize(loaded.pointSize, in: bounds.size) : loaded.pointSize
        var next: ZoomModel
        if let current = zoom {
            next = current
            next.replaceImage(size: size)
        } else {
            next = ZoomModel(
                imageSize: size, viewSize: bounds.size,
                fitFraction: fitFraction, upscalesSmallImages: upscalesSmallImages
            )
        }
        if case .restore(let scale, let offset, let turns) = placement {
            next.restore(scale: scale, offset: offset, quarterTurns: turns)
        }
        zoom = next
        shownCount += 1
        // `IOSurface` из сервиса декодирования — слой показывает его напрямую, без копирования.
        imageLayer.contents = loaded.surface
        messageLabel.isHidden = true
        applyZoom(animated: false)
    }

    /// Та же картинка в большем разрешении — подменяем пиксели, не трогая масштаб и сдвиг.
    func upgrade(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        CATransaction.commit()
    }

    func showError(fileName: String) {
        imageLayer.contents = nil
        zoom = nil
        messageLabel.stringValue = "\(fileName)\n" + String(localized: "Couldn't open")
        messageLabel.isHidden = false
        setTagDots([], names: [])
        applyZoom(animated: false)
    }

    func clear() {
        setLiveMode(false)
        setLiveAnalysis(nil)
        resetSwipe()
        imageLayer.contents = nil
        zoom = nil
        messageLabel.isHidden = true
        isDragging = false
        zoomBadge.alphaValue = 0
        infoPanel.alphaValue = 0
        isInfoShown = false
        setTagDots([], names: [])
        applyZoom(animated: false)
    }

    override func layout() {
        super.layout()
        if var current = zoom, current.viewSize != bounds.size {
            current.resize(to: bounds.size)
            zoom = current
        }
        applyZoom(animated: false)
    }

    /// У вектора нет естественного размера (иконка SVG бывает 24×24): за 100 % принимаем размер,
    /// растянутый до экрана. Тогда «вписать» — та же доля экрана, что и у больших фото, а увеличение —
    /// обычные 200–800 % от неё.
    nonisolated static func vectorSize(_ size: CGSize, in viewSize: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, viewSize.width > 0, viewSize.height > 0 else { return size }
        let ratio = min(viewSize.width / size.width, viewSize.height / size.height)
        return CGSize(width: size.width * ratio, height: size.height * ratio)
    }

    /// Прямоугольник изображения при «вписать»: по центру, уменьшен до границ, но никогда не увеличен.
    nonisolated static func fittedRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        ZoomModel(imageSize: imageSize, viewSize: bounds.size).imageRect.offsetBy(dx: bounds.minX, dy: bounds.minY)
    }

    private func applyZoom(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(Self.zoomAnimationDuration) }
        // Повёрнутая картинка: слою — неповёрнутый размер и поворот вокруг центра прямоугольника на экране.
        let rect = zoom?.imageRect ?? .zero
        let turns = zoom?.quarterTurns ?? 0
        imageLayer.transform = CATransform3DMakeRotation(-CGFloat(turns) * .pi / 2, 0, 0, 1)
        imageLayer.bounds = CGRect(
            origin: .zero,
            size: turns.isMultiple(of: 2) ? rect.size : CGSize(width: rect.height, height: rect.width)
        )
        imageLayer.position = CGPoint(x: rect.midX + swipeOffset, y: rect.midY)
        CATransaction.commit()
        liveOverlay.frame = Self.screenRect(ofUnit: liveCrop, in: rect, quarterTurns: turns).offsetBy(dx: swipeOffset, dy: 0)
        liveOverlay.setContentsRectNeedsUpdate()
        if isLiveMode { placeShareButton() }
        updateCursor()
    }

    // MARK: - Масштаб

    /// Клавиши и «умное увеличение»: плавно, с плашкой.
    func perform(_ command: ViewerCommand, at anchor: CGPoint? = nil) {
        guard var current = zoom else { return }
        switch command {
        case .zoomIn: current.zoomIn(around: anchor)
        case .zoomOut: current.zoomOut(around: anchor)
        case .zoomFit: current.zoomToFit()
        default: return
        }
        commit(current, animated: true)
    }

    /// `⌘→` / `⌘←`: повернуть показ на 90° — плавно, со «вписать».
    func rotate(clockwise: Bool) {
        guard var current = zoom else { return }
        current.rotate(clockwise: clockwise)
        commit(current, animated: true)
    }

    private func commit(_ updated: ZoomModel, animated: Bool) {
        let scaleChanged = updated.scale != zoom?.scale
        zoom = updated
        applyZoom(animated: animated)
        onViewChanged?()
        if scaleChanged {
            showZoomBadge(updated.label)
            onZoomChanged?(updated)
        }
    }

    /// Сообщение в той же плашке, что и масштаб, — чуть дольше, чтобы успеть прочитать.
    func showMessage(_ text: String) {
        showZoomBadge(text, for: .seconds(1.6))
    }

    private func showZoomBadge(_ text: String, for duration: Duration = .seconds(1)) {
        zoomLabel.stringValue = text
        zoomBadge.alphaValue = 1
        zoomBadgeHide?.cancel()
        zoomBadgeHide = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                zoomBadge.animator().alphaValue = 0
            }, completionHandler: nil)
        }
    }

    // MARK: - Трекпад и мышь

    private func point(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// Жесты из перехвата (режим «следовать за Finder»): точка — в координатах экрана.
    func magnify(by magnification: CGFloat, atScreenPoint screenPoint: CGPoint) {
        guard var current = zoom else { return }
        current.magnify(by: magnification, around: point(fromScreen: screenPoint))
        commit(current, animated: false)
    }

    func smartMagnify(atScreenPoint screenPoint: CGPoint) {
        guard var current = zoom else { return }
        current.toggleSmartZoom(at: point(fromScreen: screenPoint))
        commit(current, animated: true)
    }

    private func point(fromScreen screenPoint: CGPoint) -> CGPoint {
        guard let window else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        return convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    }

    /// Сведение и разведение двух пальцев — плавно, в точке между пальцами.
    override func magnify(with event: NSEvent) {
        guard var current = zoom else { return }
        current.magnify(by: event.magnification, around: point(of: event))
        commit(current, animated: false)
    }

    /// Двойное касание двумя пальцами — «вписать» ↔ 100 %.
    override func smartMagnify(with event: NSEvent) {
        guard var current = zoom else { return }
        current.toggleSmartZoom(at: point(of: event))
        commit(current, animated: true)
    }

    /// Прокрутка двумя пальцами или колёсиком двигает увеличенную картинку.
    override func scrollWheel(with event: NSEvent) {
        if handleSwipe(event) { return }
        guard var current = zoom, current.canPan else { return }
        // Колёсико мыши даёт строки, трекпад — точные пункты.
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        current.pan(by: CGVector(dx: event.scrollingDeltaX * factor, dy: -event.scrollingDeltaY * factor))
        commit(current, animated: false)
    }

    // MARK: - Смахивание

    /// Прокрутка двумя пальцами по трекпаду во «вписать» — смахивание. Увеличенная картинка, как и раньше,
    /// двигается (`false` — событие не наше). Колёсико мыши (без фаз) не листает.
    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        // Инерция после смахивания не листает дальше.
        if !event.momentumPhase.isEmpty {
            if swallowsSwipeMomentum {
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled { swallowsSwipeMomentum = false }
                return true
            }
            return swipe != nil || isSwipeAnimating || zoom?.isFit != false
        }
        switch event.phase {
        case .began:
            swallowsSwipeMomentum = false
            // Быстро смахнули ещё раз, пока доезжает прошлое, — довести его сразу, а не терять новое.
            if isSwipeAnimating, let pending = animatingDecision {
                imageLayer.removeAllAnimations()
                neighborLayer.removeAllAnimations()
                completeSwipe(pending.decision, forward: pending.forward, generation: pending.generation)
            }
            guard zoom?.isFit != false else { return false }
            swipeNeighbors = (swipeNeighbor?(true) ?? .none, swipeNeighbor?(false) ?? .none)
            swipe = SwipeTracker(
                width: bounds.width, canGoNext: swipeNeighbors.next.exists, canGoPrevious: swipeNeighbors.previous.exists
            )
            trackSwipe(event)
            return true
        case .changed:
            guard swipe != nil else { return false }
            // Пока вели пальцы, картинку увеличили щипком — это уже не смахивание, а сдвиг.
            guard zoom?.isFit != false else {
                swipe = nil
                placeSwipe(offset: 0)
                return false
            }
            trackSwipe(event)
            return true
        case .ended, .cancelled:
            guard let tracker = swipe else { return false }
            swipe = nil
            let decision = event.phase == .cancelled ? .cancel : tracker.end(time: event.timestamp)
            let motion = tracker.motion(at: event.timestamp)
            let phase = event.phase == .cancelled ? "отменено системой" : tracker.isVertical ? "отпущено, вертикальное" : "отпущено"
            swallowsSwipeMomentum = true
            swipeLog.info("Смахивание \(phase, privacy: .public): путь \(Int(tracker.distance), privacy: .public) пт, скорость \(Int(motion.velocity), privacy: .public) пт/с, в конце \(Int(motion.recent), privacy: .public) пт, соседи \(self.swipeNeighbors.previous.exists ? "←" : "·", privacy: .public)\(self.swipeNeighbors.next.exists ? "→" : "·", privacy: .public) → \(String(describing: decision), privacy: .public)")
            finishSwipe(decision)
            return true
        default:
            return swipe != nil
        }
    }

    private func trackSwipe(_ event: NSEvent) {
        guard var tracker = swipe else { return }
        // Движение пальцев: при «естественной прокрутке» оно совпадает с прокруткой, иначе — обратное.
        let fingers: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        tracker.move(dx: event.scrollingDeltaX * fingers, dy: event.scrollingDeltaY * fingers, time: event.timestamp)
        swipe = tracker
        placeSwipe(offset: tracker.offset)
    }

    /// Просмотр закрыт или открыт заново — смахивание бросить: отложенное завершение не должно листать
    /// новый список, а соседняя картинка — держать память.
    private func resetSwipe() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.removeAllAnimations()
        neighborLayer.removeAllAnimations()
        neighborLayer.isHidden = true
        neighborLayer.contents = nil
        CATransaction.commit()
        swipe = nil
        swipeOffset = 0
        isSwipeAnimating = false
        animatingDecision = nil
        swipeGeneration += 1
        swipeNeighbors = (.none, .none)
        swallowsSwipeMomentum = false
    }

    /// Текущая картинка сдвинута на `offset`, с нужной стороны — соседняя.
    private func placeSwipe(offset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swipeOffset = offset
        applyZoom(animated: false)
        let forward = offset < 0
        let neighbor = forward ? swipeNeighbors.next : swipeNeighbors.previous
        if offset != 0, case .image(let image) = neighbor {
            let size = image.isVector ? Self.vectorSize(image.pointSize, in: bounds.size) : image.pointSize
            let fitted = ZoomModel(
                imageSize: size, viewSize: bounds.size, fitFraction: fitFraction, upscalesSmallImages: upscalesSmallImages
            ).imageRect
            neighborLayer.contents = image.surface
            neighborLayer.frame = fitted.offsetBy(dx: offset + (forward ? bounds.width : -bounds.width), dy: 0)
            neighborLayer.isHidden = false
        } else {
            neighborLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Отпустили: довести до конца (перелистнуть) или вернуть. Без «плавного появления» — быстрее.
    private func finishSwipe(_ decision: SwipeTracker.Decision) {
        let target: CGFloat = switch decision {
        case .next: -bounds.width
        case .previous: bounds.width
        case .cancel: 0
        }
        isSwipeAnimating = true
        let forward = decision == .next
        swipeGeneration += 1
        let generation = swipeGeneration
        animatingDecision = (decision, forward, generation)
        let neighborFrame = neighborLayer.frame.offsetBy(dx: target - swipeOffset, dy: 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animatesInfo ? 0.22 : 0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.completeSwipe(decision, forward: forward, generation: generation) }
        }
        swipeOffset = target
        if let rect = zoom?.imageRect {
            imageLayer.position = CGPoint(x: rect.midX + target, y: rect.midY)
        }
        neighborLayer.frame = neighborFrame
        CATransaction.commit()
    }

    private func completeSwipe(_ decision: SwipeTracker.Decision, forward: Bool, generation: Int) {
        // Уже доведено (новое смахивание довело его раньше конца анимации) — второй раз не листать.
        guard isSwipeAnimating, generation == swipeGeneration else { return }
        animatingDecision = nil
        // Всё в одной транзакции без анимаций: прежняя картинка не мелькнёт в центре.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swipeOffset = 0
        neighborLayer.isHidden = true
        neighborLayer.contents = nil
        isSwipeAnimating = false
        swipeNeighbors = (.none, .none)
        if decision != .cancel {
            // Сначала листает контроллер — пока на экране прежняя картинка, её масштаб и поворот запомнятся
            // под её именем. Готовая в кэше новая показывается сразу (синхронно); ещё не готовая — пусто.
            let shownBefore = shownCount
            if onSwipe?(forward) == true, shownCount == shownBefore { imageLayer.contents = nil }
        }
        applyZoom(animated: false)
        CATransaction.commit()
    }

    // Окно просмотра в режиме «следовать за Finder» неактивно — первый же клик должен работать.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Вне режима Live Text до картинки доходит щелчок сквозь оверлей — он снимает выделение текста.
        if !isLiveMode { liveOverlay.resetSelection() }
        if event.clickCount == 2 {
            guard var current = zoom else { return }
            current.toggleSmartZoom(at: point(of: event))
            commit(current, animated: true)
            return
        }
        guard zoom?.canPan == true else { return }
        isDragging = true
        lastDragPoint = point(of: event)
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, var current = zoom else { return }
        let location = point(of: event)
        current.pan(by: CGVector(dx: location.x - lastDragPoint.x, dy: location.y - lastDragPoint.y))
        lastDragPoint = location
        commit(current, animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        updateCursor()
    }

    // MARK: - Курсор

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`: в режиме «следовать за Finder» Ementium неактивен, а курсор всё равно нужен.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor()
    }

    private func updateCursor() {
        // В режиме Live Text курсор ставит VisionKit (I-образный над текстом).
        if isLiveMode { return }
        if isDragging {
            NSCursor.closedHand.set()
        } else if zoom?.canPan == true {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Live Text

    /// Распознанное на показанной картинке или её части `crop`; `nil` — забыть (другая картинка, поворот).
    func setLiveAnalysis(_ analysis: ImageAnalysis?, crop: CGRect = ViewerView.unitRect) {
        liveCrop = analysis == nil ? Self.unitRect : crop
        applyZoom(animated: false)
        liveOverlay.analysis = analysis
        liveOverlay.preferredInteractionTypes = analysis == nil ? [] : .automatic
        liveOverlay.isHidden = analysis == nil
        // После щелчка по тексту клавиатура у оверлея; спрятанный, он отдаёт её окну — и Esc, Пробел, стрелки
        // никто не разбирает (системный звук), пока не щёлкнешь по картинке. Возвращаем просмотру.
        if analysis == nil, let window, window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        liveOverlay.setSupplementaryInterfaceHidden(!isLiveMode, animated: false)
        if isLiveMode { placeShareButtonAfterAppearance() }
    }

    var hasLiveAnalysis: Bool { liveOverlay.analysis != nil }

    /// Под точкой окна — «пилюля» быстрого действия (`VKCActionInfoButton`) или распознанные данные на картинке
    /// (`VKCDataDetectorElementView`): ссылка, телефон, адрес. Классы VisionKit частные — не узнали, значит `false`.
    func isLiveActionHit(atWindowPoint point: NSPoint) -> Bool {
        guard isLiveMode, !liveOverlay.isHidden, let root = superview else { return false }
        var view = root.hitTest(point)
        while let current = view, current !== self {
            let name = String(describing: type(of: current))
            if name.contains("ActionInfoButton") || name.contains("DataDetectorElement") { return true }
            view = current.superview
        }
        return false
    }

    /// Есть ли что искать «Поиском по изображению» (в регионах, где он недоступен, — нет).
    var hasLookUpResults: Bool { liveOverlay.analysis?.hasResults(for: .visualLookUp) ?? false }

    /// Взаимодействия VisionKit не выключаем (это сбросило бы выделение) — новые начинаются только в режиме
    /// (`shouldBeginAt`), а вне его мышь проходит сквозь оверлей к картинке: сдвиг и смахивание целы.
    func setLiveMode(_ on: Bool) {
        guard on != isLiveMode else { return }
        isLiveMode = on
        liveOverlay.setSupplementaryInterfaceHidden(!on, animated: true)
        shareButton.isHidden = !on
        if on {
            placeShareButtonAfterAppearance()
        } else if liveOverlay.selectableItemsHighlighted {
            liveOverlay.selectableItemsHighlighted = false
        }
        updateCursor()
    }

    /// Выделенный текст; пустой — ничего не выделено.
    var selectedLiveText: String {
        liveOverlay.hasActiveTextSelection ? liveOverlay.selectedText : ""
    }

    /// Видимая часть картинки — в долях неповёрнутой картинки (как `liveCrop`).
    var visibleImageUnitRect: CGRect? {
        guard let zoom, zoom.imageRect.width > 0, zoom.imageRect.height > 0 else { return nil }
        let visible = zoom.imageRect.intersection(bounds)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        return Self.unitRect(ofScreen: visible, in: zoom.imageRect, quarterTurns: zoom.quarterTurns)
    }

    nonisolated static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Точка в долях картинки (от левого верхнего угла) после поворота показа на `quarterTurns` по часовой:
    /// левый верхний угол уходит в правый верхний и т. д. — как поворачивает `imageLayer`.
    nonisolated static func rotateUnit(_ point: CGPoint, quarterTurns: Int) -> CGPoint {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: CGPoint(x: 1 - point.y, y: point.x)
        case 2: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: CGPoint(x: point.y, y: 1 - point.x)
        default: point
        }
    }

    /// Часть неповёрнутой картинки (доли) → прямоугольник на экране, где показана повёрнутая картинка `rect`.
    nonisolated static func screenRect(ofUnit unit: CGRect, in rect: CGRect, quarterTurns: Int) -> CGRect {
        let corners = [CGPoint(x: unit.minX, y: unit.minY), CGPoint(x: unit.maxX, y: unit.maxY)]
            .map { rotateUnit($0, quarterTurns: quarterTurns) }
            .map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.maxY - $0.y * rect.height) }
        return CGRect(
            x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
            width: abs(corners[0].x - corners[1].x), height: abs(corners[0].y - corners[1].y)
        )
    }

    /// Обратное: прямоугольник на экране → часть неповёрнутой картинки (доли).
    nonisolated static func unitRect(ofScreen screen: CGRect, in rect: CGRect, quarterTurns: Int) -> CGRect {
        let corners = [CGPoint(x: screen.minX, y: screen.maxY), CGPoint(x: screen.maxX, y: screen.minY)]
            .map { CGPoint(x: ($0.x - rect.minX) / rect.width, y: (rect.maxY - $0.y) / rect.height) }
            .map { rotateUnit($0, quarterTurns: 4 - ((quarterTurns % 4) + 4) % 4) }
        return CGRect(
            x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
            width: abs(corners[0].x - corners[1].x), height: abs(corners[0].y - corners[1].y)
        )
    }

    /// Где открыть меню «Поделиться» — у кнопки (и когда она скрыта: `⌘S` без режима).
    var shareAnchor: NSRect {
        placeShareButton()
        return shareButton.frame
    }

    /// Нажать кнопку «Поиск по изображению» VisionKit. `false` — её нет (нечего искать или функция недоступна).
    func pressLookUp() -> Bool {
        guard let button = Self.visionKitView(in: liveOverlay, named: "VisualSearch") else { return false }
        if let control = button as? NSControl {
            control.performClick(nil)
        } else if !button.accessibilityPerformPress(), let window {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ) {
                    window.sendEvent(event)
                }
            }
        }
        return true
    }

    /// Справа от кнопки Live Text, того же размера и на той же высоте; её нет (на картинке нет текста) —
    /// в угол видимой части картинки.
    private func placeShareButton() {
        if let liveText = Self.visionKitView(in: liveOverlay, named: "VKImageAnalysisButton") {
            let frame = liveText.convert(liveText.bounds, to: self)
            shareButton.frame = frame.offsetBy(dx: frame.width + 8, dy: 0)
        } else {
            var visible = (zoom?.imageRect ?? .zero).offsetBy(dx: swipeOffset, dy: 0).intersection(bounds)
            // Картинки ещё нет (`⌘S` сразу после открытия) — пересечение пустое или `.null`: угол экрана.
            if visible.isNull || visible.isEmpty { visible = bounds }
            shareButton.frame = NSRect(
                x: visible.maxX - 8 - Self.shareSize, y: visible.minY + 8, width: Self.shareSize, height: Self.shareSize
            )
        }
    }

    /// Кнопки VisionKit появляются с анимацией — посреди неё кнопка Live Text ещё не на месте.
    private func placeShareButtonAfterAppearance() {
        placeShareButton()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isLiveMode else { return }
            self.placeShareButton()
        }
    }

    /// Видимое внутреннее вью VisionKit по имени класса. API, чтобы открыть поиск по изображению или узнать место
    /// кнопок, у VisionKit нет; не нашлось — запасной путь (угол картинки, подсказка), ничего не ломается.
    private static func visionKitView(in root: NSView, named name: String) -> NSView? {
        for view in root.subviews {
            if !view.isHiddenOrHasHiddenAncestor, String(describing: type(of: view)).contains(name) { return view }
            if let found = visionKitView(in: view, named: name) { return found }
        }
        return nil
    }

    // MARK: - Сведения о снимке

    /// Показать (или обновить) карточку: первая строка — имя файла, жирным.
    func showInfo(_ lines: [String]) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            let font: NSFont = index == 0 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
            text.append(NSAttributedString(string: line, attributes: [
                .font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
            ]))
        }
        infoLabel.attributedStringValue = text
        isInfoShown = true
        updateTagDots(animated: true)
        guard infoPanel.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animatesInfo ? 0.15 : 0
            infoPanel.animator().alphaValue = 1
        }
    }

    func hideInfo() {
        isInfoShown = false
        updateTagDots(animated: true)
        guard infoPanel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animatesInfo ? 0.15 : 0
            infoPanel.animator().alphaValue = 0
        }
    }

    // MARK: - Точки меток

    private func setUpTagDots() {
        tagDots.orientation = .horizontal
        tagDots.spacing = 6
        tagDots.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        // Подложка — чтобы точки читались и на светлом фоне, и над краем картинки.
        tagDots.wantsLayer = true
        tagDots.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        tagDots.layer?.cornerRadius = 12
        tagDots.alphaValue = 0
        tagDots.translatesAutoresizingMaskIntoConstraints = false
        tagDots.setAccessibilityElement(true)
        tagDots.setAccessibilityRole(.group)
        addSubview(tagDots)
        // Отступ — как у карточки сведений.
        NSLayoutConstraint.activate([
            tagDots.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            tagDots.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }

    /// Метки показанного файла (цвета в порядке меню Finder) и их имена для VoiceOver. Пусто — точек нет.
    /// Смена картинки — сразу, в том же кадре; появление из пустого — мягко.
    func setTagDots(_ colors: [NSColor], names: [String]) {
        let appearing = tagColors.isEmpty && !colors.isEmpty
        tagColors = colors
        tagDots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for color in colors {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 6
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 12), dot.heightAnchor.constraint(equalToConstant: 12),
            ])
            tagDots.addArrangedSubview(dot)
        }
        tagDots.setAccessibilityLabel(names.joined(separator: ", "))
        // Без меток — не элемент: невидимая пустая группа сбивала бы VoiceOver.
        tagDots.setAccessibilityElement(!colors.isEmpty)
        updateTagDots(animated: appearing)
    }

    /// Зажата стрелка — точки прячутся (сразу); отпустили — показ.
    func holdTagDots(_ held: Bool) {
        guard held != tagDotsHeld else { return }
        tagDotsHeld = held
        updateTagDots(animated: !held)
    }

    /// Видны, только если меток есть, стрелка не зажата и не открыта карточка сведений (в ней строка «Метки»).
    private func updateTagDots(animated: Bool) {
        let visible: CGFloat = !tagColors.isEmpty && !tagDotsHeld && !isInfoShown ? 1 : 0
        guard tagDots.alphaValue != visible else { return }
        // Прятать — всегда сразу: неверные точки не должны висеть ни кадра.
        guard animated, visible == 1, animatesInfo else {
            tagDots.alphaValue = visible
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            tagDots.animator().alphaValue = visible
        }
    }

    // MARK: - Клавиатура (режим «свой список»; в режиме «следовать» клавиши разбирает перехват)

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyPressed?((123...126).contains(event.keyCode))
        if event.isARepeat, (123...126).contains(event.keyCode) { onArrowHeld?() }
        guard let command = ViewerCommand(event: event) else { return }
        // Автоповтор зажатого Пробела после закрытия ушёл бы в следующее окно, зажатая цифра щёлкала бы меткой.
        if command == .close, event.isARepeat { return }
        if case .tag = command, event.isARepeat { return }
        // Пробел закрывает, только если это включено в настройках; Esc закрывает всегда.
        if command == .close, event.keyCode == 49, !spaceClosesViewer { return }
        handle(command)
    }

    // ⌘-сочетания приходят сюда раньше, чем в главное меню. Пока открыт просмотр, поглощаем их все:
    // иначе стандартное меню SwiftUI откроет по ⌘, пустые настройки под оверлеем, а ⌘H спрячет приложение.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        // Сочетание с `⌘` — не удержание `⌘` для Live Text (и не `⌥` для сведений).
        onKeyPressed?(false)
        if let command = ViewerCommand(event: event) {
            // Зажатое сочетание: поворот крутил бы каруселью, копирование и открытие — повторялись бы.
            let once: [ViewerCommand] = [.rotateClockwise, .rotateCounterclockwise, .copy, .openInApp, .lookUp, .share]
            if event.isARepeat, once.contains(command) { return true }
            handle(command)
        }
        return true
    }

    private func handle(_ command: ViewerCommand) {
        switch command {
        case .zoomIn, .zoomOut, .zoomFit:
            perform(command)
        default:
            onCommand?(command)
        }
    }
}

extension ViewerView: ImageAnalysisOverlayViewDelegate {
    // Оверлей лежит ровно на картинке.
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func overlayView(
        _ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
        forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes
    ) -> Bool {
        isLiveMode
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, highlightSelectedItemsDidChange highlightSelectedItems: Bool) {
        onLiveTextLatch?(highlightSelectedItems)
    }

    // Клавиши — просмотру (стрелки, Esc, ⌘C): оверлей после щелчка по тексту мог бы забирать их себе.
    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldHandleKeyDownEvent event: NSEvent) -> Bool {
        false
    }
}
