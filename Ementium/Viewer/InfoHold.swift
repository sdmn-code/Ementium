import AppKit
import CoreGraphics

/// Модификаторы, важные для показа сведений о снимке. Caps Lock и Fn не в счёт:
/// у стрелок система сама ставит флаг Fn.
nonisolated struct HoldModifiers: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let option = HoldModifiers(rawValue: 1 << 0)
    static let command = HoldModifiers(rawValue: 1 << 1)
    static let control = HoldModifiers(rawValue: 1 << 2)
    static let shift = HoldModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(_ flags: CGEventFlags) {
        var result: HoldModifiers = []
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        self = result
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var result: HoldModifiers = []
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}

/// Ввод для сведений о снимке в режиме «следовать»: клавиатура там у Finder, и модификаторы
/// с нажатиями видит только перехват.
nonisolated enum ViewerInput: Equatable, Sendable {
    case modifiers(HoldModifiers)
    case keyPressed(isArrow: Bool)
    /// Стрелка зажата (автоповтор) — точки меток прячутся до остановки.
    case arrowHeld
}

/// Сведения о снимке — пока удерживается `⌥`. Чистый автомат; таймер и показ — у вызывающего.
///
/// - Только `⌥`, держим 0,5 с — показ. Отпустили — скрыть.
/// - За эти 0,5 с нажата любая клавиша или добавлен другой модификатор — показ отменяется до отпускания `⌥`
///   (на `⌥⌘Пробел` и других сочетаниях ничего не мелькнёт).
/// - Сведения показаны: стрелки листают, сведения остаются; любая другая клавиша или модификатор — скрыть.
nonisolated struct InfoHoldTracker: Equatable {
    enum Output: Equatable {
        case startTimer
        case cancelTimer
        case show
        case hide
    }

    enum State: Equatable {
        case idle
        /// `⌥` нажат, ждём 0,5 с.
        case arming
        case shown
        /// `⌥` ещё держат, но это было сочетание — до отпускания не показываем.
        case cancelled
    }

    static let delay = Duration.milliseconds(500)

    private(set) var state = State.idle

    mutating func modifiersChanged(_ modifiers: HoldModifiers) -> [Output] {
        let optionOnly = modifiers == .option
        let optionHeld = modifiers.contains(.option)
        switch state {
        case .idle:
            if optionOnly {
                state = .arming
                return [.startTimer]
            }
            // `⌥` вместе с другим модификатором — сочетание, а не просьба показать сведения.
            if optionHeld { state = .cancelled }
            return []
        case .arming:
            if optionOnly { return [] }
            state = optionHeld ? .cancelled : .idle
            return [.cancelTimer]
        case .shown:
            if optionOnly { return [] }
            state = optionHeld ? .cancelled : .idle
            return [.hide]
        case .cancelled:
            if !optionHeld { state = .idle }
            return []
        }
    }

    mutating func keyPressed(isArrow: Bool) -> [Output] {
        switch state {
        case .arming:
            state = .cancelled
            return [.cancelTimer]
        case .shown:
            // Держишь `⌥` и листаешь — сведения остаются и обновляются.
            if isArrow { return [] }
            state = .cancelled
            return [.hide]
        case .idle, .cancelled:
            return []
        }
    }

    mutating func timerFired() -> [Output] {
        guard state == .arming else { return [] }
        state = .shown
        return [.show]
    }

    /// Просмотр закрылся.
    mutating func reset() -> [Output] {
        let outputs: [Output] = switch state {
        case .shown: [.hide]
        case .arming: [.cancelTimer]
        case .idle, .cancelled: []
        }
        state = .idle
        return outputs
    }
}
