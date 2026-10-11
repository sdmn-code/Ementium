import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Ementium

final class ImageLoaderTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmentiumLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Пишет настоящую картинку с заданными метаданными.
    private func makeImage(
        _ name: String, width: Int, height: Int, type: UTType = .jpeg,
        dpi: Double? = nil, orientation: Int? = nil
    ) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        var properties: [CFString: Any] = [:]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }

        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func plainImageKeepsItsSizeAndIsNotUpscaled() async throws {
        let url = try makeImage("plain.jpg", width: 200, height: 100)
        let loaded = try await ImageLoader.load(url, maxPixelSize: 5000)
        #expect(loaded.pointSize == CGSize(width: 200, height: 100))
        #expect(loaded.image.width == 200)
        #expect(loaded.image.height == 100)
    }

    @Test func exifRotationSwapsWidthAndHeight() async throws {
        let url = try makeImage("rotated.jpg", width: 200, height: 100, orientation: 6)
        let loaded = try await ImageLoader.load(url, maxPixelSize: 5000)
        #expect(loaded.pointSize == CGSize(width: 100, height: 200))
        // Поворот применён к самим пикселям.
        #expect(loaded.image.width == 100)
        #expect(loaded.image.height == 200)
    }

    @Test func retinaScreenshotIsShownAtHalfSize() async throws {
        let url = try makeImage("screenshot.png", width: 400, height: 200, type: .png, dpi: 144)
        let loaded = try await ImageLoader.load(url, maxPixelSize: 5000)
        #expect(loaded.pointSize == CGSize(width: 200, height: 100))
    }

    @Test(arguments: [72.0, 240, 300])
    func printDpiDoesNotShrinkPhotos(dpi: Double) async throws {
        let url = try makeImage("photo-\(Int(dpi)).jpg", width: 400, height: 200, dpi: dpi)
        let loaded = try await ImageLoader.load(url, maxPixelSize: 5000)
        #expect(loaded.pointSize == CGSize(width: 400, height: 200))
    }

    @Test func largeImageIsDecodedNoBiggerThanTheLimit() async throws {
        let url = try makeImage("large.jpg", width: 3000, height: 1500)
        let loaded = try await ImageLoader.load(url, maxPixelSize: 1000)
        #expect(max(loaded.image.width, loaded.image.height) == 1000)
        // Естественный размер — по оригиналу, а не по уменьшенной копии.
        #expect(loaded.pointSize == CGSize(width: 3000, height: 1500))
    }

    @Test(arguments: ["garbage", ""])
    func unreadableFileThrows(contents: String) async throws {
        let url = folder.appendingPathComponent("broken-\(contents.count).jpg")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        await #expect(throws: ImageLoaderError.self) {
            try await ImageLoader.load(url, maxPixelSize: 1000)
        }
    }

    @Test func cancelledLoadDoesNotDecode() async throws {
        let url = try makeImage("cancel.jpg", width: 200, height: 100)
        let task = Task { try await ImageLoader.load(url, maxPixelSize: 1000) }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func originalPixelSizeIsKeptWhenDecodedSmaller() async throws {
        let url = try makeImage("big.jpg", width: 3000, height: 1500)
        let loaded = try await ImageLoader.load(url, maxPixelSize: 1000)
        #expect(loaded.pixelSize == CGSize(width: 3000, height: 1500))
        #expect(loaded.decodedLongSide == 1000)
        #expect(loaded.originalLongSide == 3000)
    }

    @Test func originalPixelSizeFollowsRotation() async throws {
        let url = try makeImage("rotated-big.jpg", width: 200, height: 100, orientation: 6)
        let loaded = try await ImageLoader.load(url, maxPixelSize: 5000)
        #expect(loaded.pixelSize == CGSize(width: 100, height: 200))
    }

    // Быстрое превью — только для RAW: у JPEG встроенные превью крошечные, а сами они декодируются быстро.
    @Test func rawPreviewIsNotUsedForOrdinaryImages() async throws {
        let url = try makeImage("ordinary.jpg", width: 3000, height: 2000)
        #expect(await ImageLoader.loadRawPreview(url, maxPixelSize: 5000) == nil)
    }

    // Встроенного превью нет — ImageIO декодирует оригинал (на этом держится пропуск второго
    // декодирования RAW без превью в ViewerWindowController).
    @Test func embeddedPreviewFallsBackToTheOriginal() async throws {
        let url = try makeImage("no-preview.png", width: 2000, height: 1000, type: .png)
        let loaded = try await ImageLoader.load(url, maxPixelSize: 5000, embeddedPreviewOnly: true)
        #expect(loaded.decodedLongSide == 2000)
    }

    // Предел полного разрешения — ~100 Мп: 24 Мп целиком, 200 Мп уменьшаются в √2 раз по стороне.
    @Test func fullResolutionLimit() {
        #expect(ImageLoader.fullResolutionLimit(for: CGSize(width: 6000, height: 4000)) == 6000)
        let limit = ImageLoader.fullResolutionLimit(for: CGSize(width: 20000, height: 10000))
        #expect(abs(limit - 14142) <= 1)
    }

    @Test(arguments: [(144.0, 2.0), (216, 3), (72, 1), (300, 1), (143.5, 2)])
    func pixelsPerPoint(dpi: Double, expected: Double) {
        #expect(ImageLoader.pixelsPerPoint(dpi: dpi) == expected)
    }

    @Test func missingDpiMeansOnePixelPerPoint() {
        #expect(ImageLoader.pixelsPerPoint(dpi: nil) == 1)
    }
}
