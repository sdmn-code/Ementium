import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Сведения о снимке для карточки по `⌥`: файл и дата, камера и объектив, экспозиция, место съёмки.
/// Разбор — чистая функция над словарём свойств ImageIO (покрыта тестами); чтение файла — `read`.
nonisolated enum ImageMetadata {
    /// То, что известно о файле без чтения картинки.
    struct FileFacts: Equatable {
        var name: String
        var byteCount: Int?
        var modified: Date?
        /// «Изображение JPEG», «Изображение RAW Sony» — описание типа на языке системы.
        var typeDescription: String?
    }

    /// Читает свойства без декодирования картинки — миллисекунды. Обёртка для тестов; в приложении сведения
    /// читает сервис EmentiumDecoder (`read(_:file:)`).
    @concurrent
    static func read(_ url: URL) async -> [String] {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey])
        let facts = FileFacts(
            name: url.lastPathComponent,
            byteCount: values?.fileSize,
            modified: values?.contentModificationDate,
            typeDescription: values?.contentType?.localizedDescription
        )
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return lines(properties: [:], file: facts) }
        return read(data, type: values?.contentType, file: facts)
    }

    /// Строки карточки по данным файла: свойства ImageIO без декодирования картинки. Тип — подсказка
    /// для ImageIO (без неё RAW читается как TIFF).
    static func read(_ data: Data, type: UTType?, file: FileFacts) -> [String] {
        var properties: [String: Any] = [:]
        if let source = CGImageSourceCreateWithData(data as CFData, ImageLoader.sourceOptions(type) as CFDictionary),
           let copied = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            properties = copied
        }
        return lines(properties: properties, file: file)
    }

    /// Строки карточки. Нет поля — нет строки; нет EXIF вовсе (скриншот, SVG) — только файл и дата.
    static func lines(properties: [String: Any], file: FileFacts) -> [String] {
        let exif = dictionary(properties[kCGImagePropertyExifDictionary as String])
        let exifAux = dictionary(properties[kCGImagePropertyExifAuxDictionary as String])
        let tiff = dictionary(properties[kCGImagePropertyTIFFDictionary as String])
        let gps = dictionary(properties[kCGImagePropertyGPSDictionary as String])

        var lines = [file.name]

        if let taken = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap(exifDate) {
            lines.append(formatDate(taken, timeZone: utc))
        } else if let modified = file.modified {
            lines.append(formatDate(modified, timeZone: .current))
        }

        var format: [String] = []
        if let type = file.typeDescription { format.append(type) }
        if let size = pixelSize(properties) { format.append("\(size.width)×\(size.height)") }
        if !format.isEmpty { lines.append(format.joined(separator: " · ")) }
        if let bytes = file.byteCount { lines.append(fileSize(bytes)) }

        if let camera = camera(make: tiff[kCGImagePropertyTIFFMake as String] as? String,
                               model: tiff[kCGImagePropertyTIFFModel as String] as? String) {
            lines.append(camera)
        }
        let lens = clean(exifAux[kCGImagePropertyExifAuxLensModel as String] as? String)
            ?? clean(exif[kCGImagePropertyExifLensModel as String] as? String)
        if let lens { lines.append(lens) }

        var optics: [String] = []
        if let focal = number(exif[kCGImagePropertyExifFocalLength as String]), focal > 0 {
            optics.append("\(decimal(focal, digits: 1)) мм")
        }
        if let aperture = number(exif[kCGImagePropertyExifFNumber as String]), aperture > 0 {
            optics.append("ƒ/\(decimal(aperture, digits: 1))")
        }
        if let time = number(exif[kCGImagePropertyExifExposureTime as String]), time > 0 {
            optics.append(shutter(time))
        }
        if !optics.isEmpty { lines.append(optics.joined(separator: "  ")) }

        var exposure: [String] = []
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first.flatMap(number), iso > 0 {
            exposure.append("ISO \(Int(iso.rounded()))")
        }
        if let bias = number(exif[kCGImagePropertyExifExposureBiasValue as String]), abs(bias) >= 0.05 {
            exposure.append("\(bias > 0 ? "+" : "−")\(decimal(abs(bias), digits: 1)) EV")
        }
        if let flash = number(exif[kCGImagePropertyExifFlash as String]), Int(flash) & 1 == 1 {
            exposure.append("вспышка")
        }
        if !exposure.isEmpty { lines.append(exposure.joined(separator: "  ")) }

        if let place = coordinates(gps) { lines.append(place) }
        return lines
    }

    // MARK: - Поля

    /// Размер с учётом EXIF-поворота (ориентации 5–8 меняют стороны местами).
    private static func pixelSize(_ properties: [String: Any]) -> (width: Int, height: Int)? {
        guard let width = number(properties[kCGImagePropertyPixelWidth as String]),
              let height = number(properties[kCGImagePropertyPixelHeight as String]),
              width > 0, height > 0 else { return nil }
        let orientation = Int(number(properties[kCGImagePropertyOrientation as String]) ?? 1)
        return (5...8).contains(orientation) ? (Int(height), Int(width)) : (Int(width), Int(height))
    }

    /// «SONY ILCE-7M3», но «NIKON D750», а не «NIKON CORPORATION NIKON D750».
    static func camera(make: String?, model: String?) -> String? {
        let make = clean(make)
        guard let model = clean(model) else { return make }
        guard let make, let brand = make.split(separator: " ").first,
              !model.lowercased().hasPrefix(brand.lowercased()) else { return model }
        return "\(make) \(model)"
    }

    /// Короче секунды — «1/250 с»; дробная выдержка, не равная 1/n (0,4 с), и длинные — десятичной дробью.
    static func shutter(_ seconds: Double) -> String {
        if seconds < 1 {
            let denominator = 1 / seconds
            if abs(denominator - denominator.rounded()) <= denominator * 0.05 {
                return "1/\(Int(denominator.rounded())) с"
            }
        }
        return "\(decimal(seconds, digits: 1)) с"
    }

    static func fileSize(_ bytes: Int) -> String {
        if bytes < 1_000_000 { return "\(max(1, Int((Double(bytes) / 1000).rounded()))) КБ" }
        return "\(decimal(Double(bytes) / 1_000_000, digits: 1, trimZero: false)) МБ"
    }

    /// «55,7558° с. ш., 37,6173° в. д.» — только цифры, без карты и сети.
    private static func coordinates(_ gps: [String: Any]) -> String? {
        guard let latitude = number(gps[kCGImagePropertyGPSLatitude as String]),
              let longitude = number(gps[kCGImagePropertyGPSLongitude as String]) else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() == "W"
        return "\(decimal(latitude, digits: 4, trimZero: false))° \(south ? "ю. ш." : "с. ш."), "
            + "\(decimal(longitude, digits: 4, trimZero: false))° \(west ? "з. д." : "в. д.")"
    }

    // MARK: - Даты

    private static let utc = TimeZone(secondsFromGMT: 0)!

    /// Дата съёмки из EXIF («2025:10:12 14:32:05») — время, как записала камера, без перевода поясов.
    private static func exifDate(_ text: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = utc
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return parser.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)))
    }

    /// «12 октября 2025, 14:32». Дату съёмки показываем в поясе разбора (как записала камера),
    /// дату изменения файла — в поясе этого Mac, как в Finder.
    static func formatDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Числа

    private static func dictionary(_ value: Any?) -> [String: Any] {
        (value as? NSDictionary) as? [String: Any] ?? [:]
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let double as Double: double
        case let int as Int: Double(int)
        default: nil
        }
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Десятичная запятая; «,0» по умолчанию отбрасывается (ƒ/4, 35 мм).
    static func decimal(_ value: Double, digits: Int, trimZero: Bool = true) -> String {
        var text = String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
        if trimZero, text.contains(",") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(",") { text.removeLast() }
        }
        return text
    }
}
