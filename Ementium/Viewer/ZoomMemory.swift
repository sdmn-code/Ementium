import CoreGraphics
import Foundation

/// Как поставить новую картинку в окне просмотра.
nonisolated enum ZoomPlacement: Equatable {
    /// «Вписать».
    case fit
    /// Вернулись к картинке, которую увеличивали: её масштаб и место.
    case restore(scale: CGFloat, offset: CGPoint)
}

/// Масштаб и место каждой картинки, которую увеличивали, — на время сеанса просмотра (до `Esc`).
/// Настройка «Запоминать масштаб каждой картинки»; выключена — всё открывается во «вписать».
/// Масштаб считается от естественного размера, сдвиг — в пунктах экрана, поэтому запись верна
/// и для превью RAW, и для полной версии, и для оригинала в полном разрешении.
///
/// Переноса масштаба с одной картинки на следующую нет намеренно: вместе с памятью по файлам он делал
/// масштаб следующей картинки непредсказуемым (проверено в v0.5).
nonisolated struct ZoomMemory {
    private var states: [URL: (scale: CGFloat, offset: CGPoint)] = [:]
    var isEnabled = true {
        didSet { if !isEnabled { states.removeAll() } }
    }

    var count: Int { states.count }

    /// Уходим с картинки: увеличенную запоминаем, а во «вписать» — забываем (вернули её вручную).
    mutating func remember(_ zoom: ZoomModel, for url: URL) {
        guard isEnabled else { return }
        states[url] = zoom.isFit ? nil : (zoom.scale, zoom.offset)
    }

    func placement(for url: URL) -> ZoomPlacement {
        guard isEnabled, let state = states[url] else { return .fit }
        return .restore(scale: state.scale, offset: state.offset)
    }

    mutating func forget() {
        states.removeAll()
    }
}
