import AppKit
import Darwin
import os

/// Метки клавишами 1–7: чтение и запись тегов Finder на файле. Теги — атрибут файла, а не содержимое: граница
/// процессов (приложение не разбирает файлы картинок) не нарушается. Всё — вне главного потока: на сетевом
/// диске это медленно. Факты — прототип `Prototypes/FinderTagProbe`:
/// - пишется весь список (`tagNamesKey`), поэтому чужие теги сохраняются, если прочитать, переключить, записать;
/// - в историю отмены Finder запись не попадает — `⌘Z` по меткам делает сам Ementium;
/// - дата изменения файла не меняется.
nonisolated enum FileTagger {
    /// Почему не вышло: у каждой причины своя подсказка в просмотре.
    enum Failure: Error, Equatable {
        /// Нет прав на запись или файл защищён (`-5000`).
        case noPermission
        /// Том только для чтения (`-61`).
        case readOnlyVolume
        /// Файла нет (`-43`).
        case missing
        case other
    }

    private static let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "tags")

    /// Номера цветов тегов (старых «ярлыков») в порядке меню Finder: красный, оранжевый, жёлтый, зелёный, синий,
    /// лиловый, серый — это цифры 1–7.
    static let menuOrderColors = [6, 7, 5, 2, 4, 3, 1]

    /// Цвета точек и кружков — системные, как у тегов Finder; в порядке меню.
    @MainActor static let menuOrderNSColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemGray,
    ]

    @concurrent static func tags(of url: URL) async throws -> [String] {
        try readTags(url)
    }

    /// Переключить тег `tag`: прочитать, переключить (`TagToggle`), записать и перечитать для проверки.
    @concurrent static func toggle(_ tag: String, at url: URL) async throws -> (before: [String], after: [String]) {
        let before = try readTags(url)
        try writeTags(TagToggle.toggled(before, tag), to: url)
        return (before, try readTags(url))
    }

    /// `⌘Z`: вернуть теги, какими были.
    @concurrent static func restore(_ tags: [String], at url: URL) async throws -> [String] {
        try writeTags(tags, to: url)
        return try readTags(url)
    }

    /// Имена цветных тегов на языке системы, в порядке меню Finder (`nil` — для цвета имени нет). Цвет даёт только
    /// имя на языке системы («Красный» на русской), а `NSWorkspace.fileLabels` — на языке программы, и в русской
    /// системе «Red» стал бы бесцветным тегом. Поэтому кандидаты — избранные теги Finder (`FavoriteTagNames`, язык
    /// системы, переименованные тоже) и `fileLabels`, а цвет каждому даёт сама система: запись во временный файл
    /// и номер цвета из атрибута. ~0,1 с.
    @concurrent static func colorTagNames() async -> [String?] {
        let favorites = UserDefaults(suiteName: "com.apple.finder")?.stringArray(forKey: "FavoriteTagNames") ?? []
        let labels = await MainActor.run { NSWorkspace.shared.fileLabels }
        // Английские — на случай, если избранных у Finder нет, а язык программы не совпал с системным.
        let english = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
        let candidates = (favorites + labels + english).filter { !$0.isEmpty }
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("Ementium-tags-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
            log.error("Метки: не создал временный файл для имён цветов")
            return menuOrderColors.map { _ in nil }
        }
        defer { try? FileManager.default.removeItem(at: probe) }
        var byColor: [Int: String] = [:]
        for name in candidates {
            guard (try? writeTags([name], to: probe)) != nil, let color = storedColors(probe).first, color > 0,
                  byColor[color] == nil else { continue }
            byColor[color] = name
        }
        let names = menuOrderColors.map { byColor[$0] }
        log.notice("Метки: имён цветов найдено \(names.compactMap { $0 }.count, privacy: .public) из 7")
        return names
    }

    static func failure(_ error: Error) -> Failure {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSOSStatusErrorDomain, -5000), (NSCocoaErrorDomain, NSFileWriteNoPermissionError): return .noPermission
        case (NSOSStatusErrorDomain, -61), (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError): return .readOnlyVolume
        case (NSOSStatusErrorDomain, -43), (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError): return .missing
        default: return .other
        }
    }

    // MARK: - Синхронно, на вызывающем потоке

    private static func readTags(_ url: URL) throws -> [String] {
        // Свежий URL: у прежнего значения закэшированы.
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    private static func writeTags(_ tags: [String], to url: URL) throws {
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
    }

    /// Номера цветов из атрибута, где система хранит теги как «имя\nцвет».
    private static func storedColors(_ url: URL) -> [Int] {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard read == size, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return list.compactMap { $0.split(separator: "\n").last.flatMap { Int($0) } }
    }
}
