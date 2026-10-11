import Foundation

/// Отличает окно обычной папки от виртуального: «Недавние», результаты поиска, тег, смарт-папка.
///
/// Явного признака в Accessibility у Finder нет (`AXDocument` пуст у всех окон, `AXProxy` одинаковый —
/// см. `Prototypes/FinderAXProbe`), поэтому сравниваем заголовок окна с именем папки, где лежит файл.
/// Ошибка эвристики безопасна: окно сочтётся папкой, и листаться будет каталог файла.
nonisolated enum FinderLocation {
    static func isFolderWindow(title: String, folderName: String) -> Bool {
        let title = normalized(title)
        let name = normalized(folderName)
        // Заголовок неизвестен — ведём себя как раньше.
        guard !title.isEmpty, !name.isEmpty else { return true }
        if title == name { return true }
        // «⁨Документы⁩ — локальный»: имя папки и пояснение через тире.
        return title.hasPrefix(name + " — ") || title.hasPrefix(name + " - ")
    }

    /// Убирает невидимые символы направления текста (U+2068/2069 вокруг имени) и неразрывные пробелы.
    private static func normalized(_ string: String) -> String {
        let scalars = string.unicodeScalars.filter { $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
