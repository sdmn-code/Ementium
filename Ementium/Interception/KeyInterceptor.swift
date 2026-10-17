import AppKit
import CoreGraphics
import Foundation
import os

/// Глобальный перехват клавиатуры через `CGEventTap`: Пробел в Finder открывает просмотр, а пока
/// просмотр следует за Finder, перехват разбирает все нажатия (Finder за оверлеем остаётся активным).
///
/// Callback должен отвечать мгновенно: если он задержится, система отключит tap
/// (`tapDisabledByTimeout`). Поэтому внутри — только чтение `InterceptionState` под замком
/// и чистые решения `InterceptionPolicy`, без единого обращения к Finder.
nonisolated final class KeyInterceptor: @unchecked Sendable {
    /// Метка наших собственных событий (стрелки для Finder) — их перехват пропускает не глядя.
    static let syntheticEventMarker: Int64 = 0x454D_4E54  // «EMNT»

    private let state: InterceptionState
    /// Пробел в Finder: открыть просмотр с этими файлами.
    private let onAbsorb: @Sendable (_ urls: [URL]) -> Void
    /// Клавиша при открытом просмотре в режиме «следовать за Finder».
    private let onViewerKey: @Sendable (ViewerKeyAction) -> Void
    /// Жест масштаба при открытом просмотре в режиме «следовать за Finder».
    private let onViewerGesture: @Sendable (ViewerGesture) -> Void
    /// Модификаторы и нажатия в режиме «следовать» — для сведений о снимке по `⌥`.
    private let onViewerInput: @Sendable (ViewerInput) -> Void

    /// Все жесты трекпада приходят в перехват одним системным типом 29 («жест»); какой это жест —
    /// масштаб, двойное касание, сырые касания — видно только после преобразования в `NSEvent`
    /// (выяснено диагностикой: типы AppKit 30 и 32 на системном уровне не встречаются).
    private static let gestureEventType: UInt32 = 29
    private let thread = RunLoopThread(name: "Ementium.KeyInterceptor")
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "interceptor")

    // Только на потоке перехвата.
    private var tap: CFMachPort?
    private var swallowed = SwallowedKeys()

    init(
        state: InterceptionState,
        onAbsorb: @escaping @Sendable (_ urls: [URL]) -> Void,
        onViewerKey: @escaping @Sendable (ViewerKeyAction) -> Void,
        onViewerGesture: @escaping @Sendable (ViewerGesture) -> Void,
        onViewerInput: @escaping @Sendable (ViewerInput) -> Void
    ) {
        self.state = state
        self.onAbsorb = onAbsorb
        self.onViewerKey = onViewerKey
        self.onViewerGesture = onViewerGesture
        self.onViewerInput = onViewerInput
    }

    /// Создаёт tap. Возвращает `false`, если система не дала доступ (нет разрешения).
    func start() -> Bool {
        let result = OSAllocatedUnfairLock(initialState: false)
        let done = DispatchSemaphore(value: 0)
        thread.perform {
            result.withLock { $0 = self.createTap() }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 }
    }

    private func createTap() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << Self.gestureEventType)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Не удалось создать event tap — нет разрешения?")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else { return false }
        thread.add(source)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        log.info("Перехват Пробела запущен")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            log.error("Tap отключён системой (\(type.rawValue)), включаю снова")
            // Пока tap был выключен, отпускания могли пройти мимо.
            swallowed.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp:
            // Наши собственные стрелки для Finder.
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyUp {
                return swallowed.released(keyCode) ? nil : Unmanaged.passUnretained(event)
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let snapshot = state.snapshot
            // Разбирать все клавиши можно, только пока Finder действительно активен: иначе после ⌘Tab
            // перехват глотал бы ввод в другом приложении.
            if snapshot.isViewerVisible, snapshot.isFollowingFinder, snapshot.isFinderFrontmost {
                return handleViewerKey(event, keyCode: keyCode, isRepeat: isRepeat)
            }
            if isRepeat, swallowed.isHeld(keyCode) {
                return nil
            }
            if !isRepeat { swallowed.pressed(keyCode) }
            switch InterceptionPolicy.decide(keyCode: keyCode, flags: event.flags, isRepeat: isRepeat, state: snapshot) {
            case .absorb(let urls):
                // Автоповтор и отпускание этого Пробела тоже не должны дойти до Finder,
                // иначе тот откроет Quick Look поверх просмотра.
                swallowed.swallow(keyCode)
                onAbsorb(urls)
                return nil
            case .pass:
                return Unmanaged.passUnretained(event)
            }

        case .flagsChanged:
            // Модификаторы всегда пропускаем: проглоченное изменение «залепит» модификатор у системы.
            // Просмотру — копия, и только пока клавиатуру разбираем мы (как и с остальными клавишами).
            let snapshot = state.snapshot
            if snapshot.isViewerVisible, snapshot.isFollowingFinder, snapshot.isFinderFrontmost {
                onViewerInput(.modifiers(HoldModifiers(event.flags)))
            }
            return Unmanaged.passUnretained(event)

        default:
            if type.rawValue == Self.gestureEventType {
                return handleGesture(event)
            }
            return Unmanaged.passUnretained(event)
        }
    }

    /// Жест масштаба при открытом просмотре — просмотру, а не активному приложению (обычно Finder:
    /// иначе он за оверлеем ещё и поменял бы размер значков).
    private func handleGesture(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Жесты идут постоянно (любое касание трекпада) — разбираем только при открытом просмотре.
        // В любом режиме: и при двух выделенных картинках активен Finder, и жест ушёл бы ему, а не панели.
        // Поглощаем, чтобы при активном Ementium (`open -a`) жест не пришёл ещё и панели напрямую.
        guard state.snapshot.isViewerVisible, let gesture = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        switch gesture.type {
        case .magnify:
            if gesture.magnification != 0 { onViewerGesture(.magnify(gesture.magnification)) }
            return nil
        case .smartMagnify:
            onViewerGesture(.smartMagnify)
            return nil
        default:
            // Прокрутка, нажатия, сырые касания — дальше как обычно (прокрутку получит панель под курсором).
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleViewerKey(_ event: CGEvent, keyCode: UInt16, isRepeat: Bool) -> Unmanaged<CGEvent>? {
        let snapshot = state.snapshot
        onViewerInput(.keyPressed(isArrow: ArrowKey(rawValue: keyCode) != nil))
        let action = InterceptionPolicy.followingAction(
            keyCode: keyCode, characters: characters(of: event), flags: event.flags, isRepeat: isRepeat,
            systemShortcuts: snapshot.systemShortcuts, spaceClosesViewer: snapshot.spaceClosesViewer,
            trashEnabled: snapshot.trashEnabled
        )
        switch action {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .passAndClose:
            // Не `.close`: тот сначала закрывает карточку или окно ссылки, а просмотр остался бы — и Spotlight
            // открылся бы под ним.
            onViewerKey(.passAndClose)
            return Unmanaged.passUnretained(event)
        case .swallow:
            swallowed.swallow(keyCode)
            return nil
        case .step, .close, .quit, .zoom, .openSettings, .trash, .trashOff, .undoTrash, .edge, .rotate, .copy, .openInApp,
             .lookUp, .share:
            swallowed.swallow(keyCode)
            onViewerKey(action)
            return nil
        }
    }

    /// Символ клавиши — нужен, чтобы ⌘Q распознавался в любой раскладке.
    private func characters(of event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return length > 0 ? String(utf16CodeUnits: buffer, count: length) : nil
    }
}
