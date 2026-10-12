import CoreGraphics
import Foundation
import IOSurface

/// Что умеет сервис декодирования EmentiumDecoder.
///
/// Основной процесс держит «Универсальный доступ» и перехват клавиатуры, поэтому содержимое файлов сам
/// не разбирает: он открывает файл и передаёт дескриптор, а декодирует сервис в песочнице без доступа
/// к файлам и сети. Картинки возвращаются как `IOSurface` — без копирования пикселей.
@objc(EMDecoderProtocol)
nonisolated protocol DecoderProtocol {
    /// Картинка не крупнее `maxPixelSize`; `previewOnly` — встроенное превью RAW. Ошибка — строка с шагом.
    /// `request` — номер для `cancel(request:)`.
    func decode(
        _ file: FileHandle, type: String, maxPixelSize: Int, previewOnly: Bool, request: Int,
        reply: @escaping @Sendable (DecodedImage?, String?) -> Void
    )

    /// Приложению запрос больше не нужен: ещё не начатый — не начинать.
    func cancel(request: Int)

    /// Открыть анимацию: токен для `frame` (0 — не анимация), сколько раз проиграть (0 — бесконечно)
    /// и задержки всех кадров.
    func openAnimation(_ file: FileHandle, reply: @escaping @Sendable (_ token: Int, _ loopCount: Int, _ delays: [Double]) -> Void)

    func frame(token: Int, index: Int, maxPixelSize: Int, reply: @escaping @Sendable (DecodedFrame?) -> Void)

    func closeAnimation(token: Int)

    /// Строки карточки сведений о снимке (`ImageMetadata`).
    func metadata(
        _ file: FileHandle, type: String, name: String, byteCount: Int, modified: Date?, typeDescription: String?,
        reply: @escaping @Sendable ([String]) -> Void
    )

    /// Пустой вызов — поднять процесс заранее.
    func ping(reply: @escaping @Sendable () -> Void)
}

/// Декодированная картинка, как её получает приложение: пиксели в `IOSurface` и размеры.
@objc(EMDecodedImage)
nonisolated final class DecodedImage: NSObject, NSSecureCoding, @unchecked Sendable {
    static let supportsSecureCoding = true

    let surface: IOSurface
    /// Естественный размер в пунктах (см. `LoadedImage.pointSize`).
    let pointSize: CGSize
    /// Размер оригинала в пикселях с учётом поворота.
    let pixelSize: CGSize
    let isVector: Bool
    let isAnimated: Bool

    init(surface: IOSurface, pointSize: CGSize, pixelSize: CGSize, isVector: Bool = false, isAnimated: Bool = false) {
        self.surface = surface
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        self.isVector = isVector
        self.isAnimated = isAnimated
    }

    /// Из картинки загрузчика — в сервисе (и в тестах).
    convenience init?(_ loaded: LoadedImage) {
        guard let surface = SurfaceConverter.surface(from: loaded.image) else { return nil }
        self.init(
            surface: surface, pointSize: loaded.pointSize, pixelSize: loaded.pixelSize,
            isVector: loaded.isVector, isAnimated: loaded.isAnimated
        )
    }

    /// Сколько пикселей по длинной стороне декодировано сейчас.
    var decodedLongSide: Int { max(surface.width, surface.height) }
    var originalLongSide: Int { Int(max(pixelSize.width, pixelSize.height)) }

    func encode(with coder: NSCoder) {
        coder.encode(surface, forKey: "surface")
        coder.encode(pointSize, forKey: "pointSize")
        coder.encode(pixelSize, forKey: "pixelSize")
        coder.encode(isVector, forKey: "isVector")
        coder.encode(isAnimated, forKey: "isAnimated")
    }

    /// Ответу сервиса не доверяем: декодер разбирает чужие файлы и теоретически может быть скомпрометирован.
    /// NaN или нулевой размер дошли бы до `ZoomModel` и `CALayer.frame` — и уронили бы процесс
    /// с «Универсальным доступом».
    init?(coder: NSCoder) {
        guard let surface = coder.decodeObject(of: IOSurface.self, forKey: "surface"),
              SurfaceConverter.isValid(surface) else { return nil }
        let pointSize = coder.decodeSize(forKey: "pointSize")
        let pixelSize = coder.decodeSize(forKey: "pixelSize")
        guard Self.isSane(pointSize), Self.isSane(pixelSize) else { return nil }
        self.surface = surface
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        isVector = coder.decodeBool(forKey: "isVector")
        isAnimated = coder.decodeBool(forKey: "isAnimated")
    }

    /// Конечный положительный размер не больше миллиона пунктов по стороне.
    static func isSane(_ size: CGSize) -> Bool {
        [size.width, size.height].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 1_000_000 }
    }
}

/// Кадр анимации и сколько его показывать.
@objc(EMDecodedFrame)
nonisolated final class DecodedFrame: NSObject, NSSecureCoding, @unchecked Sendable {
    static let supportsSecureCoding = true

    let surface: IOSurface
    let delay: Double

    init(surface: IOSurface, delay: Double) {
        self.surface = surface
        self.delay = delay
    }

    func encode(with coder: NSCoder) {
        coder.encode(surface, forKey: "surface")
        coder.encode(delay, forKey: "delay")
    }

    init?(coder: NSCoder) {
        guard let surface = coder.decodeObject(of: IOSurface.self, forKey: "surface"),
              SurfaceConverter.isValid(surface) else { return nil }
        self.surface = surface
        delay = Self.sane(coder.decodeDouble(forKey: "delay"))
    }

    /// Задержка — конечная, от 11 мс до минуты.
    static func sane(_ delay: Double) -> Double {
        delay.isFinite ? min(max(delay, 0.011), 60) : 0.1
    }
}

/// `CGImage` → `IOSurface` (BGRA, премножённая альфа) с цветовым пространством картинки: `CALayer`
/// показывает такую поверхность напрямую и учитывает её цветовое пространство.
nonisolated enum SurfaceConverter {
    static func surface(from image: CGImage) -> IOSurface? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: bytesPerRow,
            .pixelFormat: 0x4247_5241,  // 'BGRA'
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        // Цветное пространство картинки (Display P3 у RAW, профиль снимка у JPEG); серое и прочее — sRGB.
        let preferred = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        func context(_ space: CGColorSpace) -> CGContext? {
            CGContext(
                data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: surface.bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }
        // HDR-пространства (PQ, HLG, extended) 8-битный контекст может не принять — тогда sRGB.
        guard let (context, space) = context(preferred).map({ ($0, preferred) }) ?? context(sRGB).map({ ($0, sRGB) }) else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let plist = space.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist)
        }
        return surface
    }

    /// Предел стороны текстуры у видеокарты: больше `CALayer` поверхность может не показать.
    static let maxSide = 16384

    /// Поверхность в нашем формате и разумного размера — то, что пришло от сервиса, проверяется.
    static func isValid(_ surface: IOSurface) -> Bool {
        surface.width > 0 && surface.height > 0 && surface.width <= maxSide && surface.height <= maxSide
            && surface.pixelFormat == 0x4247_5241 && surface.bytesPerRow >= surface.width * 4
    }
}
