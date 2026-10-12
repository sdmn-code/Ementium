import Foundation

/// Можно ли переместить файл в Корзину без вопросов Finder. Если нет — Ementium файл не трогает:
/// диалог Finder («удалить навсегда?», «файл защищён», пароль администратора) оказался бы под оверлеем.
nonisolated enum TrashCheck {
    enum Problem: Equatable {
        case missing
        /// Открыт прямо из Корзины: там ⌘⌫ удалил бы его насовсем.
        case alreadyInTrash
        /// Сетевой диск: Корзины обычно нет, удаление было бы необратимым.
        case noTrash
        /// Файл защищён («Защита» в окне «Свойства»).
        case locked
        /// Нет прав на удаление из этой папки (или том только для чтения).
        case noPermission

        var message: String {
            switch self {
            case .missing: "Файл не найден"
            case .alreadyInTrash: "Файл уже в Корзине"
            case .noTrash: "Здесь нет Корзины — удалите в Finder"
            case .locked: "Файл защищён — удалите в Finder"
            case .noPermission: "Нет прав на удаление — удалите в Finder"
            }
        }
    }

    /// Вне главного потока: том может быть сетевым.
    @concurrent
    static func problem(_ url: URL) async -> Problem? {
        check(url)
    }

    static func check(_ url: URL) -> Problem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if isInTrash(url) { return .alreadyInTrash }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.isUserImmutableKey, .volumeIsLocalKey])
        if values?.isUserImmutable == true { return .locked }
        if values?.volumeIsLocal == false { return .noTrash }
        if !FileManager.default.isDeletableFile(atPath: url.path) { return .noPermission }
        return nil
    }

    /// Внутри `~/.Trash` или `.Trashes` на внешнем диске.
    static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }
}
