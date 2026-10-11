import CoreGraphics
import Foundation
import os

/// Глобальный перехват Пробела через `CGEventTap`.
///
/// Callback должен отвечать мгновенно: если он задержится, система отключит tap
/// (`tapDisabledByTimeout`). Поэтому внутри — только чтение `InterceptionState` под замком
/// и чистое решение `InterceptionPolicy`, без единого обращения к Finder.
nonisolated final class KeyInterceptor: @unchecked Sendable {
    private let state: InterceptionState
    private let onAbsorb: @Sendable ([URL]) -> Void
    private let thread = RunLoopThread(name: "Ementium.KeyInterceptor")
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "interceptor")

    // Только на потоке перехвата.
    private var tap: CFMachPort?
    /// Пробел, который мы поглотили, ещё не отпущен: его автоповтор и отпускание тоже не должны
    /// дойти до Finder, иначе тот откроет Quick Look поверх просмотра.
    private var isSwallowingSpace = false

    init(state: InterceptionState, onAbsorb: @escaping @Sendable ([URL]) -> Void) {
        self.state = state
        self.onAbsorb = onAbsorb
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if keyCode == InterceptionPolicy.spaceKeyCode, isSwallowingSpace {
                if isRepeat { return nil }
                isSwallowingSpace = false  // отпускание потерялось — это новое нажатие
            }
            switch InterceptionPolicy.decide(keyCode: keyCode, flags: event.flags, isRepeat: isRepeat, state: state.snapshot) {
            case .absorb(let urls):
                isSwallowingSpace = true
                onAbsorb(urls)
                return nil
            case .pass:
                return Unmanaged.passUnretained(event)
            }

        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == InterceptionPolicy.spaceKeyCode, isSwallowingSpace {
                isSwallowingSpace = false
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
