import CoreImage
import CoreVideo
import ImageIO
import IOSurface
import VisionKit

/// Режим Live Text — пока удерживается `⌘` или пока он зафиксирован. Чистый автомат; таймер, распознавание
/// и показ — у вызывающего. Устроен как сведения по `⌥` (`InfoHoldTracker`):
///
/// - Только `⌘`, держим 0,3 с — режим. Отпустили — выйти, если режим не зафиксирован.
/// - За эти 0,3 с нажата клавиша (`⌘C`, `⌘→`, `⌘⌫`…) или добавлен модификатор — режим не включается до отпускания
///   `⌘`: сочетания не мигают кнопками и не запускают распознавание впустую.
/// - В режиме клавиши (`⌘C`, `⌘L`, `⌘S`) его не снимают.
/// - Зафиксировать режим может кнопка Live Text (подсветить весь текст, как в Quick Look) или `⌘L`: `⌘` можно
///   отпустить. Снимают: новое нажатие `⌘`, та же кнопка, смена картинки, закрытие просмотра.
nonisolated struct LiveTextHoldTracker: Equatable {
    enum Output: Equatable {
        case startTimer
        case cancelTimer
        case enter
        case exit
    }

    enum State: Equatable {
        case idle
        /// `⌘` нажат, ждём 0,3 с.
        case arming
        case active
        /// `⌘` ещё держат, но это было сочетание — до отпускания не включаемся.
        case cancelled
    }

    static let delay = Duration.milliseconds(300)

    private(set) var state = State.idle
    private(set) var isLatched = false
    /// `⌘` держали при прошлом изменении модификаторов — чтобы отличить новое нажатие от того, которым включали.
    private var wasCommandHeld = false

    var isActive: Bool { state == .active }

    mutating func modifiersChanged(_ modifiers: HoldModifiers) -> [Output] {
        let commandOnly = modifiers == .command
        let commandHeld = modifiers.contains(.command)
        defer { wasCommandHeld = commandHeld }
        switch state {
        case .idle:
            if commandOnly {
                state = .arming
                return [.startTimer]
            }
            // `⌘` вместе с другим модификатором — сочетание, а не просьба включить режим.
            if commandHeld { state = .cancelled }
            return []
        case .arming:
            if commandOnly { return [] }
            state = commandHeld ? .cancelled : .idle
            return [.cancelTimer]
        case .active:
            if isLatched {
                // Зафиксированный режим снимает новое нажатие `⌘`; пока его держат, режим снова не включается.
                guard commandHeld, !wasCommandHeld else { return [] }
                isLatched = false
                state = .cancelled
                return [.exit]
            }
            // Держишь `⌘` (хоть и с `⇧`) — режим держится; отпустили — выход.
            if commandHeld { return [] }
            state = .idle
            return [.exit]
        case .cancelled:
            if !commandHeld { state = .idle }
            return []
        }
    }

    mutating func keyPressed() -> [Output] {
        guard state == .arming else { return [] }
        state = .cancelled
        return [.cancelTimer]
    }

    mutating func timerFired() -> [Output] {
        guard state == .arming else { return [] }
        state = .active
        return [.enter]
    }

    /// Кнопка Live Text: подсветка включена — режим держится и без `⌘`; выключена — как обычно
    /// (`⌘` уже отпущен — выход).
    mutating func setLatched(_ latched: Bool, commandHeld: Bool) -> [Output] {
        guard state == .active else { return [] }
        isLatched = latched
        guard !latched, !commandHeld else { return [] }
        state = .idle
        return [.exit]
    }

    /// `⌘L`: включить режим сразу и зафиксировать — поиску нужны кнопки VisionKit, а `⌘` тут же отпустят.
    mutating func latch() -> [Output] {
        isLatched = true
        switch state {
        case .active:
            return []
        case .arming:
            state = .active
            return [.cancelTimer, .enter]
        case .idle, .cancelled:
            state = .active
            return [.enter]
        }
    }

    /// Смена картинки, закрытие просмотра.
    mutating func reset() -> [Output] {
        let outputs: [Output] = switch state {
        case .active: [.exit]
        case .arming: [.cancelTimer]
        case .idle, .cancelled: []
        }
        state = .idle
        isLatched = false
        return outputs
    }
}

/// «Пузыри» DataDetectors — просмотр ссылки из «пилюли». Его показывает другой процесс
/// (`com.apple.quicklook.ui.helper`), и ни сменой анализа, ни скрытием панели он не закрывается. VisionKit закрывает
/// его, когда перестраивает «пилюли», — вызовом `-[DDActionsManager requestBubbleClosureUnanchorOnFailure:]`; так же
/// закрываем и мы (прототип LiveTextProbe, pilltest). Метод частный: на другой версии macOS его может не быть — тогда
/// ничего не делаем и возвращаем `false`.
enum DataDetectorBubbles {
    @discardableResult
    static func close() -> Bool {
        let shared = NSSelectorFromString("sharedManager")
        let request = NSSelectorFromString("requestBubbleClosureUnanchorOnFailure:")
        guard let managerClass = NSClassFromString("DDActionsManager") as? NSObject.Type,
              managerClass.responds(to: shared),
              let manager = managerClass.perform(shared)?.takeUnretainedValue() as? NSObject,
              manager.responds(to: request),
              // Та же сигнатура, что на macOS 27: ничего не возвращает, один аргумент — BOOL. Иначе вызов вслепую.
              let method = class_getInstanceMethod(type(of: manager), request),
              method_getNumberOfArguments(method) == 3,
              Self.argumentType(method, 2) == "B", Self.returnType(method) == "v" else { return false }
        typealias Request = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(manager.method(for: request), to: Request.self)(manager, request, false)
        return true
    }

    private static func argumentType(_ method: Method, _ index: UInt32) -> String? {
        guard let type = method_copyArgumentType(method, index) else { return nil }
        defer { free(type) }
        return String(cString: type)
    }

    private static func returnType(_ method: Method) -> String {
        let type = method_copyReturnType(method)
        defer { free(type) }
        return String(cString: type)
    }
}

/// Распознавание текста и объектов на показанной картинке — из уже декодированных пикселей (`IOSurface`
/// от сервиса), файл приложение не читает (вариант `analyze` с адресом файла не используем).
final class LiveTextAnalyzer {
    private let analyzer = ImageAnalyzer()

    /// Поворот показа — ориентация для анализатора: рамки текста ложатся на повёрнутую картинку.
    nonisolated static func orientation(quarterTurns: Int) -> CGImagePropertyOrientation {
        [.up, .right, .down, .left][((quarterTurns % 4) + 4) % 4]
    }

    /// `crop` — часть картинки в долях от левого верхнего угла: распознаватель не видит текст мельче доли высоты
    /// картинки, поэтому при увеличении распознаём видимую часть — и мелкий текст в ней становится крупнее.
    func analyze(_ surface: IOSurface, crop: CGRect, quarterTurns: Int) async -> ImageAnalysis? {
        // Конфигурация не Sendable — своя на каждый вызов, а не общая.
        let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])
        let orientation = Self.orientation(quarterTurns: quarterTurns)
        guard crop != CGRect(x: 0, y: 0, width: 1, height: 1) else {
            var buffer: Unmanaged<CVPixelBuffer>?
            guard CVPixelBufferCreateWithIOSurface(nil, surface as IOSurfaceRef, nil, &buffer) == kCVReturnSuccess,
                  let pixels = buffer?.takeRetainedValue() else { return nil }
            return try? await analyzer.analyze(pixels, orientation: orientation, configuration: configuration)
        }
        // У CoreImage начало координат — внизу.
        let width = CGFloat(surface.width), height = CGFloat(surface.height)
        let pixels = CGRect(
            x: crop.minX * width, y: (1 - crop.maxY) * height, width: crop.width * width, height: crop.height * height
        ).integral
        let image = CIImage(ioSurface: surface as IOSurfaceRef).cropped(to: pixels)
            .transformed(by: CGAffineTransform(translationX: -pixels.minX, y: -pixels.minY))
        return try? await analyzer.analyze(image, orientation: orientation, configuration: configuration)
    }
}
