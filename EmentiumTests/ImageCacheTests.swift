import CoreGraphics
import Foundation
import os
import Testing
@testable import Ementium

struct PrefetchWindowTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    @Test func nearestFirstForwardBeforeBackward() {
        let order = PrefetchWindow.order(forward: [url("f1"), url("f2")], backward: [url("b1")])
        #expect(order == [url("f1"), url("b1"), url("f2")])
    }

    @Test func orderAtTheEdges() {
        #expect(PrefetchWindow.order(forward: [], backward: [url("b1")]) == [url("b1")])
        #expect(PrefetchWindow.order(forward: [url("f1")], backward: []) == [url("f1")])
        #expect(PrefetchWindow.order(forward: [], backward: []).isEmpty)
    }

    // Окно Finder: документы и заголовки групп (без файла) между картинками пропускаются.
    @Test func skipsDocumentsAndRowsWithoutFiles() {
        let items: [URL?] = [url("a.jpg"), url("doc.pdf"), nil, url("b.jpg"), url("c.jpg"), url("d.txt"), url("e.jpg"), url("f.jpg")]
        let neighbors = PrefetchWindow.neighbors(
            of: 3, count: items.count, url: { items[$0] }, isImage: { $0.pathExtension == "jpg" }
        )
        #expect(neighbors == [url("c.jpg"), url("a.jpg"), url("e.jpg")])
    }

    @Test func firstAndLastHaveNeighborsOnOneSide() {
        let items = (0..<5).map { url("\($0).jpg") }
        #expect(PrefetchWindow.neighbors(of: 0, count: 5, url: { items[$0] }, isImage: { _ in true })
            == [items[1], items[2]])
        #expect(PrefetchWindow.neighbors(of: 4, count: 5, url: { items[$0] }, isImage: { _ in true })
            == [items[3]])
    }

    @Test func singleImageHasNoNeighbors() {
        #expect(PrefetchWindow.neighbors(of: 0, count: 1, url: { _ in self.url("a.jpg") }, isImage: { _ in true }).isEmpty)
    }

    // Не больше `limit` элементов в каждую сторону: в огромной папке без картинок не читаем всё окно Finder.
    @Test func lookupIsLimited() {
        var asked = 0
        let neighbors = PrefetchWindow.neighbors(
            of: 500, count: 1000, url: { asked += 1; return self.url("\($0).txt") },
            isImage: { $0.pathExtension == "jpg" }, limit: 10
        )
        #expect(neighbors.isEmpty)
        #expect(asked == 20)
    }
}

/// Подменный загрузчик: запоминает вызовы и считает, сколько декодирований идёт одновременно.
private final class FakeLoader: Sendable {
    struct State {
        var fullCalls: [URL] = []
        var cancelled: [URL] = []
        var running = 0
        var maxRunning = 0
        var remote: Set<URL> = []
        var downloaded: [URL] = []
        var broken: Set<URL> = []
        var rawWithPreview: [URL: Int] = [:]
        var modified: [URL: Date] = [:]
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let delay: Duration

    init(delay: Duration = .milliseconds(30)) {
        self.delay = delay
    }

    static func image(longSide: Int, original: Int) -> DecodedImage {
        let context = CGContext(
            data: nil, width: longSide, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return DecodedImage(LoadedImage(
            image: context.makeImage()!, pointSize: CGSize(width: original, height: 1),
            pixelSize: CGSize(width: original, height: 1)
        ))!
    }

    var loader: ImageCache.Loader {
        ImageCache.Loader(
            rawPreview: { url, _ in
                guard let side = self.state.withLock({ $0.rawWithPreview[url] }) else { return nil }
                return Self.image(longSide: side, original: 4000)
            },
            full: { url, size in
                self.state.withLock {
                    $0.fullCalls.append(url)
                    $0.running += 1
                    $0.maxRunning = max($0.maxRunning, $0.running)
                }
                defer { self.state.withLock { $0.running -= 1 } }
                do {
                    try await Task.sleep(for: self.delay)
                } catch {
                    self.state.withLock { $0.cancelled.append(url) }
                    throw error
                }
                if self.state.withLock({ $0.broken.contains(url) }) { throw ImageLoaderError.noImage }
                return Self.image(longSide: size, original: 4000)
            },
            ensureDownloaded: { url in
                self.state.withLock { if $0.remote.remove(url) != nil { $0.downloaded.append(url) } }
            },
            needsDownload: { url in self.state.withLock { $0.remote.contains(url) } },
            modificationDate: { url in self.state.withLock { $0.modified[url] } }
        )
    }
}

@MainActor
struct ImageCacheTests {
    private nonisolated func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).jpg") }

    /// Ждёт условия (загрузки идут в фоне) — не дольше 2 с.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private final class Recorder {
        var updates: [String] = []
        var isFinal: Bool { updates.last == "final" }
        func record(_ update: ImageCache.Update) {
            switch update {
            case .preview: updates.append("preview")
            case .final: updates.append("final")
            case .failed: updates.append("failed")
            }
        }
    }

    @Test func currentImageIsLoadedAndReported() async {
        let fake = FakeLoader()
        let cache = ImageCache(loader: fake.loader)
        let recorder = Recorder()
        cache.request(url("a"), maxPixelSize: 100) { recorder.record($0) }
        #expect(recorder.updates.isEmpty)
        await waitUntil { recorder.isFinal }
        #expect(recorder.updates == ["final"])
    }

    // Предзагруженная картинка отдаётся сразу — синхронно, без индикатора.
    @Test func prefetchedNeighborIsReadyImmediately() async {
        let fake = FakeLoader()
        let cache = ImageCache(loader: fake.loader)
        cache.request(url("a"), maxPixelSize: 100) { _ in }
        cache.prefetch([url("b"), url("c")], around: url("a"), maxPixelSize: 100)
        await waitUntil { fake.state.withLock { $0.fullCalls.count == 3 && $0.running == 0 } }

        let recorder = Recorder()
        cache.request(url("b"), maxPixelSize: 100) { recorder.record($0) }
        #expect(recorder.updates == ["final"])
        #expect(fake.state.withLock { $0.fullCalls.count } == 3)
    }

    // Соседи — по одному и только после текущей: текущая не делит процессор с предзагрузкой.
    @Test func neighborsWaitForCurrentAndLoadOneByOne() async {
        let fake = FakeLoader()
        let cache = ImageCache(loader: fake.loader)
        cache.request(url("a"), maxPixelSize: 100) { _ in }
        cache.prefetch([url("b"), url("z"), url("c")], around: url("a"), maxPixelSize: 100)
        await waitUntil { fake.state.withLock { $0.fullCalls.count == 4 && $0.running == 0 } }
        let calls = fake.state.withLock { $0.fullCalls }
        #expect(calls == [url("a"), url("b"), url("z"), url("c")])
        #expect(fake.state.withLock { $0.maxRunning } == 1)
    }

    @Test func imagesOutsideTheWindowAreDropped() async {
        let fake = FakeLoader()
        let cache = ImageCache(loader: fake.loader)
        cache.request(url("a"), maxPixelSize: 100) { _ in }
        cache.prefetch([url("b"), url("c")], around: url("a"), maxPixelSize: 100)
        await waitUntil { fake.state.withLock { $0.fullCalls.count == 3 && $0.running == 0 } }

        // Шагнули на b: окно — b, его соседи c и a (уже готовы); d новая — b готова, поэтому d грузится сразу.
        cache.request(url("b"), maxPixelSize: 100) { _ in }
        cache.prefetch([url("c"), url("a"), url("d")], around: url("b"), maxPixelSize: 100)
        #expect(cache.count == 4)
        await waitUntil { fake.state.withLock { $0.fullCalls.count == 4 && $0.running == 0 } }
        // Шагнули далеко: всё старое вне окна.
        cache.request(url("x"), maxPixelSize: 100) { _ in }
        cache.prefetch([url("y")], around: url("x"), maxPixelSize: 100)
        #expect(!cache.contains(url("a")))
        #expect(!cache.contains(url("b")))
        #expect(cache.contains(url("x")))
    }

    // Соседи не пришли (Finder не ответил) — память всё равно ограничена.
    @Test func capacityIsLimitedWithoutNeighborUpdates() async {
        let fake = FakeLoader(delay: .milliseconds(1))
        let cache = ImageCache(loader: fake.loader)
        for index in 0..<8 {
            cache.request(url("\(index)"), maxPixelSize: 100) { _ in }
            #expect(cache.count <= ImageCache.capacity)
        }
        #expect(cache.contains(url("7")))
    }

    @Test func outdatedPrefetchIsIgnored() async {
        let fake = FakeLoader()
        let cache = ImageCache(loader: fake.loader)
        cache.request(url("a"), maxPixelSize: 100) { _ in }
        cache.request(url("b"), maxPixelSize: 100) { _ in }
        // Соседи «a» пришли от Finder, когда показывается уже «b».
        cache.prefetch([url("c")], around: url("a"), maxPixelSize: 100)
        await waitUntil { fake.state.withLock { $0.fullCalls.count == 2 && $0.running == 0 } }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(!cache.contains(url("c")))
    }

    // RAW: превью сразу, полная версия следом.
    @Test func rawPreviewThenFull() async {
        let fake = FakeLoader()
        fake.state.withLock { $0.rawWithPreview[url("raw")] = 1600 }
        let cache = ImageCache(loader: fake.loader)
        let recorder = Recorder()
        cache.request(url("raw"), maxPixelSize: 3000) { recorder.record($0) }
        await waitUntil { recorder.isFinal }
        #expect(recorder.updates == ["preview", "final"])
    }

    // Полноразмерное превью (Nikon) — второе декодирование не нужно.
    @Test func fullSizePreviewIsFinal() async {
        let fake = FakeLoader()
        fake.state.withLock { $0.rawWithPreview[url("nef")] = 4000 }
        let cache = ImageCache(loader: fake.loader)
        let recorder = Recorder()
        cache.request(url("nef"), maxPixelSize: 3000) { recorder.record($0) }
        await waitUntil { recorder.isFinal }
        #expect(recorder.updates == ["preview", "final"])
        #expect(fake.state.withLock { $0.fullCalls }.isEmpty)
    }

    @Test func brokenFileFails() async {
        let fake = FakeLoader()
        fake.state.withLock { $0.broken = [url("bad")] }
        let cache = ImageCache(loader: fake.loader)
        let recorder = Recorder()
        cache.request(url("bad"), maxPixelSize: 100) { recorder.record($0) }
        await waitUntil { !recorder.updates.isEmpty }
        #expect(recorder.updates == ["failed"])
    }

    // Превью есть, а полная версия не декодировалась — превью остаётся окончательной версией.
    @Test func previewSurvivesFailedFullDecode() async {
        let fake = FakeLoader()
        fake.state.withLock {
            $0.rawWithPreview[url("raw")] = 1600
            $0.broken = [url("raw")]
        }
        let cache = ImageCache(loader: fake.loader)
        let first = Recorder()
        cache.request(url("raw"), maxPixelSize: 3000) { first.record($0) }
        await waitUntil { first.updates.count == 2 }
        #expect(first.updates == ["preview", "failed"])

        let again = Recorder()
        cache.request(url("raw"), maxPixelSize: 3000) { again.record($0) }
        #expect(again.updates == ["final"])
    }

    // Соседа в iCloud не скачиваем; текущую — скачиваем.
    @Test func remoteNeighborIsSkippedButRemoteCurrentIsDownloaded() async {
        let fake = FakeLoader()
        fake.state.withLock { $0.remote = [url("cloud"), url("cloud2")] }
        let cache = ImageCache(loader: fake.loader)
        cache.request(url("a"), maxPixelSize: 100) { _ in }
        cache.prefetch([url("cloud")], around: url("a"), maxPixelSize: 100)
        await waitUntil { fake.state.withLock { $0.fullCalls.count == 1 && $0.running == 0 } }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(!cache.contains(url("cloud")))
        #expect(fake.state.withLock { $0.downloaded }.isEmpty)

        let recorder = Recorder()
        cache.request(url("cloud2"), maxPixelSize: 100) { recorder.record($0) }
        await waitUntil { recorder.isFinal }
        #expect(fake.state.withLock { $0.downloaded } == [url("cloud2")])
    }

    // Готовая картинка показывается сразу, а дата файла проверяется в фоне (сетевой диск не должен
    // вешать главный поток). Файл поменяли — перечитываем и показываем заново.
    @Test func changedFileIsShownThenReloaded() async {
        let fake = FakeLoader()
        let cache = ImageCache(loader: fake.loader)
        let first = Recorder()
        cache.request(url("a"), maxPixelSize: 100) { first.record($0) }
        await waitUntil { first.isFinal }
        fake.state.withLock { $0.modified[url("a")] = Date() }

        let again = Recorder()
        cache.request(url("a"), maxPixelSize: 100) { again.record($0) }
        #expect(again.updates == ["final"])
        await waitUntil { again.updates.count == 2 }
        #expect(again.updates == ["final", "final"])
        #expect(fake.state.withLock { $0.fullCalls.count } == 2)
    }

    @Test func unchangedFileIsNotReloaded() async {
        let fake = FakeLoader()
        let cache = ImageCache(loader: fake.loader)
        let first = Recorder()
        cache.request(url("a"), maxPixelSize: 100) { first.record($0) }
        await waitUntil { first.isFinal }
        let again = Recorder()
        cache.request(url("a"), maxPixelSize: 100) { again.record($0) }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(again.updates == ["final"])
        #expect(fake.state.withLock { $0.fullCalls.count } == 1)
    }

    // Зажатая стрелка: недекодированная прежняя картинка отменяется — новая не ждёт кучу чужих декодирований.
    @Test func unfinishedPreviousCurrentIsCancelled() async {
        let fake = FakeLoader(delay: .milliseconds(200))
        let cache = ImageCache(loader: fake.loader)
        for name in ["a", "b", "c", "d"] {
            cache.request(url(name), maxPixelSize: 100) { _ in }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(cache.count == 1)
        await waitUntil { fake.state.withLock { $0.running == 0 } }
        #expect(fake.state.withLock { $0.cancelled } == [url("a"), url("b"), url("c")])
        // Отмена доходит до декодера не мгновенно — перекрытие не больше одной старой загрузки.
        #expect(fake.state.withLock { $0.maxRunning } <= 2)
    }

    // Соседи прежней картинки, ещё не начатые, после шага не грузятся.
    @Test func queuedNeighborsOfThePreviousImageAreDropped() async {
        let fake = FakeLoader(delay: .milliseconds(50))
        let cache = ImageCache(loader: fake.loader)
        cache.request(url("a"), maxPixelSize: 100) { _ in }
        cache.prefetch([url("b"), url("c")], around: url("a"), maxPixelSize: 100)
        cache.request(url("x"), maxPixelSize: 100) { _ in }
        await waitUntil { fake.state.withLock { $0.running == 0 && !$0.fullCalls.isEmpty } }
        try? await Task.sleep(for: .milliseconds(80))
        let calls = fake.state.withLock { $0.fullCalls }
        #expect(!calls.contains(url("b")))
        #expect(!calls.contains(url("c")))
    }

    // Битый сосед не блокирует очередь и не декодируется заново на каждом шаге.
    @Test func brokenNeighborIsTriedOnceAndDoesNotBlock() async {
        let fake = FakeLoader(delay: .milliseconds(5))
        fake.state.withLock { $0.broken = [url("bad")] }
        let cache = ImageCache(loader: fake.loader)
        cache.request(url("a"), maxPixelSize: 100) { _ in }
        cache.prefetch([url("bad"), url("c")], around: url("a"), maxPixelSize: 100)
        await waitUntil { fake.state.withLock { $0.fullCalls.count == 3 && $0.running == 0 } }
        cache.prefetch([url("bad"), url("c")], around: url("a"), maxPixelSize: 100)
        try? await Task.sleep(for: .milliseconds(50))
        let calls = fake.state.withLock { $0.fullCalls }
        #expect(calls == [url("a"), url("bad"), url("c")])

        // Стал текущим — пробуем ещё раз (ошибка могла быть временной).
        let recorder = Recorder()
        cache.request(url("bad"), maxPixelSize: 100) { recorder.record($0) }
        await waitUntil { !recorder.updates.isEmpty }
        #expect(recorder.updates == ["failed"])
        #expect(fake.state.withLock { $0.fullCalls.count } == 4)
    }

    // Другой экран — другой размер декодирования.
    @Test func differentScreenSizeReloads() async {
        let fake = FakeLoader()
        let cache = ImageCache(loader: fake.loader)
        let first = Recorder()
        cache.request(url("a"), maxPixelSize: 100) { first.record($0) }
        await waitUntil { first.isFinal }
        let again = Recorder()
        cache.request(url("a"), maxPixelSize: 200) { again.record($0) }
        #expect(again.updates.isEmpty)
        await waitUntil { again.isFinal }
        #expect(fake.state.withLock { $0.fullCalls.count } == 2)
    }

    @Test func clearCancelsEverything() async {
        let fake = FakeLoader(delay: .seconds(5))
        let cache = ImageCache(loader: fake.loader)
        let recorder = Recorder()
        cache.request(url("a"), maxPixelSize: 100) { recorder.record($0) }
        await waitUntil { fake.state.withLock { $0.running == 1 } }
        cache.clear()
        #expect(cache.count == 0)
        await waitUntil { fake.state.withLock { $0.running == 0 } }
        #expect(fake.state.withLock { $0.running } == 0)
        #expect(recorder.updates.isEmpty)
    }
}
