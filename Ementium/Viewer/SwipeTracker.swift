import CoreGraphics
import Foundation

/// Смахивание двумя пальцами по трекпаду во «вписать»: картинка едет за пальцами, при отпускании —
/// перелистнуть или вернуть. Чистая логика (покрыта тестами); вид только рисует `offset`.
///
/// Сдвиги — движение пальцев (вправо — положительное), уже с учётом «естественной прокрутки»:
/// пальцы влево — следующая картинка, как в Фото.
nonisolated struct SwipeTracker {
    enum Decision: Equatable {
        case next
        case previous
        /// Недотянули, передумали или листать некуда — вернуть на место.
        case cancel
    }

    /// Пока сдвиг меньше — направление не решено (вертикальная прокрутка смахиванием не считается).
    static let lockDistance: CGFloat = 8
    /// Перелистнуть, если протянули на 2 % ширины (~35 пт на экране MacBook)…
    static let distanceFraction: CGFloat = 0.02
    /// …или быстро взмахнули (пунктов в секунду) хотя бы на 12 пунктов. Подобрано по ощущениям Саши:
    /// четверть, 15 %, 6 %, 3 % ширины и 600, потом 350 пт/с — «долго вести пальцы».
    static let flickVelocity: CGFloat = 250
    static let flickDistance: CGFloat = 12
    /// На краю (листать некуда) картинка тянется туго — упругий отскок.
    static let edgeResistance: CGFloat = 0.25
    /// Скорость — по последним 0,05 с движения (трекпад шлёт события каждые 8–16 мс): длиннее — и рывок
    /// в конце тонул бы в медленном движении до него.
    static let velocityWindow: TimeInterval = 0.05

    private enum Lock {
        case undecided
        case horizontal
        case vertical
    }

    private let width: CGFloat
    private let canGoNext: Bool
    private let canGoPrevious: Bool
    private var lock = Lock.undecided
    private var raw: CGFloat = 0
    private var vertical: CGFloat = 0
    private var samples: [(time: TimeInterval, dx: CGFloat)] = []

    init(width: CGFloat, canGoNext: Bool, canGoPrevious: Bool) {
        self.width = max(width, 1)
        self.canGoNext = canGoNext
        self.canGoPrevious = canGoPrevious
    }

    /// Смахивание идёт (горизонтальное движение) — вид двигает картинку на `offset`.
    var isTracking: Bool { lock == .horizontal }
    /// Жест оказался вертикальным — не смахивание (для лога).
    var isVertical: Bool { lock == .vertical }

    /// Сдвиг картинки на экране: за пальцами, а там, где листать некуда, — с сопротивлением. Не больше
    /// ширины: при частых жестах macOS ускоряет прокрутку, и путь доходит до нескольких экранов —
    /// обе картинки улетели бы за край.
    var offset: CGFloat {
        guard lock == .horizontal else { return 0 }
        let blocked = (raw < 0 && !canGoNext) || (raw > 0 && !canGoPrevious)
        let shift = blocked ? raw * Self.edgeResistance : raw
        return min(max(shift, -width), width)
    }

    /// Пальцы сдвинулись на `dx`, `dy` (пункты) в момент `time`.
    mutating func move(dx: CGFloat, dy: CGFloat, time: TimeInterval) {
        guard lock != .vertical else { return }
        raw += dx
        vertical += dy
        if lock == .undecided, max(abs(raw), abs(vertical)) >= Self.lockDistance {
            lock = abs(raw) >= abs(vertical) ? .horizontal : .vertical
        }
        samples.append((time, dx))
        samples.removeAll { time - $0.time > Self.velocityWindow }
    }

    /// Сдвиг пальцев (для лога).
    var distance: CGFloat { raw }

    /// Скорость пальцев к моменту `time` (пт/с) и путь за последние `velocityWindow`. Окно не короче 20 мс:
    /// по одному замеру скорость вышла бы огромной.
    func motion(at time: TimeInterval) -> (velocity: CGFloat, recent: CGFloat) {
        let window = samples.filter { time - $0.time <= Self.velocityWindow }
        guard let first = window.first, let last = window.last else { return (0, 0) }
        let recent = window.reduce(0) { $0 + $1.dx }
        return (recent / CGFloat(max(last.time - first.time, 0.02)), recent)
    }

    /// Пальцы отпущены в момент `time`.
    func end(time: TimeInterval) -> Decision {
        guard lock == .horizontal else { return .cancel }
        let (velocity, recent) = motion(at: time)
        // В конце повели обратно — передумали, как в Фото: не листаем, даже если протянули далеко. Только если
        // пальцы правда прошли обратно — при отрыве от трекпада бывает рывок назад в пару пунктов.
        let backwards = (recent < 0) != (raw < 0) && abs(recent) >= Self.flickDistance
        if backwards, abs(velocity) >= Self.flickVelocity { return .cancel }
        let far = abs(raw) >= width * Self.distanceFraction
        let flick = abs(velocity) >= Self.flickVelocity && abs(raw) >= Self.flickDistance && (velocity < 0) == (raw < 0)
        guard far || flick else { return .cancel }
        if raw < 0 { return canGoNext ? .next : .cancel }
        return canGoPrevious ? .previous : .cancel
    }
}
