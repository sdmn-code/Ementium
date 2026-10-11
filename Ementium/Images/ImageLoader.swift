import CoreGraphics
import Foundation
import ImageIO

/// Декодированное изображение и размер, в котором его показывать.
nonisolated struct LoadedImage: @unchecked Sendable {
    let image: CGImage
    /// Естественный размер в пунктах экрана с учётом EXIF-поворота. Обычно 1 пиксель = 1 пункт;
    /// у Retina-снимков (144 и 216 dpi) — 2 и 3 пикселя на пункт, чтобы скриншот был размером с исходное окно.
    let pointSize: CGSize
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
    @concurrent
    static func load(_ url: URL, maxPixelSize: Int) async throws -> LoadedImage {
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

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide > 0 ? min(longSide, maxPixelSize) : maxPixelSize,
        ]
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
        if rotated { size = CGSize(width: size.height, height: size.width) }

        return LoadedImage(image: image, pointSize: size)
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
