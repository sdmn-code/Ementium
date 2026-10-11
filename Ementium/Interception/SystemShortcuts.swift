import CoreGraphics
import Foundation

/// Системное сочетание клавиш, которое во время просмотра нужно пропустить, а не проглотить.
nonisolated struct SystemShortcut: Sendable, Equatable {
    let keyCode: UInt16
    /// Только ⌘ ⌥ ⌃ ⇧ — остальные флаги при сравнении не учитываются.
    let modifiers: CGEventFlags
    /// `.pass` — просмотр остаётся открытым (смена языка, скриншот); `.passAndClose` — система уводит
    /// из Finder (Spotlight, Mission Control, рабочие столы).
    let action: ViewerKeyAction
}

/// Системные сочетания macOS с учётом того, как их переназначил пользователь.
///
/// Берутся из настроек `com.apple.symbolichotkeys` (Системные настройки → Клавиатура → Сочетания клавиш):
/// там лежат и стандартные, и переназначенные сочетания. Если запись для действия есть, но без клавиш,
/// значит, используется стандартное сочетание — оно берётся из `defaults`.
nonisolated enum SystemShortcuts {
    static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// Действия, при которых просмотр остаётся открытым.
    private static let stayingIDs: Set<Int> = [
        60, 61,                  // предыдущий / следующий источник ввода
        28, 29, 30, 31, 184,     // скриншоты экрана, области, панель скриншотов
    ]

    /// Стандартные сочетания для действий, у которых в настройках нет своих клавиш.
    /// Коды: ← 123, → 124, ↓ 125, ↑ 126, Пробел 49, цифры 1…9, 3/4/5 — 20/21/23, F11 — 103.
    private static let defaults: [Int: (keyCode: UInt16, modifiers: CGEventFlags)] = [
        32: (126, .maskControl),                  // Mission Control
        33: (125, .maskControl),                  // окна приложения
        36: (103, []),                            // показать рабочий стол (F11)
        60: (49, .maskControl),                   // предыдущий источник ввода
        61: (49, [.maskControl, .maskAlternate]), // следующий источник ввода
        64: (49, .maskCommand),                   // Spotlight
        79: (123, .maskControl),                  // рабочий стол слева
        81: (124, .maskControl),                  // рабочий стол справа
        118: (18, .maskControl), 119: (19, .maskControl), 120: (20, .maskControl),
        121: (21, .maskControl), 122: (23, .maskControl), 123: (22, .maskControl),
        124: (26, .maskControl), 125: (28, .maskControl), 126: (25, .maskControl),  // рабочие столы 1…9
        28: (20, [.maskCommand, .maskShift]),
        29: (20, [.maskControl, .maskCommand, .maskShift]),
        30: (21, [.maskCommand, .maskShift]),
        31: (21, [.maskControl, .maskCommand, .maskShift]),
        184: (23, [.maskCommand, .maskShift]),
    ]

    /// Читает текущие настройки пользователя. Дёшево — можно звать при каждом открытии просмотра.
    static func load() -> [SystemShortcut] {
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        return parse(value as? [String: Any] ?? [:])
    }

    /// Разбирает словарь `AppleSymbolicHotKeys`: `{ "64": { enabled, value: { parameters: (символ, код, модификаторы) } } }`.
    /// Модификаторы — в формате `NSEvent.ModifierFlags`, биты совпадают с `CGEventFlags`.
    static func parse(_ hotKeys: [String: Any]) -> [SystemShortcut] {
        var shortcuts: [SystemShortcut] = []
        var seen = Set<Int>()
        for (key, raw) in hotKeys {
            guard let id = Int(key), let entry = raw as? [String: Any] else { continue }
            seen.insert(id)
            guard (entry["enabled"] as? NSNumber)?.boolValue == true else { continue }
            let action: ViewerKeyAction = stayingIDs.contains(id) ? .pass : .passAndClose
            if let value = entry["value"] as? [String: Any],
               let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3,
               parameters[1].intValue != 0xFFFF {
                let modifiers = CGEventFlags(rawValue: UInt64(parameters[2].uintValue)).intersection(modifierMask)
                shortcuts.append(SystemShortcut(keyCode: UInt16(parameters[1].intValue), modifiers: modifiers, action: action))
            } else if let standard = defaults[id] {
                shortcuts.append(SystemShortcut(keyCode: standard.keyCode, modifiers: standard.modifiers, action: action))
            }
        }
        // Действия, которых нет в настройках, работают со стандартными сочетаниями (пользователь их не трогал).
        for (id, standard) in defaults where !seen.contains(id) {
            let action: ViewerKeyAction = stayingIDs.contains(id) ? .pass : .passAndClose
            shortcuts.append(SystemShortcut(keyCode: standard.keyCode, modifiers: standard.modifiers, action: action))
        }
        // Смену языка и скриншоты проверяем первыми: при совпадении сочетаний просмотр лучше не закрывать.
        return shortcuts.sorted { $0.action == .pass && $1.action != .pass }
    }
}
