import Foundation
import UniformTypeIdentifiers

/// Список изображений для просмотра и текущая позиция в нём.
///
/// Открыт один файл — в список попадают все изображения его каталога.
/// Открыто несколько — только переданные изображения, как в Quick Look.
nonisolated struct ImageDirectory: Equatable {
    private(set) var images: [URL]
    private(set) var index: Int

    var current: URL { images[index] }
    var hasNext: Bool { index < images.count - 1 }
    var hasPrevious: Bool { index > 0 }

    /// Возвращает `nil`, если среди `urls` нет ни одного изображения.
    init?(opening urls: [URL], fileManager: FileManager = .default) {
        let opened = urls.filter(Self.isImage)
        guard let first = opened.first else { return nil }

        if urls.count == 1 {
            let folder = first.deletingLastPathComponent()
            let siblings = (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentTypeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []
            images = Self.sorted(siblings.filter(Self.isImage))
            // Соседи перечислены из того же каталога, что и `first`, поэтому достаточно сравнить имена.
            // Каталог мог не прочитаться или файл мог исчезнуть — тогда показываем хотя бы его.
            if let position = images.firstIndex(where: { $0.lastPathComponent == first.lastPathComponent }) {
                index = position
                // Перечисление каталога может вернуть путь в другом написании (/private/var вместо /var).
                // Текущим оставляем переданный URL: по нему просмотр сверяет, что показывает нужный файл.
                images[position] = first
            } else {
                images = [first]
                index = 0
            }
        } else {
            var seen = Set<String>()
            images = Self.sorted(opened).filter { seen.insert(Self.fileKey($0)).inserted }
            index = 0
        }
    }

    /// Список из одного изображения, который строится без чтения каталога, — чтобы показать картинку сразу,
    /// пока полный список собирается в фоне. Для нескольких файлов это первое по имени изображение,
    /// то есть то же, с которого начнёт полный список.
    init?(preview urls: [URL]) {
        guard let first = Self.sorted(urls).first(where: Self.isImage) else { return nil }
        images = [first]
        index = 0
    }

    /// Строит полный список вне главного потока: каталог может быть большим или на сетевом диске.
    @concurrent
    static func load(opening urls: [URL]) async -> ImageDirectory? {
        ImageDirectory(opening: urls)
    }


    /// Переходит к следующему изображению. На последнем ничего не делает и возвращает `false`.
    @discardableResult
    mutating func moveNext() -> Bool {
        guard hasNext else { return false }
        index += 1
        return true
    }

    /// Сдвигается на `steps` изображений (отрицательное — назад), упираясь в края.
    /// Возвращает `false`, если позиция не изменилась.
    @discardableResult
    mutating func move(by steps: Int) -> Bool {
        let target = min(max(index + steps, 0), images.count - 1)
        guard target != index else { return false }
        index = target
        return true
    }

    /// Переходит к предыдущему изображению. На первом ничего не делает и возвращает `false`.
    @discardableResult
    mutating func movePrevious() -> Bool {
        guard hasPrevious else { return false }
        index -= 1
        return true
    }

    static func isImage(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey]),
              values.isDirectory != true,
              let type = values.contentType else { return false }
        return type.conforms(to: .image)
    }

    /// Порядок как в Finder при сортировке по имени: «img-2» перед «img-10».
    /// Имена, равные для `localizedStandardCompare` («img-01» и «img-1»), упорядочиваются по пути, чтобы порядок был стабильным.
    static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted {
            switch $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.path < $1.path
            }
        }
    }

    /// Один и тот же файл, открытый по разным путям (например, через /var и /private/var), даёт один ключ.
    private static func fileKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
