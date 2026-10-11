import CoreGraphics
import Foundation

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
}
