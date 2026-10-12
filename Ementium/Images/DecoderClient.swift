import Darwin
import Foundation
import IOSurface
import os
import UniformTypeIdentifiers

/// Связь с сервисом декодирования EmentiumDecoder (XPC, песочница без доступа к файлам и сети).
///
/// Приложение само файлы не разбирает: открывает их и передаёт дескриптор. Сервис упал — запрос повторяется
/// один раз на новом процессе; завис дольше 15 с — процесс сервиса убивается (настоящая отмена зависшего
/// декодера). После закрытия просмотра сервис отпускается и завершается — с кэшами декодеров.
final class DecoderClient {
    static let shared = DecoderClient()

    enum DecoderError: Error {
        /// Сервис не смог декодировать — строка с шагом для лога.
        case failed(String)
        /// Сервис упал или соединение порвалось.
        case serviceLost
        case timedOut
    }

    struct Animation: Sendable {
        let token: Int
        /// 0 — бесконечно.
        let loopCount: Int
        let delays: [Double]
        var frameCount: Int { delays.count }
    }

    private static let serviceName = "io.github.sdmn-code.EmentiumDecoder"
    private static let timeout = Duration.seconds(15)
    /// Сколько ждать после закрытия просмотра, прежде чем отпустить сервис (вдруг откроют снова).
    private static let idleRelease = Duration.seconds(10)

    private var connection: NSXPCConnection?
    private var releaseTask: Task<Void, Never>?
    private var nextRequest = 1
    /// Поднять свежий процесс сразу после отпускания — если Пробел вероятен (Finder активен).
    var shouldStayWarm: () -> Bool = { false }
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "decoder")

    // MARK: - Запросы

    func decode(_ url: URL, maxPixelSize: Int, previewOnly: Bool = false) async throws -> DecodedImage {
        try await withRetry {
            let (file, type) = try await Self.open(url)
            let request = self.makeRequestID()
            return try await self.call(onCancel: { proxy in proxy.cancel(request: request) }) { proxy, done in
                proxy.decode(file, type: type, maxPixelSize: maxPixelSize, previewOnly: previewOnly, request: request) { image, error in
                    _ = done(image.map { .success($0) } ?? .failure(DecoderError.failed(error ?? "?")))
                }
            }
        }
    }

    func openAnimation(_ url: URL) async throws -> Animation {
        try await withRetry {
            let (file, _) = try await Self.open(url)
            return try await self.call { proxy, done in
                proxy.openAnimation(file) { [weak self] token, loopCount, delays in
                    guard token > 0, delays.count > 1 else {
                        _ = done(.failure(DecoderError.failed("анимация")))
                        return
                    }
                    let animation = Animation(token: token, loopCount: loopCount, delays: delays.map(DecodedFrame.sane))
                    // Открылась, когда она уже не нужна (отмена, таймаут) — закрыть, иначе источник висит в сервисе.
                    if !done(.success(animation)) {
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.closeAnimation(animation) } }
                    }
                }
            }
        }
    }

    func frame(_ animation: Animation, index: Int, maxPixelSize: Int) async throws -> DecodedFrame {
        try await call { proxy, done in
            proxy.frame(token: animation.token, index: index, maxPixelSize: maxPixelSize) { frame in
                _ = done(frame.map { .success($0) } ?? .failure(DecoderError.failed("кадр")))
            }
        }
    }

    /// Только по живому соединению: поднимать процесс ради закрытия несуществующего токена незачем.
    func closeAnimation(_ animation: Animation) {
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? DecoderProtocol)?.closeAnimation(token: animation.token)
    }

    /// Строки карточки сведений о снимке. `nil` — сервис не ответил (такое не кэшировать).
    func metadata(_ url: URL) async -> [String]? {
        guard let facts = await Self.facts(url) else { return nil }
        return try? await withRetry {
            let (file, type) = try await Self.open(url)
            return try await self.call { proxy, done in
                proxy.metadata(
                    file, type: type, name: facts.name, byteCount: facts.byteCount ?? -1, modified: facts.modified,
                    typeDescription: facts.typeDescription
                ) { lines in _ = done(.success(lines)) }
            }
        }
    }

    // MARK: - Жизненный цикл

    /// Просмотр открыт — отложенное отпускание сервиса больше не нужно.
    func viewerOpened() {
        releaseTask?.cancel()
        releaseTask = nil
    }

    /// Поднять процесс заранее — чтобы холодный запуск не добавлялся к первому Пробелу. Отложенное
    /// отпускание не отменяет: процесс с кэшами всё равно уйдёт, а пустой поднимется следом.
    func warmUp() {
        guard connection == nil, releaseTask == nil else { return }
        let started = ContinuousClock.now
        (makeConnection().remoteObjectProxyWithErrorHandler { _ in } as? DecoderProtocol)?.ping { [log] in
            log.info("Сервис декодирования поднят за \(started.duration(to: .now), privacy: .public)")
        }
    }

    /// Просмотр закрыт: через некоторое время отпустить сервис — процесс завершится.
    func releaseSoon() {
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(for: Self.idleRelease)
            guard !Task.isCancelled else { return }
            invalidate(connection)
            // Старый процесс с кэшами декодеров уходит, новый — пустой и лёгкий — ждёт следующего Пробела.
            // Не сразу: пока старый процесс завершается, новое соединение попало бы в него и оборвалось.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            releaseTask = nil
            if connection == nil, shouldStayWarm() { warmUp() }
        }
    }

    private func invalidate(_ target: NSXPCConnection?) {
        guard let target else { return }
        target.invalidate()
        if connection === target { connection = nil }
    }

    private func makeRequestID() -> Int {
        nextRequest += 1
        return nextRequest
    }

    private func makeConnection() -> NSXPCConnection {
        let created = NSXPCConnection(serviceName: Self.serviceName)
        created.remoteObjectInterface = NSXPCInterface(with: (any DecoderProtocol).self)
        created.interruptionHandler = { [log] in
            log.error("Сервис декодирования прервался — следующий запрос поднимет его заново")
        }
        created.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self?.connection === created { self?.connection = nil }
                }
            }
        }
        created.resume()
        connection = created
        return created
    }

    // MARK: - Вызов с таймаутом

    /// Состояние одного вызова: ещё не отправлен, ждём ответа или уже завершён.
    private enum CallState<T> {
        case pending
        case waiting(CheckedContinuation<T, Error>)
        case done
    }

    /// Один вызов сервиса: ответ, ошибка соединения, таймаут или отмена — что раньше. `done` возвращает
    /// `false`, если ответ опоздал (вызов уже завершён), — так можно прибрать то, что сервис успел создать.
    private func call<T: Sendable>(
        onCancel: (@Sendable (DecoderProtocol) -> Void)? = nil,
        _ body: (DecoderProtocol, @escaping @Sendable (Result<T, Error>) -> Bool) -> Void
    ) async throws -> T {
        let state = OSAllocatedUnfairLock<CallState<T>>(uncheckedState: .pending)
        let finish: @Sendable (Result<T, Error>) -> Bool = { result in
            state.withLockUnchecked { current in
                switch current {
                case .waiting(let continuation):
                    continuation.resume(with: result)
                    current = .done
                    return true
                case .pending:
                    // Отмена раньше, чем вызов начался: запомнить, чтобы не отправлять.
                    if case .failure(let error) = result, error is CancellationError { current = .done }
                    return false
                case .done:
                    return false
                }
            }
        }
        let cancelHook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let timeoutTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
        defer { timeoutTask.withLock { $0?.cancel() } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let cancelledEarly = state.withLockUnchecked { current -> Bool in
                    if case .done = current { return true }
                    current = .waiting(continuation)
                    return false
                }
                if cancelledEarly {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let current = connection ?? makeConnection()
                guard let proxy = current.remoteObjectProxyWithErrorHandler({ _ in _ = finish(.failure(DecoderError.serviceLost)) })
                        as? DecoderProtocol else {
                    _ = finish(.failure(DecoderError.serviceLost))
                    return
                }
                if let onCancel {
                    nonisolated(unsafe) let target = proxy
                    cancelHook.withLock { $0 = { onCancel(target) } }
                }
                body(proxy, finish)
                // Завис — убиваем процесс сервиса: только так останавливается зависший декодер.
                let pid = current.processIdentifier
                let task = Task { [weak self] in
                    try? await Task.sleep(for: Self.timeout)
                    guard !Task.isCancelled else { return }
                    // Сначала таймаут (без повтора), потом обрыв — иначе ошибка соединения обогнала бы его.
                    guard finish(.failure(DecoderError.timedOut)) else { return }
                    self?.log.error("Сервис декодирования не ответил за \(Self.timeout, privacy: .public) — перезапуск")
                    if pid > 0 { kill(pid, SIGKILL) }
                    self?.invalidate(current)
                }
                timeoutTask.withLock { $0 = task }
            }
        } onCancel: {
            _ = finish(.failure(CancellationError()))
            // Сервису: ещё не начатый запрос не начинать.
            cancelHook.withLock { $0 }?()
        }
    }

    /// Сервис упал посреди запроса — один повтор на новом процессе.
    private func withRetry<T>(_ attempt: () async throws -> T) async throws -> T {
        do {
            return try await attempt()
        } catch DecoderError.serviceLost {
            try Task.checkCancellation()
            return try await attempt()
        }
    }

    /// Открыть файл для сервиса (вне главного потока: том может быть сетевым) и узнать тип по `UTType` —
    /// это не разбор содержимого.
    @concurrent
    private static func open(_ url: URL) async throws -> (FileHandle, String) {
        let handle = try FileHandle(forReadingFrom: url)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier ?? UTType.data.identifier
        return (handle, type)
    }

    /// Имя, размер, дата и описание типа — свойства файла, не содержимое; вне главного потока.
    @concurrent
    private static func facts(_ url: URL) async -> ImageMetadata.FileFacts? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey]) else {
            return nil
        }
        return ImageMetadata.FileFacts(
            name: url.lastPathComponent, byteCount: values.fileSize, modified: values.contentModificationDate,
            typeDescription: values.contentType?.localizedDescription
        )
    }
}
