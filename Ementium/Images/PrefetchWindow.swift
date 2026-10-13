import Foundation

/// Какие соседние картинки держать готовыми и в каком порядке их декодировать.
/// Чистая логика — покрыта тестами; источник соседей — `ImageDirectory` или окно Finder.
nonisolated enum PrefetchWindow {
    /// Готовить две картинки в сторону листания и одну позади — чтобы вернуться без ожидания.
    static let forward = 2
    static let backward = 1
    /// Сколько соседей знать с каждой стороны (адреса, не картинки): три быстрых смахивания подряд в любую
    /// сторону — не дожидаясь, пока Finder сообщит соседей новой картинки (бывает дольше полсекунды).
    static let reach = 3

    /// Порядок предзагрузки: +1, −1, +2, −2… — ближние раньше дальних, вперёд раньше назад.
    static func order(forward: [URL], backward: [URL]) -> [URL] {
        var result: [URL] = []
        for index in 0..<max(forward.count, backward.count) {
            if index < forward.count { result.append(forward[index]) }
            if index < backward.count { result.append(backward[index]) }
        }
        return result
    }

    /// Соседи по сторонам: дальше и раньше по списку (ближние первыми). `next` / `previous` — для смахивания.
    struct Neighbors: Equatable, Sendable {
        var forward: [URL] = []
        var backward: [URL] = []

        var next: URL? { forward.first }
        var previous: URL? { backward.first }

        /// Порядок предзагрузки: две в сторону листания, одна позади — +1, −1, +2 (или −1, +1, −2).
        func prefetchOrder(backwards: Bool) -> [URL] {
            let ahead = backwards ? backward : forward
            let behind = backwards ? forward : backward
            return PrefetchWindow.order(
                forward: Array(ahead.prefix(PrefetchWindow.forward)), backward: Array(behind.prefix(PrefetchWindow.backward))
            )
        }

        /// Те же соседи, отсчитанные от `url` — одного из них (`center` — вокруг кого прочитаны).
        /// `nil` — `url` среди них нет.
        func recentered(around center: URL, to url: URL) -> Neighbors? {
            let strip = backward.reversed() + [center] + forward
            guard let index = strip.firstIndex(of: url) else { return nil }
            return Neighbors(forward: Array(strip[(index + 1)...]), backward: Array(strip[..<index].reversed()))
        }

        /// Соседи того же места из двух источников: окно Finder одно, так что короткая сторона — начало длинной.
        func merged(with other: Neighbors) -> Neighbors {
            Neighbors(
                forward: forward.count >= other.forward.count ? forward : other.forward,
                backward: backward.count >= other.backward.count ? backward : other.backward
            )
        }
    }

    /// То же, что `neighbors`, но по сторонам.
    static func sides(
        of index: Int, count: Int, url: (Int) -> URL?, isImage: (URL) -> Bool,
        forward: Int = forward, backward: Int = backward, limit: Int = .max
    ) -> Neighbors {
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
        return Neighbors(forward: scan(step: 1, wanted: forward), backward: scan(step: -1, wanted: backward))
    }

    /// Ближайшие картинки вокруг элемента `index` из `count` элементов, в порядке предзагрузки.
    /// `url(i)` — файл элемента (`nil` — элемента без файла, например заголовка группы в Finder);
    /// он вызывается лениво: в окне Finder каждый вызов — AX-запрос. В каждую сторону просматриваем
    /// не больше `limit` элементов.
    static func neighbors(
        of index: Int, count: Int, url: (Int) -> URL?, isImage: (URL) -> Bool,
        forward: Int = forward, backward: Int = backward, limit: Int = .max
    ) -> [URL] {
        let found = sides(of: index, count: count, url: url, isImage: isImage, forward: forward, backward: backward, limit: limit)
        return order(forward: found.forward, backward: found.backward)
    }
}
