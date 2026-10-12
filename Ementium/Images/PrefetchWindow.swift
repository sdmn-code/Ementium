import Foundation

/// Какие соседние картинки держать готовыми и в каком порядке их декодировать.
/// Чистая логика — покрыта тестами; источник соседей — `ImageDirectory` или окно Finder.
nonisolated enum PrefetchWindow {
    /// Вперёд листают чаще — туда больше; одна назад — чтобы вернуться без ожидания.
    static let forward = 2
    static let backward = 1

    /// Порядок предзагрузки: +1, −1, +2, −2… — ближние раньше дальних, вперёд раньше назад.
    static func order(forward: [URL], backward: [URL]) -> [URL] {
        var result: [URL] = []
        for index in 0..<max(forward.count, backward.count) {
            if index < forward.count { result.append(forward[index]) }
            if index < backward.count { result.append(backward[index]) }
        }
        return result
    }

    /// Ближайшие картинки вокруг элемента `index` из `count` элементов, в порядке предзагрузки.
    /// `url(i)` — файл элемента (`nil` — элемента без файла, например заголовка группы в Finder);
    /// он вызывается лениво: в окне Finder каждый вызов — AX-запрос. В каждую сторону просматриваем
    /// не больше `limit` элементов.
    static func neighbors(
        of index: Int, count: Int, url: (Int) -> URL?, isImage: (URL) -> Bool,
        forward: Int = forward, backward: Int = backward, limit: Int = .max
    ) -> [URL] {
        func scan(step: Int, wanted: Int) -> [URL] {
            var found: [URL] = []
            var position = index
            var looked = 0
            while found.count < wanted, looked < limit {
                position += step
                guard (0..<count).contains(position) else { break }
                looked += 1
                if let file = url(position), isImage(file) { found.append(file) }
            }
            return found
        }
        return order(forward: scan(step: 1, wanted: forward), backward: scan(step: -1, wanted: backward))
    }
}
