import AppKit

/// Действие, которое клавиша вызывает в окне просмотра.
nonisolated enum ViewerCommand: Equatable {
    case next
    case previous
    case close
    case quit
    case zoomIn
    case zoomOut
    case zoomFit
    case openSettings

    private enum KeyCode {
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let qwertyQ: UInt16 = 12
        static let equal: UInt16 = 24       // «=» и «+» (с ⇧)
        static let minus: UInt16 = 27
        static let zero: UInt16 = 29
        static let keypadPlus: UInt16 = 69
        static let keypadMinus: UInt16 = 78
        static let keypadZero: UInt16 = 82
        static let comma: UInt16 = 43       // «,» (в русской раскладке «б» — та же клавиша)
    }

    /// Стрелки, Esc и Пробел распознаются по физическому коду — он одинаков во всех раскладках.
    /// ⌘Q — по символу «q», чтобы работал и на AZERTY/Dvorak; физический код — запасной вариант
    /// для нелатинских раскладок, где символ не «q» (например, «й»).
    init?(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        // Масштаб: «+», «-», «0» — с ⌘ и без (как в Просмотре), на основной клавиатуре и цифровом блоке.
        // «+» на основной клавиатуре — это ⇧= , поэтому ⇧ тоже допускается.
        if flags.isSubset(of: [.command, .shift]) {
            switch keyCode {
            case KeyCode.equal, KeyCode.keypadPlus:
                self = .zoomIn
                return
            case KeyCode.minus, KeyCode.keypadMinus:
                self = .zoomOut
                return
            case KeyCode.zero, KeyCode.keypadZero:
                self = .zoomFit
                return
            default:
                break
            }
        }
        if flags == .command, keyCode == KeyCode.comma {
            self = .openSettings
            return
        }
        if flags == .command {
            let character = characters?.lowercased()
            let isLatinLetter = character?.first.map { $0.isASCII && $0.isLetter } ?? false
            if character == "q" || (!isLatinLetter && keyCode == KeyCode.qwertyQ) {
                self = .quit
                return
            }
            return nil
        }
        switch (keyCode, flags) {
        case (KeyCode.right, []), (KeyCode.down, []): self = .next
        case (KeyCode.left, []), (KeyCode.up, []): self = .previous
        case (KeyCode.escape, []), (KeyCode.space, []): self = .close
        default: return nil
        }
    }

    init?(event: NSEvent) {
        self.init(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
    }
}
