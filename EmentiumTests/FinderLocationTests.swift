import Testing
@testable import Ementium

/// Заголовки — реальные, из логов FinderAXProbe (macOS 27), включая невидимые U+2068/2069 и неразрывный пробел.
struct FinderLocationTests {
    @Test(arguments: [
        ("testdata", "testdata"),
        ("huge", "huge"),
        ("Загрузки", "Загрузки"),
        ("\u{2068}Документы\u{2069}\u{00A0}— локальный", "Документы"),
        ("\u{2068}Рабочий стол\u{2069} — локальный", "Рабочий стол"),
        ("Macintosh HD", "Macintosh HD"),
    ])
    func folderWindows(title: String, folder: String) {
        #expect(FinderLocation.isFolderWindow(title: title, folderName: folder))
    }

    @Test(arguments: [
        ("Недавние", "Downloads"),
        ("Место поиска: Этот Mac", "testdata"),
        ("Красный", "Документы"),
        // Похожее начало имени — ещё не та папка.
        ("testdata-old", "testdata"),
    ])
    func virtualWindows(title: String, folder: String) {
        #expect(!FinderLocation.isFolderWindow(title: title, folderName: folder))
    }

    // Не знаем заголовок — ведём себя как раньше (листаем каталог).
    @Test func unknownTitleCountsAsFolder() {
        #expect(FinderLocation.isFolderWindow(title: "", folderName: "testdata"))
        #expect(FinderLocation.isFolderWindow(title: "\u{2068}\u{2069}", folderName: "testdata"))
    }
}
