import AppKit
import CoreGraphics
import Foundation

/// Что делать с клавишей, пока открыт просмотр в режиме «следовать за Finder».
/// Finder за оверлеем активен, поэтому до него доходит только то, что мы сами отправим.
nonisolated enum ViewerKeyAction: Equatable {
    /// Шаг листания — стрелка уйдёт в Finder (после перевода под вид окна).
    case step(ArrowKey)
    case close
    case quit
    /// Системное сочетание, не уводящее от просмотра (скриншот, раскладка), — пропустить.
    case pass
    /// Системное сочетание, уводящее из Finder (⌘Tab, Spotlight, Mission Control), — пропустить
    /// и закрыть просмотр: Finder больше не получает наши стрелки, а ввод в Spotlight не должен глотаться.
    case passAndClose
    /// Проглотить: иначе Finder за оверлеем невидимо переименовал бы, удалил или выделил всё.
    case swallow
    /// Масштаб картинки (`+`, `-`, `0`, с ⌘ и без).
    case zoom(ViewerCommand)
    /// `⌘,` — закрыть просмотр и открыть настройки Ementium.
    case openSettings
    /// `⌘⌫` — переместить показанную картинку в Корзину (через Finder).
    case trash
    /// `⌘Z` — вернуть удалённое в этом сеансе.
    case undoTrash
    /// `Home` / `End`: первая / последняя картинка в окне Finder.
    case edge(first: Bool)
    /// `⌘→` / `⌘←` (`⌘R` / `⌘L`): повернуть показ.
    case rotate(clockwise: Bool)
    /// `⌘C` — файл в буфер обмена.
    case copy
    /// `⌘O` — открыть в приложении по умолчанию.
    case openInApp
}

/// Жест трекпада при открытом просмотре. Жесты масштаба macOS отдаёт активному приложению — обычно Finder,
/// а не панели просмотра под курсором (прокрутка и клики при этом доходят до панели), поэтому их
/// забирает перехват и передаёт просмотру — в обоих режимах.
nonisolated enum ViewerGesture: Equatable, Sendable {
    /// Сведение / разведение двух пальцев: приращение масштаба (0,1 = +10 %).
    case magnify(CGFloat)
    /// Двойное касание двумя пальцами.
    case smartMagnify
}

/// Решение «поглотить Пробел или пропустить в Finder». Чистая функция: никаких обращений к системе,
/// поэтому её можно вызывать из callback перехвата и проверять тестами.
nonisolated enum InterceptionPolicy {
    enum Decision: Equatable {
        /// Поглотить и открыть просмотр с этими файлами.
        case absorb([URL])
        /// Пропустить событие без изменений.
        case pass
    }

    static let spaceKeyCode: UInt16 = 49

    private static let blockingModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    static func decide(keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool, state: InterceptionSnapshot) -> Decision {
        guard keyCode == spaceKeyCode,
              flags.intersection(blockingModifiers).isEmpty,
              !isRepeat,
              state.isEnabled,
              state.isFinderFrontmost,
              !state.isViewerVisible,
              !state.isFinderStateStale,
              !state.isTextFieldFocused,
              state.selectionHasImage
        else { return .pass }
        return .absorb(state.selection)
    }

    /// Клавиша при открытом просмотре в режиме «следовать за Finder».
    ///
    /// Системные сочетания пропускаются строго по списку: всё остальное дойдёт до Finder за оверлеем,
    /// а там есть опасное — ⌥⌘⌫ «Удалить немедленно», ⌥⇧⌘⌫ «Очистить Корзину», ⌃⌘N «Новая папка с выбранным».
    /// Список — сочетания из настроек пользователя (`SystemShortcuts`) и несколько неназначаемых.
    static func followingAction(
        keyCode: UInt16, characters: String?, flags: CGEventFlags, isRepeat: Bool,
        systemShortcuts: [SystemShortcut], spaceClosesViewer: Bool = true, trashEnabled: Bool = false
    ) -> ViewerKeyAction {
        let modifiers = flags.intersection(SystemShortcuts.modifierMask)
        if let fixed = fixedSystemShortcut(keyCode: keyCode, modifiers: modifiers) {
            return fixed
        }
        if let shortcut = systemShortcuts.first(where: { $0.keyCode == keyCode && $0.modifiers == modifiers }) {
            return shortcut.action
        }
        // «Модификатор + Пробел» — почти всегда запускалка (Spotlight, Alfred, Raycast) или смена языка,
        // назначенные сторонним приложением. Пропускаем и закрываем: просмотр закроется, и всё будет видно.
        if keyCode == KeyCode.space, !modifiers.isEmpty {
            return .passAndClose
        }
        // С `⌥` — тоже шаг: держишь `⌥` (сведения о снимке) и листаешь. Finder получит обычную стрелку,
        // а не ⌥→ (та раскрыла бы папки в «Списке»): мост шлёт стрелки без модификаторов.
        if modifiers.isEmpty || modifiers == .maskAlternate, let arrow = ArrowKey(rawValue: keyCode) {
            return .step(arrow)
        }
        // F-клавиши — Mission Control, Launchpad, рабочий стол и т. п.
        if modifiers.isEmpty, KeyCode.functionKeys.contains(keyCode) {
            return .passAndClose
        }
        let nsModifiers = NSEvent.ModifierFlags(rawValue: UInt(modifiers.rawValue))
        switch ViewerCommand(keyCode: keyCode, characters: characters, modifiers: nsModifiers) {
        case .close?:
            // Автоповтор Пробела, которым открыли просмотр, не должен его тут же закрыть.
            if isRepeat { return .swallow }
            // Пробел закрывает, только если это включено в настройках; Esc закрывает всегда.
            if keyCode == KeyCode.space, !spaceClosesViewer { return .swallow }
            return .close
        case .openSettings?:
            return .openSettings
        // Без настройки ⌘⌫ и ⌘Z проглатываются, как раньше: Finder за оверлеем не должен ничего удалять невидимо.
        // Автоповтор — никогда: зажатый ⌘⌫ удалял бы папку по картинке, зажатый ⌘Z — возвращал бы всё подряд.
        case .trash?:
            return trashEnabled && !isRepeat ? .trash : .swallow
        case .undo?:
            return trashEnabled && !isRepeat ? .undoTrash : .swallow
        case .first?:
            return .edge(first: true)
        case .last?:
            return .edge(first: false)
        // Автоповтор — нет: зажатое сочетание крутило бы картинку каруселью.
        case .rotateClockwise?:
            return isRepeat ? .swallow : .rotate(clockwise: true)
        case .rotateCounterclockwise?:
            return isRepeat ? .swallow : .rotate(clockwise: false)
        case .copy?:
            return isRepeat ? .swallow : .copy
        case .openInApp?:
            return isRepeat ? .swallow : .openInApp
        case .quit?:
            return .quit
        case let zoom? where [.zoomIn, .zoomOut, .zoomFit].contains(zoom):
            return .zoom(zoom)
        default:
            return .swallow
        }
    }

    private enum KeyCode {
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let grave: UInt16 = 50
        static let escape: UInt16 = 53
        static let q: UInt16 = 12
        static let functionKeys: Set<UInt16> = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,  // F1–F12
            105, 107, 113, 106, 64, 79, 80, 90,                      // F13–F20
        ]
    }

    /// Сочетания, которых нет в настройках клавиатуры: переключатель приложений, переход между окнами,
    /// принудительное завершение, блокировка экрана.
    private static func fixedSystemShortcut(keyCode: UInt16, modifiers: CGEventFlags) -> ViewerKeyAction? {
        let command: CGEventFlags = .maskCommand
        let commandShift: CGEventFlags = [.maskCommand, .maskShift]
        switch (keyCode, modifiers) {
        case (KeyCode.tab, command), (KeyCode.tab, commandShift),
             (KeyCode.grave, command), (KeyCode.grave, commandShift),
             (KeyCode.escape, [.maskCommand, .maskAlternate]),
             (KeyCode.q, [.maskControl, .maskCommand]):
            return .passAndClose
        default:
            return nil
        }
    }
}

/// Клавиши, нажатие которых перехват проглотил: их автоповтор и отпускание тоже не должны дойти
/// до приложения — иначе Finder получит «отпускание» без нажатия или повтор Пробела откроет Quick Look.
nonisolated struct SwallowedKeys {
    private var keys = Set<UInt16>()

    mutating func swallow(_ keyCode: UInt16) { keys.insert(keyCode) }

    /// Клавиша проглочена и ещё не отпущена (для её автоповтора).
    func isHeld(_ keyCode: UInt16) -> Bool { keys.contains(keyCode) }

    /// Новое (не автоповтор) нажатие: прежнее отпускание потерялось, забываем его.
    mutating func pressed(_ keyCode: UInt16) { keys.remove(keyCode) }

    /// Отпускание: `true` — его тоже нужно проглотить.
    mutating func released(_ keyCode: UInt16) -> Bool { keys.remove(keyCode) != nil }

    /// Система отключала tap — отпускания могли пройти мимо.
    mutating func reset() { keys.removeAll() }
}
