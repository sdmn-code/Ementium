import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Декодированное изображение и размер, в котором его показывать.
nonisolated struct LoadedImage: @unchecked Sendable {
    let image: CGImage
    /// Естественный размер в пунктах экрана с учётом EXIF-поворота. Обычно 1 пиксель = 1 пункт;
    /// у Retina-снимков (144 и 216 dpi) — 2 и 3 пикселя на пункт, чтобы скриншот был размером с исходное окно.
    let pointSize: CGSize
    /// Размер оригинала в пикселях с учётом EXIF-поворота — чтобы при увеличении понять,
    /// есть ли смысл декодировать картинку заново в большем разрешении.
    let pixelSize: CGSize

    /// Сколько пикселей по длинной стороне декодировано сейчас.
    var decodedLongSide: Int { max(image.width, image.height) }
    var originalLongSide: Int { Int(max(pixelSize.width, pixelSize.height)) }
}

nonisolated enum ImageLoaderError: Error {
    case unreadable
}

nonisolated enum ImageLoader {
    /// Декодирует изображение не крупнее `maxPixelSize` по длинной стороне.
    ///
    /// Оригинал целиком в память не загружается: ImageIO сразу строит уменьшенную копию,
    /// поэтому большие фото и RAW не съедают память. Изображения меньше лимита
    /// декодируются в исходном размере.
    /// - Parameter embeddedPreviewOnly: предпочесть встроенное в файл превью. Если превью нет, ImageIO
    ///   всё равно декодирует оригинал (проверено тестом) — тогда результат просто полноразмерный.
    @concurrent
    static func load(_ url: URL, maxPixelSize: Int, embeddedPreviewOnly: Bool = false) async throws -> LoadedImage {
        // При быстром листании большинство загрузок отменяется — не начинаем и не доделываем лишнее.
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageLoaderError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longSide = max(pixelWidth, pixelHeight)
        try Task.checkCancellation()

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide > 0 ? min(longSide, maxPixelSize) : maxPixelSize,
        ]
        // Без флага «всегда из оригинала» ImageIO берёт встроенное превью, если оно есть.
        if !embeddedPreviewOnly {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoaderError.unreadable
        }
        try Task.checkCancellation()

        // Ориентации 5–8 поворачивают изображение на 90°: ширина и высота меняются местами.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        let width = pixelWidth > 0 ? pixelWidth : image.width
        let height = pixelHeight > 0 ? pixelHeight : image.height
        let scale = pixelsPerPoint(dpi: properties[kCGImagePropertyDPIWidth] as? Double)
        var size = CGSize(width: Double(width) / scale, height: Double(height) / scale)
        var pixels = CGSize(width: width, height: height)
        if rotated {
            size = CGSize(width: size.height, height: size.width)
            pixels = CGSize(width: pixels.height, height: pixels.width)
        }

        return LoadedImage(image: image, pointSize: size, pixelSize: pixels)
    }

    /// Встроенное превью RAW-файла — чтобы показать снимок сразу, пока сам RAW декодируется в фоне
    /// (0,4–0,6 с под экран для ARW, RW2, DNG; превью читается за ~10 мс — замеры `Prototypes/RawProbe`).
    /// `nil` — не RAW или превью меньше `minLongSide` (крошечное превью хуже короткого ожидания).
    @concurrent
    static func loadRawPreview(_ url: URL, maxPixelSize: Int, minLongSide: Int = 1000) async -> LoadedImage? {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              type.conforms(to: .rawImage),
              let preview = try? await load(url, maxPixelSize: maxPixelSize, embeddedPreviewOnly: true),
              preview.decodedLongSide >= minLongSide else { return nil }
        return preview
    }

    /// Предел для декодирования в полном разрешении: не больше ~100 Мп (около 400 МБ в памяти).
    /// Возвращает длинную сторону, до которой уменьшать оригинал.
    static func fullResolutionLimit(for pixelSize: CGSize, maxPixels: Double = 100_000_000) -> Int {
        let longSide = max(pixelSize.width, pixelSize.height)
        let area = Double(pixelSize.width * pixelSize.height)
        guard area > maxPixels else { return Int(longSide) }
        return Int((Double(longSide) * (maxPixels / area).squareRoot()).rounded(.down))
    }

    /// DPI учитывается только у Retina-снимков. Фото с 240 или 300 dpi после экспорта или скана
    /// иначе показывались бы маленьким прямоугольником посреди экрана.
    static func pixelsPerPoint(dpi: Double?) -> Double {
        guard let dpi else { return 1 }
        for factor in [2.0, 3.0] where abs(dpi - 72 * factor) < 1 {
            return factor
        }
        return 1
    }
}
