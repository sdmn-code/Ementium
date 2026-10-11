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
    private let thread = RunLoopThread(name: "Ementium.KeyInterceptor")
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "interceptor")

    // Только на потоке перехвата.
    private var tap: CFMachPort?
    private var swallowed = SwallowedKeys()

    init(
        state: InterceptionState,
        onAbsorb: @escaping @Sendable (_ urls: [URL]) -> Void,
        onViewerKey: @escaping @Sendable (ViewerKeyAction) -> Void
    ) {
        self.state = state
        self.onAbsorb = onAbsorb
        self.onViewerKey = onViewerKey
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

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleViewerKey(_ event: CGEvent, keyCode: UInt16, isRepeat: Bool) -> Unmanaged<CGEvent>? {
        let action = InterceptionPolicy.followingAction(
            keyCode: keyCode, characters: characters(of: event), flags: event.flags, isRepeat: isRepeat,
            systemShortcuts: state.snapshot.systemShortcuts
        )
        switch action {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .passAndClose:
            onViewerKey(.close)
            return Unmanaged.passUnretained(event)
        case .swallow:
            swallowed.swallow(keyCode)
            return nil
        case .step, .close, .quit:
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
