import AppKit

/// Затемнённый фон и изображение по центру. Большие изображения вписываются в экран,
/// маленькие показываются в естественном размере и не растягиваются.
final class ViewerView: NSView {
    var onCommand: ((ViewerCommand) -> Void)?

    private let imageLayer = CALayer()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// Индикатор ожидания: Finder пропускает документы между картинками или картинка долго декодируется.
    private let spinnerBackground = NSView()
    private let spinner = NSProgressIndicator()
    private var imageSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor

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
    }

    var isSpinning: Bool { !spinnerBackground.isHidden }

    func setSpinning(_ spinning: Bool) {
        guard spinning != isSpinning else { return }
        spinnerBackground.isHidden = !spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    func show(_ loaded: LoadedImage) {
        imageLayer.contents = loaded.image
        imageSize = loaded.pointSize
        messageLabel.isHidden = true
        needsLayout = true
    }

    func showError(fileName: String) {
        imageLayer.contents = nil
        imageSize = .zero
        messageLabel.stringValue = "\(fileName)\nНе удалось открыть"
        messageLabel.isHidden = false
        needsLayout = true
    }

    func clear() {
        imageLayer.contents = nil
        imageSize = .zero
        messageLabel.isHidden = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = Self.fittedRect(imageSize: imageSize, in: bounds)
        CATransaction.commit()
    }

    /// Прямоугольник изображения: по центру, уменьшен до границ, но никогда не увеличен.
    nonisolated static func fittedRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(1, bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = (imageSize.width * scale).rounded()
        let height = (imageSize.height * scale).rounded()
        return CGRect(
            x: bounds.minX + ((bounds.width - width) / 2).rounded(),
            y: bounds.minY + ((bounds.height - height) / 2).rounded(),
            width: width,
            height: height
        )
    }

    // MARK: - Клавиатура

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let command = ViewerCommand(event: event) else { return }
        // Автоповтор зажатого Пробела после закрытия ушёл бы в следующее окно.
        if command == .close, event.isARepeat { return }
        onCommand?(command)
    }

    // ⌘-сочетания приходят сюда раньше, чем в главное меню. Пока открыт просмотр, поглощаем их все:
    // иначе стандартное меню SwiftUI откроет по ⌘, пустые настройки под оверлеем, а ⌘H спрячет приложение.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if let command = ViewerCommand(event: event) {
            onCommand?(command)
        }
        return true
    }
}
