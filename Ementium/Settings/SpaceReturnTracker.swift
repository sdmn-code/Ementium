import Foundation

/// Было ли окно настроек впереди, когда ушли с его рабочего стола: тогда по возвращении его поднимаем
/// (см. `SettingsWindowController.activeSpaceDidChange`). Уход сам снимает с Ementium активность, а с окна — фокус,
/// и уведомления об этом приходят и чуть раньше, и чуть позже уведомления об уходе: потерю в пределах `window`
/// от ухода считаем самим уходом. Решение фиксируется у ухода — что было на другом столе, его не меняет.
nonisolated struct SpaceReturnTracker {
    static let window: TimeInterval = 0.5

    /// Окно не на текущем рабочем столе.
    private(set) var isAway = false
    /// Окно было впереди, когда ушли.
    private(set) var wasFront = false
    private var leftAt: Date?
    private var lostAt: Date?

    /// Окно впереди на текущем столе (показали, подняли) — прежний уход забыт.
    mutating func shown() {
        isAway = false
        wasFront = false
        leftAt = nil
    }

    /// Ementium перестал быть впереди или окно — ключевым.
    mutating func lostFront(at time: Date) {
        lostAt = time
        if isAway, let leftAt, time >= leftAt, time.timeIntervalSince(leftAt) < Self.window { wasFront = true }
    }

    /// Ушли со стола окна; `isFront` — впереди ли оно сейчас. Уход дальше, со стола на стол, — тот же уход.
    mutating func left(at time: Date, isFront: Bool) {
        guard !isAway else { return }
        isAway = true
        leftAt = time
        let lostJustBefore = lostAt.map { time >= $0 && time.timeIntervalSince($0) < Self.window } ?? false
        wasFront = isFront || lostJustBefore
    }

    /// Вернулись на стол окна: поднимать ли его.
    mutating func returned() -> Bool {
        guard isAway else { return false }
        let raise = wasFront
        shown()
        return raise
    }
}
