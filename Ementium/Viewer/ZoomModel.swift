import CoreGraphics
import Foundation

/// Масштаб и сдвиг картинки в окне просмотра. Чистая геометрия, без AppKit — покрыта тестами.
///
/// Масштаб считается от естественного размера картинки (`LoadedImage.pointSize`): 1 — это 100 %,
/// как «Реальный размер» в Просмотре. «Вписать» — большие картинки целиком в заданной доле экрана
/// (настройка «Размер изображения на экране», 95 %), маленькие — 100 % (или тоже до этой доли, если включено
/// «Увеличивать маленькие»). Меньше «вписать» не уменьшаем, больше 800 % (или «вписать», если оно больше)
/// не увеличиваем.
nonisolated struct ZoomModel: Equatable {
    /// Уровни для `+` / `-` и шаг «умного увеличения».
    static let levels: [CGFloat] = [0.5, 1, 2, 4, 8]
    static let maxScale: CGFloat = 8
    private static let epsilon: CGFloat = 0.001

    /// Естественный размер картинки в пунктах.
    private(set) var imageSize: CGSize
    /// Размер области просмотра.
    private(set) var viewSize: CGSize
    /// 1 = 100 %.
    private(set) var scale: CGFloat
    /// Сдвиг центра картинки от центра области, в пунктах экрана.
    private(set) var offset: CGPoint = .zero
    /// Доля области для «вписать» (0,5…1).
    private(set) var fitFraction: CGFloat
    /// Растягивать ли маленькие картинки до «вписать».
    private(set) var upscalesSmallImages: Bool

    init(imageSize: CGSize, viewSize: CGSize, fitFraction: CGFloat = 1, upscalesSmallImages: Bool = false) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.fitFraction = min(max(fitFraction, 0.1), 1)
        self.upscalesSmallImages = upscalesSmallImages
        scale = 1
        scale = fitScale
    }

    var fitScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return 1 }
        let fit = min(fitFraction * viewSize.width / imageSize.width, fitFraction * viewSize.height / imageSize.height)
        return upscalesSmallImages ? fit : min(1, fit)
    }

    /// Предел увеличения: 800 %, но не меньше «вписать» (крошечная картинка, растянутая на экран).
    var maximumScale: CGFloat { max(Self.maxScale, fitScale) }

    var isFit: Bool { abs(scale - fitScale) < Self.epsilon }

    /// Картинка больше области хотя бы по одной стороне — её можно двигать.
    var canPan: Bool {
        imageSize.width * scale > viewSize.width + 0.5 || imageSize.height * scale > viewSize.height + 0.5
    }

    /// Прямоугольник картинки в координатах области (начало — левый нижний угол, как у `NSView`).
    var imageRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let width = (imageSize.width * scale).rounded()
        let height = (imageSize.height * scale).rounded()
        return CGRect(
            x: ((viewSize.width - width) / 2 + offset.x).rounded(),
            y: ((viewSize.height - height) / 2 + offset.y).rounded(),
            width: width,
            height: height
        )
    }

    /// Масштаб для плашки: «Вписать» или проценты.
    var label: String {
        isFit ? String(localized: "Fit") : "\(Int((scale * 100).rounded())) %"
    }

    // MARK: - Изменения

    /// Следующий уровень больше текущего; якорь — точка, которая останется на месте (по умолчанию центр).
    mutating func zoomIn(around anchor: CGPoint? = nil) {
        let next = Self.levels.first { $0 > scale + Self.epsilon } ?? maximumScale
        setScale(next, around: anchor)
    }

    /// Предыдущий уровень меньше текущего, но не меньше «вписать».
    mutating func zoomOut(around anchor: CGPoint? = nil) {
        let previous = Self.levels.last { $0 < scale - Self.epsilon && $0 > fitScale + Self.epsilon }
        setScale(previous ?? fitScale, around: anchor)
    }

    mutating func zoomToFit() {
        scale = fitScale
        offset = .zero
    }

    /// «Умное увеличение» (двойное касание двумя пальцами, двойной клик): «вписать» ↔ 100 % в точке.
    /// Маленькой картинке, для которой «вписать» и есть 100 %, — 200 %.
    mutating func toggleSmartZoom(at anchor: CGPoint) {
        if isFit {
            setScale(fitScale < 1 - Self.epsilon ? 1 : 2, around: anchor)
        } else {
            zoomToFit()
        }
    }

    /// Жест сведения/разведения пальцев: `magnification` — приращение из `NSEvent` (0,1 = +10 %).
    mutating func magnify(by magnification: CGFloat, around anchor: CGPoint) {
        setScale(scale * (1 + magnification), around: anchor)
    }

    /// Сдвиг на `delta` пунктов; края увеличенной картинки не уходят внутрь области.
    mutating func pan(by delta: CGVector) {
        offset.x += delta.dx
        offset.y += delta.dy
        clampOffset()
    }

    /// Новая картинка — во «вписать» (свой запомненный масштаб ставит `restore`).
    mutating func replaceImage(size: CGSize) {
        imageSize = size
        offset = .zero
        scale = fitScale
    }

    /// Запомненные масштаб и сдвиг (вернулись к картинке) — в нынешних пределах и без ухода краёв внутрь.
    mutating func restore(scale newScale: CGFloat, offset newOffset: CGPoint) {
        scale = min(max(newScale, fitScale), maximumScale)
        offset = newOffset
        clampOffset()
    }

    /// Настройки «вписать» поменялись: «вписать» остаётся «вписать», остальное — в новых пределах.
    mutating func setFitOptions(fraction: CGFloat, upscalesSmallImages: Bool) {
        let wasFit = isFit
        fitFraction = min(max(fraction, 0.1), 1)
        self.upscalesSmallImages = upscalesSmallImages
        scale = wasFit ? fitScale : min(max(scale, fitScale), maximumScale)
        clampOffset()
    }

    /// Окно поменяло размер (другой экран): «вписать» остаётся «вписать», остальное — в пределах.
    mutating func resize(to size: CGSize) {
        let wasFit = isFit
        viewSize = size
        scale = wasFit ? fitScale : min(max(scale, fitScale), maximumScale)
        clampOffset()
    }

    /// Точка под якорем остаётся на месте: та же точка картинки до и после масштаба.
    private mutating func setScale(_ newScale: CGFloat, around anchor: CGPoint?) {
        let clamped = min(max(newScale, fitScale), maximumScale)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let anchor = anchor ?? center
        let ratio = clamped / scale
        offset = CGPoint(
            x: anchor.x - center.x - (anchor.x - center.x - offset.x) * ratio,
            y: anchor.y - center.y - (anchor.y - center.y - offset.y) * ratio
        )
        scale = clamped
        clampOffset()
    }

    private mutating func clampOffset() {
        let maxX = max(0, (imageSize.width * scale - viewSize.width) / 2)
        let maxY = max(0, (imageSize.height * scale - viewSize.height) / 2)
        offset.x = min(max(offset.x, -maxX), maxX)
        offset.y = min(max(offset.y, -maxY), maxY)
    }
}
