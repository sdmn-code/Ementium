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
    /// `⌘⌫` — в Корзину (только в режиме «следовать» и при включённой настройке).
    case trash
    /// `⌘Z` — вернуть удалённое в этом сеансе.
    case undo
    /// `Home` / `End` (на MacBook — `fn ←` / `fn →`): первая / последняя картинка.
    case first
    case last
    /// `⌘→` / `⌘←` (и `⌘R` / `⌘L`, как в Просмотре): повернуть показ на 90°, файл не меняется.
    case rotateClockwise
    case rotateCounterclockwise
    /// `⌘C` — файл в буфер обмена, как в Finder.
    case copy
    /// `⌘O` — открыть в приложении по умолчанию.
    case openInApp

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
        static let delete: UInt16 = 51      // ⌫
        static let qwertyZ: UInt16 = 6
        static let qwertyR: UInt16 = 15
        static let qwertyL: UInt16 = 37
        static let qwertyC: UInt16 = 8
        static let qwertyO: UInt16 = 31
        static let home: UInt16 = 115       // и fn ←
        static let end: UInt16 = 119        // и fn →
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
        if flags == .command, keyCode == KeyCode.delete {
            self = .trash
            return
        }
        if flags == .command {
            switch keyCode {
            case KeyCode.right: self = .rotateClockwise; return
            case KeyCode.left: self = .rotateCounterclockwise; return
            default: break
            }
            let character = characters?.lowercased()
            let isLatinLetter = character?.first.map { $0.isASCII && $0.isLetter } ?? false
            // Буквы — по символу, в нелатинской раскладке — по физическому коду (как ⌘Q).
            func letter(_ latin: String, _ code: UInt16) -> Bool {
                character == latin || (!isLatinLetter && keyCode == code)
            }
            if letter("r", KeyCode.qwertyR) { self = .rotateClockwise; return }
            if letter("l", KeyCode.qwertyL) { self = .rotateCounterclockwise; return }
            if letter("c", KeyCode.qwertyC) { self = .copy; return }
            if letter("o", KeyCode.qwertyO) { self = .openInApp; return }
            // ⌘Z — так же, как ⌘Q: по символу, а в нелатинской раскладке — по физическому коду.
            if character == "z" || (!isLatinLetter && keyCode == KeyCode.qwertyZ) {
                self = .undo
                return
            }
            if character == "q" || (!isLatinLetter && keyCode == KeyCode.qwertyQ) {
                self = .quit
                return
            }
            return nil
        }
        switch (keyCode, flags) {
        // С `⌥` — тоже: держишь `⌥` (сведения о снимке) и листаешь.
        case (KeyCode.right, []), (KeyCode.down, []), (KeyCode.right, [.option]), (KeyCode.down, [.option]): self = .next
        case (KeyCode.left, []), (KeyCode.up, []), (KeyCode.left, [.option]), (KeyCode.up, [.option]): self = .previous
        case (KeyCode.escape, []), (KeyCode.space, []): self = .close
        case (KeyCode.home, []): self = .first
        case (KeyCode.end, []): self = .last
        default: return nil
        }
    }

    init?(event: NSEvent) {
        self.init(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
    }
}
