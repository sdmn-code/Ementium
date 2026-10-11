// RawProbe — замеры декодирования RAW (и любых картинок) так, как это делает Ementium.
//
//   swift raw.swift файл…            — каждый файл: размер, превью, время показа и полного декодирования
//
// Разрешения не нужны. Одноразовый исследовательский код, в приложение не переносится.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func ms(_ start: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6 }

/// Как `ImageLoader.load`: уменьшенная копия из оригинала (не из встроенного превью).
func decode(_ source: CGImageSource, maxPixelSize: Int, fromImageAlways: Bool) -> (CGImage?, Double) {
    var options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    options[fromImageAlways ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
    let start = DispatchTime.now()
    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    return (image, ms(start))
}

let screenLongSide = 3420  // MacBook Air 15": 1710 пунктов × 2

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    print("\n== \(url.lastPathComponent)")
    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    print("тип: \(type?.identifier ?? "?"), изображение по UTType: \(type?.conforms(to: .image) ?? false), RAW: \(type?.conforms(to: .rawImage) ?? false)")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
        print("CGImageSource не создаётся — ImageIO этот файл не читает")
        continue
    }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    print("оригинал: \(width)×\(height) (\(String(format: "%.1f", Double(width * height) / 1e6)) Мп), ориентация \(orientation), файл \(size / 1_000_000) МБ, кадров \(CGImageSourceGetCount(source))")

    // Встроенное превью: «из оригинала только если превью нет» без ограничения размера отдаёт превью как есть.
    let (preview, previewMs) = decode(source, maxPixelSize: 100_000, fromImageAlways: false)
    print("встроенное превью: \(preview.map { "\($0.width)×\($0.height)" } ?? "нет") за \(String(format: "%.0f", previewMs)) мс")

    // Как сейчас в Ementium — под экран, из оригинала.
    let (screen, screenMs) = decode(source, maxPixelSize: screenLongSide, fromImageAlways: true)
    print("под экран (\(screenLongSide) px) из оригинала: \(screen.map { "\($0.width)×\($0.height)" } ?? "ошибка") за \(String(format: "%.0f", screenMs)) мс")

    // Полное разрешение — для увеличения.
    let (full, fullMs) = decode(source, maxPixelSize: max(width, height), fromImageAlways: true)
    let memory = full.map { $0.bytesPerRow * $0.height / 1_000_000 } ?? 0
    print("полное разрешение: \(full.map { "\($0.width)×\($0.height)" } ?? "ошибка") за \(String(format: "%.0f", fullMs)) мс, в памяти ~\(memory) МБ")
}
