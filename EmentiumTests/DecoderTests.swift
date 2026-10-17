import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import Testing
@testable import Ementium

struct AnimationScheduleTests {
    // Бесконечная анимация: 1, 2, 0, 1, 2, 0… (кадр 0 уже показан).
    @Test func infiniteLoops() {
        var schedule = AnimationSchedule(frameCount: 3, loopCount: 0)
        let frames = (0..<7).compactMap { _ in schedule.advance() }
        #expect(frames == [1, 2, 0, 1, 2, 0, 1])
    }

    // Проиграть дважды — после второго прохода остаётся последний кадр.
    @Test func finiteLoopsStopOnLastFrame() {
        var schedule = AnimationSchedule(frameCount: 3, loopCount: 2)
        var frames: [Int] = []
        while let next = schedule.advance() { frames.append(next) }
        #expect(frames == [1, 2, 0, 1, 2])
    }

    @Test func singleFrameDoesNotAnimate() {
        var schedule = AnimationSchedule(frameCount: 1, loopCount: 0)
        #expect(schedule.advance() == nil)
    }
}

struct AnimationPropertiesTests {
    private func key(_ name: CFString) -> String { name as String }

    @Test func delaysPerFormat() {
        #expect(ImageLoader.frameDelay([key(kCGImagePropertyGIFDictionary): [key(kCGImagePropertyGIFUnclampedDelayTime): 0.04]]) == 0.04)
        #expect(ImageLoader.frameDelay([key(kCGImagePropertyWebPDictionary): [key(kCGImagePropertyWebPDelayTime): 0.07]]) == 0.07)
        // AVIF: ключи без своих констант (проверено на образцах).
        #expect(ImageLoader.frameDelay([key(kCGImagePropertyAVISDictionary): ["UnclampedDelayTime": 0.05, "DelayTime": 0.1]]) == 0.05)
    }

    // Нулевая задержка у старых GIF — 0,1 с, как в браузерах.
    @Test func tooShortDelayIsSlowedDown() {
        #expect(ImageLoader.frameDelay([key(kCGImagePropertyGIFDictionary): [key(kCGImagePropertyGIFDelayTime): 0.0]]) == 0.1)
        #expect(ImageLoader.frameDelay([:]) == 0.1)
    }

    @Test func loopCounts() {
        #expect(ImageLoader.loopCount([key(kCGImagePropertyPNGDictionary): [key(kCGImagePropertyAPNGLoopCount): 3]]) == 3)
        #expect(ImageLoader.loopCount([key(kCGImagePropertyAVISDictionary): ["LoopCount": 1]]) == 1)
        #expect(ImageLoader.loopCount([:]) == 0)
    }

    // Кадры и задержки из настоящего файла, разобранного из данных (как в сервисе).
    @Test func framesFromRealGif() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EmentiumAnim-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 3, nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 2],
        ] as CFDictionary)
        for index in 0..<3 {
            let context = try #require(CGContext(
                data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(red: Double(index) / 3, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))

        let data = try Data(contentsOf: url)
        let animation = try #require(ImageLoader.animation(data))
        #expect(animation.frameCount == 3)
        #expect(animation.loopCount == 2)
        let frame = try #require(ImageLoader.frame(animation.source, index: 1, maxPixelSize: 100))
        #expect(frame.image.width == 20)
        #expect(abs(frame.delay - 0.2) < 0.001)
    }
}

struct SurfaceConverterTests {
    // Пиксели и цветовое пространство доезжают до IOSurface (BGRA, премножённая альфа).
    @Test func pixelsAndColorSpace() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(
            data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let image = try #require(context.makeImage())
        let surface = try #require(SurfaceConverter.surface(from: image))
        #expect(surface.width == 4)
        #expect(surface.height == 2)
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let pixel = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        #expect([pixel[0], pixel[1], pixel[2], pixel[3]] == [0, 0, 255, 255])  // B, G, R, A
        let tagged = IOSurfaceCopyValue(surface, kIOSurfaceColorSpace)
        #expect(tagged != nil)
    }

    @Test func decodedImageKeepsSizes() throws {
        let context = try #require(CGContext(
            data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let loaded = LoadedImage(
            image: try #require(context.makeImage()), pointSize: CGSize(width: 300, height: 200),
            pixelSize: CGSize(width: 3000, height: 2000), isAnimated: true
        )
        let decoded = try #require(DecodedImage(loaded))
        #expect(decoded.decodedLongSide == 30)
        #expect(decoded.originalLongSide == 3000)
        #expect(decoded.pointSize == CGSize(width: 300, height: 200))
        #expect(decoded.isAnimated)
    }
}

/// Настоящее `NSXPCConnection` к `DecoderService` через анонимного слушателя внутри процесса — так проверяется
/// и кодирование ответов (`DecodedImage` с `IOSurface`, `DecodedFrame`), и передача дескриптора файла.
final class DecoderLoopbackTests: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let connection: NSXPCConnection
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmentiumXPC-\(UUID().uuidString)")

    override init() {
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        super.init()
        listener.delegate = self
        listener.resume()
        connection.remoteObjectInterface = NSXPCInterface(with: (any DecoderProtocol).self)
        connection.resume()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        connection.invalidate()
        listener.invalidate()
        try? FileManager.default.removeItem(at: folder)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: (any DecoderProtocol).self)
        newConnection.exportedObject = DecoderService()
        newConnection.resume()
        return true
    }

    private var proxy: DecoderProtocol {
        connection.remoteObjectProxyWithErrorHandler { error in Issue.record("XPC: \(error)") } as! DecoderProtocol
    }

    private func write(_ name: String, type: String, frames: Int, width: Int = 40, height: Int = 30) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil))
        for index in 0..<frames {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(red: Double(index) / Double(frames), green: 0.4, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.25],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func decodesThroughXPC() async throws {
        let url = try write("photo.jpg", type: "public.jpeg", frames: 1, width: 300, height: 200)
        let handle = try FileHandle(forReadingFrom: url)
        let result: (DecodedImage?, String?) = await withCheckedContinuation { continuation in
            proxy.decode(handle, type: "public.jpeg", maxPixelSize: 150, previewOnly: false, request: 1) { image, error in
                continuation.resume(returning: (image, error))
            }
        }
        let image = try #require(result.0, "ошибка: \(result.1 ?? "-")")
        #expect(image.surface.width == 150)
        #expect(image.surface.height == 100)
        #expect(image.pointSize == CGSize(width: 300, height: 200))
    }

    @Test func animationThroughXPC() async throws {
        let url = try write("anim.gif", type: "com.compuserve.gif", frames: 3)
        let handle = try FileHandle(forReadingFrom: url)
        let opened: (Int, Int, [Double]) = await withCheckedContinuation { continuation in
            proxy.openAnimation(handle) { token, loops, delays in continuation.resume(returning: (token, loops, delays)) }
        }
        #expect(opened.0 > 0)
        #expect(opened.2.count == 3)
        #expect(abs(opened.2[0] - 0.25) < 0.001)
        let frame: DecodedFrame? = await withCheckedContinuation { continuation in
            proxy.frame(token: opened.0, index: 2, maxPixelSize: 100) { continuation.resume(returning: $0) }
        }
        #expect(frame?.surface.width == 40)
        proxy.closeAnimation(token: opened.0)
        // Закрытый токен больше не работает.
        let closed: DecodedFrame? = await withCheckedContinuation { continuation in
            proxy.frame(token: opened.0, index: 1, maxPixelSize: 100) { continuation.resume(returning: $0) }
        }
        #expect(closed == nil)
    }

    // Отменённый до начала запрос сервис не декодирует.
    @Test func cancelledRequestIsSkipped() async throws {
        let url = try write("skip.jpg", type: "public.jpeg", frames: 1)
        let handle = try FileHandle(forReadingFrom: url)
        proxy.cancel(request: 77)
        let result: (DecodedImage?, String?) = await withCheckedContinuation { continuation in
            proxy.decode(handle, type: "public.jpeg", maxPixelSize: 100, previewOnly: false, request: 77) { image, error in
                continuation.resume(returning: (image, error))
            }
        }
        #expect(result.0 == nil)
        #expect(result.1 == "отменено")
    }
}

struct DecoderReplyValidationTests {
    @Test func saneSizes() {
        #expect(DecodedImage.isSane(CGSize(width: 100, height: 50)))
        #expect(!DecodedImage.isSane(CGSize(width: CGFloat.nan, height: 50)))
        #expect(!DecodedImage.isSane(CGSize(width: 0, height: 50)))
        #expect(!DecodedImage.isSane(CGSize(width: -1, height: 50)))
        #expect(!DecodedImage.isSane(CGSize(width: CGFloat.infinity, height: 50)))
        #expect(!DecodedImage.isSane(CGSize(width: 2_000_000, height: 50)))
    }

    @Test func saneDelays() {
        #expect(DecodedFrame.sane(0.05) == 0.05)
        #expect(DecodedFrame.sane(.nan) == 0.1)
        #expect(DecodedFrame.sane(0) == 0.011)
        #expect(DecodedFrame.sane(1e9) == 60)
    }

    // Панорама 30000×3000 — меньше 100 Мп, но сторона больше предела текстуры видеокарты.
    @Test func fullResolutionLimitRespectsTextureSize() {
        #expect(ImageLoader.fullResolutionLimit(for: CGSize(width: 30000, height: 3000)) == SurfaceConverter.maxSide)
    }
}

/// Граница процессов: код приложения (кроме `Shared`, который в приложении не вызывается) не разбирает
/// содержимое файлов — это делает только сервис в песочнице.
struct ProcessBoundaryTests {
    @Test func appDoesNotParseFileContents() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Ementium")
        let forbidden = [
            "CGImageSourceCreate", "CGAnimateImage", "CIRAWFilter", "NSImage(contentsOf", "NSImage(data",
            "ImageLoader.load(", "ImageLoader.decode(", "ImageMetadata.read(", "QLThumbnail",
            // Live Text — только по пикселям, уже декодированным сервисом.
            "analyze(imageAt",
        ]
        let files = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for call in forbidden where text.contains(call) {
                Issue.record("\(file.lastPathComponent) содержит \(call) — разбор файлов должен быть только в сервисе")
            }
        }
    }
}
