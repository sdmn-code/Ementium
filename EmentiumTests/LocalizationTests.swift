import Foundation
import Testing
@testable import Ementium

/// Английский — язык разработки, русский — перевод. Строка без перевода показалась бы русскому
/// пользователю по-английски — это ловится здесь, а не руками.
struct LocalizationTests {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func catalog(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["strings"] as? [String: Any])
    }

    private func russian(_ entry: Any?) -> String? {
        let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any]
        let unit = (localizations?["ru"] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    @Test func everyCatalogEntryHasRussian() throws {
        for path in ["Ementium/Localizable.xcstrings", "Shared/Decoder.xcstrings"] {
            for (key, entry) in try catalog(path) where (russian(entry) ?? "").isEmpty {
                Issue.record("\(path): нет перевода для «\(key)»")
            }
        }
    }

    private var appSources: [URL] {
        FileManager.default.enumerator(at: root.appendingPathComponent("Ementium"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    }

    /// Ключи каталога, которые находит `pattern` (первая группа) в файлах, прошедших `filter`; сколько нашлось.
    private func checkKeys(pattern: String, filter: (String) -> Bool = { _ in true }) throws -> Int {
        let strings = try catalog("Ementium/Localizable.xcstrings")
        let regex = try NSRegularExpression(pattern: pattern)
        var found = 0
        for file in appSources {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard filter(text) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                // Подстановки `\(...)` в каталоге — `%@`.
                let key = String(text[range]).replacingOccurrences(
                    of: #"\\\([^)]*\)"#, with: "%@", options: .regularExpression
                )
                found += 1
                if strings[key] == nil { Issue.record("\(file.lastPathComponent): «\(key)» нет в каталоге") }
            }
        }
        return found
    }

    // Каждый String(localized: "...") в коде приложения есть в каталоге.
    @Test func everyLocalizedStringIsInCatalog() throws {
        let found = try checkKeys(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        #expect(found > 20)
    }

    // Подписи SwiftUI — литералы `LocalizedStringKey`: в каталог их добавляют руками, и забытая показалась бы
    // по-английски. `Text(verbatim:)` — не перевод и сюда не попадает.
    @Test func everySwiftUILiteralIsInCatalog() throws {
        let found = try checkKeys(
            pattern: #"\b(?:(?:Text|Toggle|Button|Section|Link|LabeledContent|ColorPicker|Label|Picker)\(|(?:title|description): )"((?:[^"\\]|\\.)*)""#,
            filter: { $0.contains("import SwiftUI") }
        )
        #expect(found > 30)
    }

    // В русском переводе карточки — русские слова (каталог сервиса подключён).
    @Test func russianCardWords() throws {
        let decoder = try catalog("Shared/Decoder.xcstrings")
        #expect(russian(decoder["unit.millimeters"]) == "мм")
        #expect(russian(decoder["gps.north"]) == "с. ш.")
    }
}
