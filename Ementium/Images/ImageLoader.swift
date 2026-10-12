import AppKit
import CoreGraphics
import CoreImage
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
    /// Векторная картинка (SVG): «естественного» размера у неё нет, она всегда вписывается в экран
    /// и перерисовывается чётко при увеличении.
    var isVector = false
    /// Анимация (GIF, APNG, WebP, HEICS, AVIF): здесь — первый кадр, остальные проигрывает `ImageAnimator`.
    var isAnimated = false

    /// Сколько пикселей по длинной стороне декодировано сейчас.
    var decodedLongSide: Int { max(image.width, image.height) }
    var originalLongSide: Int { Int(max(pixelSize.width, pixelSize.height)) }
}

nonisolated enum ImageLoaderError: Error {
    /// ImageIO не открыл файл.
    case noSource
    /// ImageIO открыл файл, но не смог его нарисовать (так было с SVG).
    case noImage
    /// `NSImage` не прочитал векторную картинку.
    case vectorUnreadable
    /// Файл iCloud не скачался за отведённое время.
    case notDownloaded

    var stage: String {
        switch self {
        case .noSource: "источник ImageIO"
        case .noImage: "декодирование ImageIO"
        case .vectorUnreadable: "SVG"
        case .notDownloaded: "скачивание из iCloud"
        }
    }
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
        // SVG — тоже `public.image`, но ImageIO его не рисует: источник создаётся, а картинки нет.
        if isVector(url) {
            return try loadVector(url, maxPixelSize: maxPixelSize)
        }
        if !embeddedPreviewOnly, isRaw(url), let raw = try loadRaw(url, maxPixelSize: maxPixelSize) {
            return raw
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageLoaderError.noSource
        }
        let animated = isAnimated(source)
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
            throw ImageLoaderError.noImage
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

        return LoadedImage(image: image, pointSize: size, pixelSize: pixels, isAnimated: animated)
    }

    /// Типы, которые ImageIO умеет анимировать (`CGAnimateImageAtURLWithBlock`). Тип — по ImageIO, а не по
    /// расширению: анимированный AVIF — это `.avif`, но ImageIO видит его как `public.avis`. Обычный HEIC
    /// с несколькими снимками (`public.heic`) — не анимация.
    static let animatableTypes: Set<String> = [
        "com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics", "public.avis",
    ]

    static func isAnimated(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 1, let type = CGImageSourceGetType(source) as String? else { return false }
        return animatableTypes.contains(type)
    }

    static func isRaw(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .rawImage) ?? false
    }

    /// RAW — через `CIRAWFilter` со своим контекстом CoreImage без кэша промежуточных результатов.
    /// Через ImageIO тот же RAW раздувал память до 2,6 ГБ на время декодирования и оставлял ~400 МБ
    /// в кэшах системы после; так — ~0,7 ГБ и ~40 МБ, и в 3–5 раз быстрее (на видеокарте).
    /// `nil` — `CIRAWFilter` файл не взял, тогда декодирует ImageIO.
    private static func loadRaw(_ url: URL, maxPixelSize: Int) throws -> LoadedImage? {
        guard let raw = CIRAWFilter(imageURL: url) else { return nil }
        let native = raw.nativeSize
        let longSide = max(native.width, native.height)
        guard longSide > 0 else { return nil }
        let scale = min(1, Double(maxPixelSize) / longSide)
        raw.scaleFactor = Float(scale)
        // Поворот по EXIF фильтр применяет сам.
        guard let image = raw.outputImage, image.extent.width > 0, image.extent.height > 0 else { return nil }
        try Task.checkCancellation()
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else {
            return nil
        }
        try Task.checkCancellation()
        // Размер оригинала с учётом поворота — по повёрнутому результату.
        let size = CGSize(width: (image.extent.width / scale).rounded(), height: (image.extent.height / scale).rounded())
        return LoadedImage(image: rendered, pointSize: size, pixelSize: size)
    }

    static func isVector(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .svg) ?? false
    }

    /// Во сколько раз векторную картинку можно увеличить относительно «вписать» без потери чёткости —
    /// столько же, сколько допускает масштаб (800 %).
    static let vectorDetailFactor: Double = 8

    /// SVG рисует `NSImage` (как вектор) в растр, у которого длинная сторона — `maxPixelSize`.
    /// `pointSize` — собственный размер SVG; вписывание в экран — забота `ViewerView`.
    private static func loadVector(_ url: URL, maxPixelSize: Int) throws -> LoadedImage {
        guard let vector = NSImage(contentsOf: url), vector.size.width > 0, vector.size.height > 0 else {
            throw ImageLoaderError.vectorUnreadable
        }
        let size = vector.size
        let ratio = Double(maxPixelSize) / max(size.width, size.height)
        let width = max(1, Int((size.width * ratio).rounded()))
        let height = max(1, Int((size.height * ratio).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw ImageLoaderError.vectorUnreadable }
        try Task.checkCancellation()
        // `NSGraphicsContext.current` — свой у каждого потока, рисовать в фоне можно.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        vector.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw ImageLoaderError.vectorUnreadable }
        try Task.checkCancellation()

        // «Оригинал» вектора — сколько угодно пикселей; ограничиваем пределом увеличения.
        let detail = Double(maxPixelSize) * vectorDetailFactor / max(size.width, size.height)
        return LoadedImage(
            image: image, pointSize: size,
            pixelSize: CGSize(width: size.width * detail, height: size.height * detail),
            isVector: true
        )
    }

    // MARK: - iCloud

    /// Файл iCloud без локальной копии: запросить скачивание и дождаться его (как делает Quick Look).
    /// Обычный файл — сразу. Отмена задачи прерывает ожидание.
    @concurrent
    static func ensureDownloaded(_ url: URL, timeout: Duration = .seconds(60)) async throws {
        guard needsDownload(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while needsDownload(url) {
            guard clock.now < deadline else { throw ImageLoaderError.notDownloaded }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Дата изменения файла — вне главного потока: том может быть сетевым и подвиснуть.
    @concurrent
    static func modificationDate(_ url: URL) async -> Date? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try? fresh.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// То же, что `needsDownload`, но вне главного потока: том может быть сетевым.
    @concurrent
    static func checkNeedsDownload(_ url: URL) async -> Bool {
        needsDownload(url)
    }

    static func needsDownload(_ url: URL) -> Bool {
        var fresh = url
        // Значения ресурсов кэшируются в самом URL — без сброса статус никогда не обновится.
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    // MARK: - Диагностика

    /// Что известно о файле, который не открылся, — без имени и пути (их пишем в лог отдельно, скрытыми).
    static func failureDescription(_ url: URL, error: Error) -> String {
        let keys: Set<URLResourceKey> = [
            .contentTypeKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .volumeIsLocalKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return failureDescription(
            fileExtension: url.pathExtension,
            typeIdentifier: values?.contentType?.identifier,
            fileSize: values?.fileSize,
            stage: (error as? ImageLoaderError)?.stage ?? String(describing: error),
            iCloudStatus: values?.isUbiquitousItem == true ? values?.ubiquitousItemDownloadingStatus?.rawValue : nil,
            isLocalVolume: values?.volumeIsLocal
        )
    }

    static func failureDescription(
        fileExtension: String, typeIdentifier: String?, fileSize: Int?, stage: String,
        iCloudStatus: String?, isLocalVolume: Bool?
    ) -> String {
        var parts = [
            "расширение: \(fileExtension.isEmpty ? "нет" : fileExtension.lowercased())",
            "тип: \(typeIdentifier ?? "неизвестен")",
            "размер: \(fileSize.map { "\($0) байт" } ?? "неизвестен")",
            "шаг: \(stage)",
        ]
        if let iCloudStatus { parts.append("iCloud: \(iCloudStatus)") }
        if isLocalVolume == false { parts.append("сетевой том") }
        return parts.joined(separator: ", ")
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
