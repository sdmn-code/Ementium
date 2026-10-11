import AppKit

/// Действие, которое клавиша вызывает в окне просмотра.
nonisolated enum ViewerCommand: Equatable {
    case next
    case previous
    case close
    case quit

    private enum KeyCode {
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let qwertyQ: UInt16 = 12
    }

    /// Стрелки, Esc и Пробел распознаются по физическому коду — он одинаков во всех раскладках.
    /// ⌘Q — по символу «q», чтобы работал и на AZERTY/Dvorak; физический код — запасной вариант
    /// для нелатинских раскладок, где символ не «q» (например, «й»).
    init?(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
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
