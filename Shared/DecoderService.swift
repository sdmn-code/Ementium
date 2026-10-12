import AppKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// Реализация сервиса декодирования EmentiumDecoder. Лежит в `Shared`, чтобы её можно было проверить
/// тестом через настоящее `NSXPCConnection` (анонимный слушатель внутри процесса); в приложении не вызывается.
///
/// Файл приходит открытым дескриптором, отображается в память (`mmap`), декодируется общим кодом
/// (`ImageLoader`, `ImageMetadata`) и уходит обратно `IOSurface`.
nonisolated final class DecoderService: NSObject, DecoderProtocol, @unchecked Sendable {
    /// Не больше трёх декодирований одновременно: при зажатой стрелке иначе десятки RAW по ~0,7 ГБ
    /// делили бы процессор с текущей картинкой.
    private static let maxConcurrent = 3
    /// Открытых анимаций — не больше, старые вытесняются (их токены просто перестают работать).
    private static let maxAnimations = 4

    private let queue = DispatchQueue(label: "Ementium.Decoder", qos: .userInitiated, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: maxConcurrent)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "decoder")

    private struct State: @unchecked Sendable {
        /// Отменённые приложением запросы: если ещё не начаты — не начинать.
        var cancelled: Set<Int> = []
        var animations: [Int: CGImageSource] = [:]
        var animationOrder: [Int] = []
    }

    func decode(
        _ file: FileHandle, type: String, maxPixelSize: Int, previewOnly: Bool, request: Int,
        reply: @escaping @Sendable (DecodedImage?, String?) -> Void
    ) {
        // Дескриптор — в память сразу: очередь может быть длинной, а держать открытые файлы незачем.
        let data = Self.mapped(file)
        queue.async { [self] in
            slots.wait()
            defer { slots.signal() }
            if state.withLock({ $0.cancelled.remove(request) != nil }) {
                reply(nil, "отменено")
                return
            }
            guard let data else {
                reply(nil, ImageLoaderError.noSource.stage)
                return
            }
            do {
                let loaded = try ImageLoader.decode(
                    data, type: UTType(type), maxPixelSize: maxPixelSize, embeddedPreviewOnly: previewOnly
                )
                guard let decoded = DecodedImage(loaded) else {
                    reply(nil, "IOSurface")
                    return
                }
                reply(decoded, nil)
            } catch {
                log.error("Не удалось декодировать: \(String(describing: error), privacy: .public)")
                reply(nil, (error as? ImageLoaderError)?.stage ?? String(describing: error))
            }
        }
    }

    func cancel(request: Int) {
        state.withLock { _ = $0.cancelled.insert(request) }
    }

    func openAnimation(_ file: FileHandle, reply: @escaping @Sendable (Int, Int, [Double]) -> Void) {
        let data = Self.mapped(file)
        queue.async { [self] in
            guard let data, let (source, frameCount, loopCount) = ImageLoader.animation(data) else {
                reply(0, 0, [])
                return
            }
            let delays = (0..<frameCount).map { index in
                ImageLoader.frameDelay(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:])
            }
            nonisolated(unsafe) let opened = source
            // Случайный токен: после перезапуска сервиса старый токен не совпадёт с чужим новым.
            let token = Int.random(in: 1...Int.max)
            state.withLockUnchecked { state in
                state.animations[token] = opened
                state.animationOrder.append(token)
                while state.animationOrder.count > Self.maxAnimations {
                    state.animations[state.animationOrder.removeFirst()] = nil
                }
            }
            reply(token, loopCount, delays)
        }
    }

    func frame(token: Int, index: Int, maxPixelSize: Int, reply: @escaping @Sendable (DecodedFrame?) -> Void) {
        queue.async { [state] in
            guard let source = state.withLockUnchecked({ $0.animations[token] }),
                  let frame = ImageLoader.frame(source, index: index, maxPixelSize: maxPixelSize),
                  let surface = SurfaceConverter.surface(from: frame.image) else {
                reply(nil)
                return
            }
            reply(DecodedFrame(surface: surface, delay: frame.delay))
        }
    }

    func closeAnimation(token: Int) {
        state.withLockUnchecked { state in
            state.animations[token] = nil
            state.animationOrder.removeAll { $0 == token }
        }
    }

    func metadata(
        _ file: FileHandle, type: String, name: String, byteCount: Int, modified: Date?, typeDescription: String?,
        reply: @escaping @Sendable ([String]) -> Void
    ) {
        let data = Self.mapped(file)
        queue.async {
            let facts = ImageMetadata.FileFacts(
                name: name, byteCount: byteCount >= 0 ? byteCount : nil, modified: modified, typeDescription: typeDescription
            )
            guard let data else {
                reply(ImageMetadata.lines(properties: [:], file: facts))
                return
            }
            reply(ImageMetadata.read(data, type: UTType(type), file: facts))
        }
    }

    func ping(reply: @escaping @Sendable () -> Void) {
        reply()
    }

    /// Содержимое переданного файла без копирования: `mmap` дескриптора (открывать файлы песочница не даёт).
    /// Дескриптор сразу закрывается — отображение от него не зависит.
    static func mapped(_ file: FileHandle) -> Data? {
        defer { try? file.close() }
        let descriptor = file.fileDescriptor
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return nil }
        let size = Int(info.st_size)
        guard let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), address != MAP_FAILED else { return nil }
        return Data(bytesNoCopy: address, count: size, deallocator: .custom { pointer, count in munmap(pointer, count) })
    }
}
