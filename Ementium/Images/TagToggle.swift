import Foundation

/// Метки клавишами 1–7: переключить один тег Finder в списке тегов файла. Метки складываются — остальные теги
/// файла (в том числе свои, вроде «Работа») и их порядок не трогаются. Система хранит весь список целиком, поэтому
/// запись — это прочитанный список, пропущенный через `toggled` (прототип FinderTagProbe).
nonisolated enum TagToggle {
    /// Тега не было — добавлен в конец; был — убран (вместе с повторами в другом регистре).
    static func toggled(_ tags: [String], _ tag: String) -> [String] {
        contains(tags, tag) ? tags.filter { !same($0, tag) } : tags + [tag]
    }

    static func contains(_ tags: [String], _ tag: String) -> Bool {
        tags.contains { same($0, tag) }
    }

    /// Имена тегов Finder сравнивает без учёта регистра, «ё» и «е» для него одно («Жёлтый» и «Желтый» — один цвет,
    /// прототип FinderTagProbe). Без общего пренебрежения диакритикой: «й» и «и» — разные буквы.
    static func same(_ a: String, _ b: String) -> Bool {
        folded(a).compare(folded(b), options: .caseInsensitive) == .orderedSame
    }

    private static func folded(_ name: String) -> String {
        name.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
    }
}
