import Foundation

/// Декодированные картинки под экран: текущая и соседние (`PrefetchWindow`: 2 в сторону листания, 1 позади).
///
/// Текущая грузится сразу, соседние — по одной и только после того, как текущая готова, чтобы
/// не отнимать у неё процессор. Всё, что выпало из окна, отменяется и выбрасывается. Оригиналы
/// в полном разрешении (увеличение) сюда не попадают — ими занимается окно просмотра.
final class ImageCache {
    enum Update {
        /// Встроенное превью RAW — показать сразу, полная версия придёт следом.
        case preview(DecodedImage)
        /// Окончательная версия под экран.
        case final(DecodedImage)
        /// Не открылось. Если было превью, оно уже показано и остаётся.
        case failed(Error)
    }

    /// Чем декодировать — подменяется в тестах.
    nonisolated struct Loader: Sendable {
        var rawPreview: @Sendable (URL, Int) async -> DecodedImage?
        var full: @Sendable (URL, Int) async throws -> DecodedImage
        var ensureDownloaded: @Sendable (URL) async throws -> Void
        var needsDownload: @Sendable (URL) async -> Bool
        var modificationDate: @Sendable (URL) async -> Date?

        /// Декодирует сервис EmentiumDecoder; встроенное превью — только у RAW и только если оно не крошечное
        /// (крошечное превью хуже короткого ожидания полной версии).
        static let live = Loader(
            rawPreview: { url, size in
                guard ImageLoader.isRaw(url),
                      let preview = try? await DecoderClient.shared.decode(url, maxPixelSize: size, previewOnly: true),
                      preview.decodedLongSide >= 1000 else { return nil }
                return preview
            },
            full: { try await DecoderClient.shared.decode($0, maxPixelSize: $1) },
            ensureDownloaded: { try await ImageLoader.ensureDownloaded($0) },
            needsDownload: { await ImageLoader.checkNeedsDownload($0) },
            modificationDate: { await ImageLoader.modificationDate($0) }
        )
    }

    private final class Entry {
        let url: URL
        let maxPixelSize: Int
        /// Дата изменения файла перед декодированием: поменяли, пока смотрели, — запись устарела.
        var modified: Date?
        /// Предзагрузка не скачивает файлы из iCloud; текущая — скачивает.
        var isPrefetch: Bool
        var preview: DecodedImage?
        var final: DecodedImage?
        var error: Error?
        var task: Task<Void, Never>?
        var lastUsed: UInt64 = 0

        init(url: URL, maxPixelSize: Int, isPrefetch: Bool) {
            self.url = url
            self.maxPixelSize = maxPixelSize
            self.isPrefetch = isPrefetch
        }

        var isDone: Bool { final != nil || error != nil }
    }

    /// Текущая и 3 соседа, плюс одна про запас: в режиме «следовать» соседи приходят от Finder
    /// с задержкой, а прежние записи пока полезны (шаг назад).
    static let capacity = 5

    private let loader: Loader
    private var entries: [URL: Entry] = [:]
    /// Текущая картинка и кому сообщать о её загрузке.
    private var current: (url: URL, update: (Update) -> Void)?
    /// Текущая и соседи в порядке предзагрузки — то, что выбрасывать нельзя.
    private var window: [URL] = []
    private var queue: [(url: URL, maxPixelSize: Int)] = []
    private var prefetching: URL?
    private var useCounter: UInt64 = 0

    init(loader: Loader = .live) {
        self.loader = loader
    }

    /// Готовая картинка без запроса (для смахивания): окончательная или превью RAW, иначе `nil`.
    func image(for url: URL) -> DecodedImage? {
        entries[url]?.final ?? entries[url]?.preview
    }

    /// Число записей — для тестов.
    var count: Int { entries.count }
    func contains(_ url: URL) -> Bool { entries[url] != nil }

    // MARK: - Текущая картинка

    /// Показать `url`: что готово — отдаётся сразу (синхронно), остальное — по мере загрузки.
    /// Сообщения получает только последняя запрошенная картинка.
    func request(_ url: URL, maxPixelSize: Int, update: @escaping (Update) -> Void) {
        let previous = current?.url
        current = (url, update)
        if previous != url {
            // Очередь соседей прежней картинки больше не нужна — соседи новой придут через `prefetch`.
            queue.removeAll()
            // Прежняя текущая не успела декодироваться — отменяем, как раньше при быстром листании:
            // иначе при зажатой стрелке копились бы параллельные декодирования, и новая ждала бы их всех.
            if let previous, let old = entries[previous], !old.isDone {
                remove(old)
                window.removeAll { $0 == previous }
            }
        }
        if !window.contains(url) { window.insert(url, at: 0) }

        let entry: Entry
        if let existing = validEntry(url, maxPixelSize: maxPixelSize) {
            entry = existing
            // Предзагрузка этой картинки ещё идёт — теперь она текущая (и iCloud ей можно скачивать).
            entry.isPrefetch = false
        } else {
            entry = start(url, maxPixelSize: maxPixelSize, isPrefetch: false)
        }
        touch(entry)
        trim()

        if let final = entry.final {
            update(.final(final))
            revalidate(entry)
            startNextPrefetch()
        } else if let preview = entry.preview {
            update(.preview(preview))
        }
    }

    // MARK: - Соседи

    /// Соседи текущей картинки `current` в порядке предзагрузки. Устаревший вызов (текущая уже другая)
    /// игнорируется.
    func prefetch(_ neighbors: [URL], around current: URL, maxPixelSize: Int) {
        guard self.current?.url == current else { return }
        let wanted = neighbors.filter { $0 != current }
        window = [current] + wanted
        for (url, entry) in entries where !window.contains(url) {
            remove(entry)
        }
        for url in wanted {
            if let entry = entries[url], entry.maxPixelSize != maxPixelSize { remove(entry) }
        }
        // Упавшего соседа не повторяем, пока он в окне: битый файл на сетевом диске декодировался бы
        // заново на каждом шаге. Повтор — когда он станет текущим.
        queue = wanted.filter { entries[$0] == nil }.map { ($0, maxPixelSize) }
        startNextPrefetch()
    }

    /// Просмотр закрыт — всё отменить и освободить память.
    func clear() {
        for entry in entries.values { entry.task?.cancel() }
        entries.removeAll()
        current = nil
        window.removeAll()
        queue.removeAll()
        prefetching = nil
    }

    // MARK: - Загрузка

    private func validEntry(_ url: URL, maxPixelSize: Int) -> Entry? {
        guard let entry = entries[url] else { return nil }
        // Другой размер экрана или прошлая попытка не удалась (могла быть временной) — заново.
        guard entry.maxPixelSize == maxPixelSize, entry.final != nil || entry.error == nil else {
            remove(entry)
            return nil
        }
        return entry
    }

    @discardableResult
    private func start(_ url: URL, maxPixelSize: Int, isPrefetch: Bool) -> Entry {
        let entry = Entry(url: url, maxPixelSize: maxPixelSize, isPrefetch: isPrefetch)
        entries[url] = entry
        entry.task = Task { await self.run(entry) }
        return entry
    }

    /// Готовая картинка показана сразу; файл тем временем проверяем в фоне — его могли поменять.
    /// Поменяли — перечитываем и показываем заново.
    private func revalidate(_ entry: Entry) {
        Task {
            let modified = await loader.modificationDate(entry.url)
            guard isLive(entry), entry.isDone, modified != entry.modified else { return }
            let url = entry.url
            remove(entry)
            if let current, current.url == url {
                request(url, maxPixelSize: entry.maxPixelSize, update: current.update)
            }
        }
    }

    private func run(_ entry: Entry) async {
        guard !Task.isCancelled else { return }
        let url = entry.url
        let size = entry.maxPixelSize
        // Дата — до декодирования: если файл поменяют после, проверка это заметит.
        let modified = await loader.modificationDate(url)
        guard isLive(entry), !Task.isCancelled else { return }
        entry.modified = modified
        if entry.isPrefetch, await loader.needsDownload(url) {
            // Соседа в облаке не скачиваем; если он тем временем стал текущим — скачаем как текущий.
            guard isLive(entry), !Task.isCancelled else { return }
            if entry.isPrefetch {
                remove(entry)
                finishedPrefetch(url)
                return
            }
        }
        do {
            try await loader.ensureDownloaded(url)
        } catch {
            guard isLive(entry), !Task.isCancelled else { return }
            complete(entry, error: error)
            return
        }
        guard isLive(entry), !Task.isCancelled else { return }

        if let preview = await loader.rawPreview(url, size) {
            guard isLive(entry), !Task.isCancelled else { return }
            entry.preview = preview
            notify(entry, .preview(preview))
            // Превью уже не меньше нужного под экран (полноразмерное у Nikon) — второе декодирование не нужно.
            if preview.decodedLongSide >= min(preview.originalLongSide, size) {
                complete(entry, image: preview)
                return
            }
        }
        do {
            let image = try await loader.full(url, size)
            guard isLive(entry), !Task.isCancelled else { return }
            complete(entry, image: image)
        } catch {
            guard isLive(entry), !Task.isCancelled else { return }
            complete(entry, error: error)
        }
    }

    private func complete(_ entry: Entry, image: DecodedImage) {
        entry.final = image
        // Превью больше не нужно — не держим лишнюю картинку в памяти.
        entry.preview = nil
        entry.task = nil
        notify(entry, .final(image))
        finishedPrefetch(entry.url)
    }

    private func complete(_ entry: Entry, error: Error) {
        // Превью остаётся окончательной версией — лучше оно, чем ничего, и в следующий раз без ошибки.
        if let preview = entry.preview {
            entry.final = preview
            entry.preview = nil
        } else {
            entry.error = error
        }
        entry.task = nil
        notify(entry, .failed(error))
        finishedPrefetch(entry.url)
    }

    private func notify(_ entry: Entry, _ update: Update) {
        guard let current, current.url == entry.url else { return }
        current.update(update)
    }

    private func finishedPrefetch(_ url: URL) {
        if prefetching == url { prefetching = nil }
        startNextPrefetch()
    }

    /// Следующий сосед — по одному и только когда текущая уже готова.
    private func startNextPrefetch() {
        guard prefetching == nil else { return }
        if let url = current?.url, let entry = entries[url], !entry.isDone { return }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard window.contains(next.url), entries[next.url] == nil else { continue }
            prefetching = next.url
            let entry = start(next.url, maxPixelSize: next.maxPixelSize, isPrefetch: true)
            touch(entry)
            return
        }
    }

    // MARK: - Память

    private func isLive(_ entry: Entry) -> Bool { entries[entry.url] === entry }

    private func touch(_ entry: Entry) {
        useCounter += 1
        entry.lastUsed = useCounter
    }

    private func remove(_ entry: Entry) {
        guard isLive(entry) else { return }
        entry.task?.cancel()
        entries[entry.url] = nil
        if prefetching == entry.url { prefetching = nil }
    }

    /// Больше `capacity` записей — выбрасываем давно не нужные, сначала те, что вне окна. Текущую — никогда.
    private func trim() {
        while entries.count > Self.capacity {
            let candidates = entries.values.filter { $0.url != current?.url }
            let victim = candidates.filter { !window.contains($0.url) }.min { $0.lastUsed < $1.lastUsed }
                ?? candidates.min { $0.lastUsed < $1.lastUsed }
            guard let victim else { return }
            remove(victim)
            window.removeAll { $0 == victim.url }
        }
    }
}
