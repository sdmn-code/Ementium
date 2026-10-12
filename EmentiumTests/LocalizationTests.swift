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

    // Каждый String(localized: "...") в коде приложения есть в каталоге.
    @Test func everyLocalizedStringIsInCatalog() throws {
        let strings = try catalog("Ementium/Localizable.xcstrings")
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Ementium"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        let pattern = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        var found = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let key = String(text[range]).replacingOccurrences(of: "\\'", with: "'")
                found += 1
                if strings[key] == nil { Issue.record("\(file.lastPathComponent): «\(key)» нет в каталоге") }
            }
        }
        #expect(found > 20)
    }

    // В русском переводе карточки — русские слова (каталог сервиса подключён).
    @Test func russianCardWords() throws {
        let decoder = try catalog("Shared/Decoder.xcstrings")
        #expect(russian(decoder["unit.millimeters"]) == "мм")
        #expect(russian(decoder["gps.north"]) == "с. ш.")
    }
}
