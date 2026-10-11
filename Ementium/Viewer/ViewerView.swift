import AppKit

/// Затемнённый фон и изображение. Большие изображения вписываются в экран, маленькие показываются
/// в естественном размере и не растягиваются. Масштаб — клавишами и жестами трекпада, сдвиг увеличенной
/// картинки — перетаскиванием и прокруткой. Геометрия — в `ZoomModel`.
final class ViewerView: NSView {
    var onCommand: ((ViewerCommand) -> Void)?
    /// Масштаб изменился — контроллер решает, не пора ли декодировать картинку в большем разрешении.
    var onZoomChanged: ((ZoomModel) -> Void)?

    private let imageLayer = CALayer()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// Индикатор ожидания: Finder пропускает документы между картинками или картинка долго декодируется.
    private let spinnerBackground = NSView()
    private let spinner = NSProgressIndicator()
    /// Плашка масштаба: «200 %» или «Вписать» внизу экрана на секунду.
    private let zoomBadge = NSView()
    private let zoomLabel = NSTextField(labelWithString: "")
    private var zoomBadgeHide: Task<Void, Never>?

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
        if var current = zoom {
            current.setFitOptions(fraction: fitFraction, upscalesSmallImages: upscalesSmallImages)
            zoom = current
            applyZoom(animated: false)
        }
    }

    /// Новая картинка. `keepScale` — сохранить масштаб предыдущей (иначе «вписать»).
    func show(_ loaded: LoadedImage, keepScale: Bool) {
        if var current = zoom {
            current.replaceImage(size: loaded.pointSize, keepScale: keepScale)
            zoom = current
        } else {
            zoom = ZoomModel(
                imageSize: loaded.pointSize, viewSize: bounds.size,
                fitFraction: fitFraction, upscalesSmallImages: upscalesSmallImages
            )
        }
        imageLayer.contents = loaded.image
        messageLabel.isHidden = true
        applyZoom(animated: false)
    }

    /// Та же картинка в большем разрешении — подменяем пиксели, не трогая масштаб и сдвиг.
    func upgrade(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    func showError(fileName: String) {
        imageLayer.contents = nil
        zoom = nil
        messageLabel.stringValue = "\(fileName)\nНе удалось открыть"
        messageLabel.isHidden = false
        applyZoom(animated: false)
    }

    func clear() {
        imageLayer.contents = nil
        zoom = nil
        messageLabel.isHidden = true
        isDragging = false
        zoomBadge.alphaValue = 0
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

    /// Прямоугольник изображения при «вписать»: по центру, уменьшен до границ, но никогда не увеличен.
    nonisolated static func fittedRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        ZoomModel(imageSize: imageSize, viewSize: bounds.size).imageRect.offsetBy(dx: bounds.minX, dy: bounds.minY)
    }

    private func applyZoom(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(Self.zoomAnimationDuration) }
        imageLayer.frame = zoom?.imageRect ?? .zero
        CATransaction.commit()
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

    private func commit(_ updated: ZoomModel, animated: Bool) {
        let scaleChanged = updated.scale != zoom?.scale
        zoom = updated
        applyZoom(animated: animated)
        if scaleChanged {
            showZoomBadge(updated.label)
            onZoomChanged?(updated)
        }
    }

    private func showZoomBadge(_ text: String) {
        zoomLabel.stringValue = text
        zoomBadge.alphaValue = 1
        zoomBadgeHide?.cancel()
        zoomBadgeHide = Task {
            try? await Task.sleep(for: .seconds(1))
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
        guard var current = zoom, current.canPan else { return }
        // Колёсико мыши даёт строки, трекпад — точные пункты.
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        current.pan(by: CGVector(dx: event.scrollingDeltaX * factor, dy: -event.scrollingDeltaY * factor))
        commit(current, animated: false)
    }

    // Окно просмотра в режиме «следовать за Finder» неактивно — первый же клик должен работать.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
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
        if isDragging {
            NSCursor.closedHand.set()
        } else if zoom?.canPan == true {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Клавиатура (режим «свой список»; в режиме «следовать» клавиши разбирает перехват)

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let command = ViewerCommand(event: event) else { return }
        // Автоповтор зажатого Пробела после закрытия ушёл бы в следующее окно.
        if command == .close, event.isARepeat { return }
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
        if let command = ViewerCommand(event: event) {
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
