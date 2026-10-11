import Foundation
import os

/// Всё, что нужно знать в момент нажатия Пробела, чтобы решить, перехватывать ли его.
nonisolated struct InterceptionSnapshot: Sendable, Equatable {
    var isEnabled = true
    var isFinderFrontmost = false
    var isViewerVisible = false
    /// От Finder пришло уведомление, а снимок ещё не обновлён (идёт дебаунс или AX-запрос).
    /// Пока снимок устарел, Пробел пропускается — лучше открыть обычный Quick Look, чем не то.
    var isFinderStateStale = true
    var isTextFieldFocused = false
    var selection: [URL] = []
    var selectionHasImage = false
    /// Выделен один файл, и окно Finder — не его папка, а «Недавние», поиск, тег или смарт-папка.
    /// Тогда листать нужно то, что показано в окне, а не каталог файла.
    var isVirtualLocation = false
}

/// Общий снимок для трёх потоков: главного, `FinderBridge` и `KeyInterceptor`.
/// Callback перехвата только читает его под замком — без обращений к Finder.
nonisolated final class InterceptionState: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: InterceptionSnapshot())

    var snapshot: InterceptionSnapshot {
        lock.withLock { $0 }
    }

    func update(_ change: (inout InterceptionSnapshot) -> Void) {
        lock.withLockUnchecked { change(&$0) }
    }
}
