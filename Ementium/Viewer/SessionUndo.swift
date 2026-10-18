import Foundation

/// История отмены сеанса просмотра: что вернуть по `⌘Z`. Одна на все действия над файлами — удаление в Корзину,
/// метки, перемещение и копирование (последние — для функции перемещения в папки). Очищается при закрытии
/// просмотра. Решает только **что** отменять: удаление отменяет мост Finder (`FinderBridge.undoTrash`, со своими
/// проверками), метки — сам просмотр.
nonisolated struct SessionUndo: Equatable {
    enum Entry: Equatable {
        /// Файл ушёл в Корзину через Finder.
        case trash(URL)
        /// Метки файла до нажатия цифры.
        case tags(url: URL, before: [String])
        case move(from: URL, to: URL)
        case copy(URL)
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func record(_ entry: Entry) {
        entries.append(entry)
    }

    /// Последнее действие — его и отменять; `nil` — отменять нечего.
    mutating func undo() -> Entry? {
        entries.popLast()
    }

    mutating func clear() {
        entries.removeAll()
    }
}
