import Foundation

/// Слайд-шоу — `S` включает и выключает, Пробел — пауза. Чистый автомат; таймер, шаг и показ — у вызывающего.
///
/// - Отсчёт идёт от момента, когда картинка появилась на экране (`imageShown`): следующая ещё декодируется — ждём.
/// - Шаг слайд-шоу (`advance`) — дальше ждём новую картинку. Ручной шаг (стрелка, смахивание): новая картинка
///   уже декодируется — ждём её; неизвестно, сдвинулись ли (стрелка в режиме «следовать» на краю никуда не ведёт,
///   и ждать картинку было бы вечно), — отсчёт заново сразу и ещё раз, когда новая появится.
/// - Шагнуть не вышло (соседи ещё не прочитаны) — повтор через `retryDelay`.
/// - Пауза: таймера нет, дисплей может заснуть, по центру — ❚❚, пока паузу не снимут; продолжение — ▶ и полный
///   интервал заново.
/// - Выход (`S`, `Esc`) — ⏹; конец списка без зацикливания (`reachedEnd`) — ⏹ и плашка «Слайд-шоу закончено».
nonisolated struct SlideshowClock: Equatable {
    enum Output: Equatable {
        /// Отсчитать интервал до следующего шага (прежний отсчёт отменяется).
        case startTimer(Duration)
        case cancelTimer
        /// Перейти к следующей картинке (край и зацикливание решает вызывающий).
        case advance
        case message(Message)
        /// Значок по центру экрана.
        case indicator(Indicator)
        /// Не давать дисплею заснуть.
        case keepDisplayAwake(Bool)
        /// Режим включён или выключен: какие клавиши работают, точки меток.
        case active(Bool)
    }

    enum Message: Equatable {
        case finished
        /// Нажатие, которое в слайд-шоу не работает.
        case blocked
    }

    /// Значок по центру экрана: пауза висит, пока её не снимут; ▶ и ⏹ гаснут сами.
    enum Indicator: Equatable {
        case play
        case pause
        case stop
        case hidden
    }

    enum Phase: Equatable {
        case off
        /// Ждём, пока картинка появится на экране.
        case waiting
        case counting
        case paused
    }

    static let retryDelay = Duration.milliseconds(500)

    /// Плашка «не работает» — не чаще: зажатая клавиша или серия нажатий не должны мигать ею без конца.
    static let blockedMessageInterval: TimeInterval = 2

    var interval: Duration
    private(set) var phase = Phase.off
    private var lastBlockedMessage: Date?

    init(interval: Duration) {
        self.interval = interval
    }

    var isActive: Bool { phase != .off }

    /// `S` (выключить — ещё и `Esc`). Включить: картинка уже на экране — сразу отсчёт, иначе — когда появится.
    mutating func toggle(imageOnScreen: Bool) -> [Output] {
        guard phase == .off else { return stop(.stop, message: nil) }
        lastBlockedMessage = nil
        phase = imageOnScreen ? .counting : .waiting
        var outputs: [Output] = [.active(true), .keepDisplayAwake(true), .indicator(.play)]
        if imageOnScreen { outputs.append(.startTimer(interval)) }
        return outputs
    }

    /// Пробел.
    mutating func pauseToggle() -> [Output] {
        switch phase {
        case .off:
            return []
        case .waiting, .counting:
            phase = .paused
            return [.cancelTimer, .indicator(.pause), .keepDisplayAwake(false)]
        case .paused:
            phase = .counting
            return [.indicator(.play), .keepDisplayAwake(true), .startTimer(interval)]
        }
    }

    /// Картинка появилась на экране (своя или ручным шагом) — отсчёт с начала. На паузе ничего не меняется.
    mutating func imageShown() -> [Output] {
        switch phase {
        case .waiting, .counting:
            phase = .counting
            return [.startTimer(interval)]
        case .off, .paused:
            return []
        }
    }

    /// Стрелка или смахивание: прежний отсчёт не должен шагнуть следом за ручным шагом. `imagePending` — перешли,
    /// и новая картинка ещё декодируется: отсчёт — когда появится (долгий RAW не пропускается).
    mutating func manualStep(imagePending: Bool = false) -> [Output] {
        guard phase == .counting || phase == .waiting else { return [] }
        if imagePending {
            phase = .waiting
            return [.cancelTimer]
        }
        phase = .counting
        return [.startTimer(interval)]
    }

    mutating func timerFired() -> [Output] {
        guard phase == .counting else { return [] }
        phase = .waiting
        return [.advance]
    }

    /// Шаг не вышел (соседи ещё не известны, список строится) — попробовать снова чуть позже.
    mutating func advanceFailed() -> [Output] {
        guard phase == .waiting else { return [] }
        phase = .counting
        return [.startTimer(Self.retryDelay)]
    }

    /// Шагнуть некуда: последняя картинка, зацикливание выключено.
    mutating func reachedEnd() -> [Output] {
        guard phase != .off else { return [] }
        return stop(.stop, message: .finished)
    }

    /// Нажатие, которое в слайд-шоу не работает: плашка — не чаще раза в `blockedMessageInterval`.
    mutating func blocked(at now: Date) -> [Output] {
        guard phase != .off else { return [] }
        if let last = lastBlockedMessage, now.timeIntervalSince(last) < Self.blockedMessageInterval { return [] }
        lastBlockedMessage = now
        return [.message(.blocked)]
    }

    /// Просмотр закрывается.
    mutating func reset() -> [Output] {
        guard phase != .off else { return [] }
        return stop(.hidden, message: nil)
    }

    private mutating func stop(_ indicator: Indicator, message: Message?) -> [Output] {
        phase = .off
        var outputs: [Output] = [.cancelTimer, .keepDisplayAwake(false), .active(false), .indicator(indicator)]
        if let message { outputs.append(.message(message)) }
        return outputs
    }
}

/// Клавиша в слайд-шоу («свой список»; в режиме «следовать» то же решает `InterceptionPolicy.followingAction`).
nonisolated enum SlideshowKey: Equatable {
    case toggle
    case pause
    /// Стрелка — листать, как обычно.
    case navigate(ViewerCommand)
    /// Наша команда, которая в слайд-шоу не работает, — плашка.
    case blocked
    /// Не наша клавиша или автоповтор — ничего.
    case ignore

    static let spaceKeyCode: UInt16 = 49

    /// `command` — что клавиша делает вне слайд-шоу (`ViewerCommand(event:)`).
    static func resolve(_ command: ViewerCommand?, keyCode: UInt16, hasModifiers: Bool, isRepeat: Bool) -> SlideshowKey {
        // Пробел — пауза, что бы ни говорила настройка «Пробел закрывает просмотр».
        if keyCode == spaceKeyCode, !hasModifiers {
            return isRepeat ? .ignore : .pause
        }
        switch command {
        // `Esc` — выйти из слайд-шоу, как `S`; просмотр закрывает следующий `Esc`.
        case .slideshow?, .close?:
            return isRepeat ? .ignore : .toggle
        case let step? where step == .next || step == .previous:
            return .navigate(step)
        case nil:
            return .ignore
        default:
            return isRepeat ? .ignore : .blocked
        }
    }
}
