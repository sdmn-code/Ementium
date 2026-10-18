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
    /// Просмотр открыт в режиме «следовать за Finder»: клавиатура остаётся у Finder,
    /// и все нажатия разбирает перехват (`InterceptionPolicy.followingAction`).
    var isFollowingFinder = false
    /// Системные сочетания пользователя (с учётом переназначенных) — их перехват пропускает.
    var systemShortcuts: [SystemShortcut] = []
    /// Настройка «Пробел в просмотре закрывает его»; выключена — закрывает только Esc.
    var spaceClosesViewer = true
    /// Настройка «⌘⌫ перемещает в Корзину».
    var trashEnabled = false
    /// Метки клавишами 1–7.
    var tagsEnabled = false
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
