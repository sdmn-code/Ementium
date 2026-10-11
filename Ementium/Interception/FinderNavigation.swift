import Foundation

/// Стрелка на клавиатуре (виртуальные коды клавиш macOS).
nonisolated enum ArrowKey: UInt16, Sendable {
    case left = 123
    case right = 124
    case down = 125
    case up = 126

    var isForward: Bool { self == .right || self == .down }

    var opposite: ArrowKey {
        switch self {
        case .left: .right
        case .right: .left
        case .down: .up
        case .up: .down
        }
    }
}

/// Вид окна Finder — от него зависит, какой стрелкой двигать выделение.
nonisolated enum FinderViewKind: Sendable, Equatable {
    case list, columns, icons, gallery, other

    /// Клавиша, которую получит Finder в ответ на стрелку пользователя.
    /// В списке и колонках вперёд — вниз; в галерее и значках — вправо (в значках путь через ряды
    /// прокладывает `IconGridPath`); на рабочем столе стрелки идут как есть — значки там расставлены вручную.
    func finderKey(for key: ArrowKey) -> ArrowKey {
        switch self {
        case .list, .columns: key.isForward ? .down : .up
        case .gallery, .icons: key.isForward ? .right : .left
        case .other: key
        }
    }
}

/// Путь по сетке значков: в «значках» Finder не переносит → на следующий ряд, поэтому к цели в другом
/// ряду идём стрелками по сетке. Горизонтальный отрезок — всегда по полному ряду: вниз — сначала по ряду,
/// потом вниз; вверх — сначала вверх, потом по ряду (последний ряд бывает короче, и → там упрётся в пустоту).
nonisolated enum IconGridPath {
    /// Порядок элементов на экране. Совпадение порядка AX с экранным не гарантировано (в прототипе
    /// первый на экране значок оказался в AX вторым), поэтому порядок восстанавливается по координатам:
    /// в значках — по рядам сверху вниз и слева направо, в галерее — слева направо.
    /// Элементы без координат — в конце.
    static func displayOrder(of positions: [CGPoint?], rowMajor: Bool) -> [Int] {
        positions.indices.sorted { a, b in
            guard let pa = positions[a], let pb = positions[b] else { return positions[a] != nil && positions[b] == nil }
            return rowMajor ? (pa.y, pa.x) < (pb.y, pb.x) : pa.x < pb.x
        }
    }

    /// - Parameters: координаты левого верхнего угла значков; `rowYs` и `colXs` — различные y и x всех
    ///   подгруженных значков. `nil`, если позиции не легли на сетку (значки расставлены вручную).
    static func keys(from start: CGPoint, to target: CGPoint, rowYs: [CGFloat], colXs: [CGFloat]) -> [ArrowKey]? {
        let rows = rowYs.sorted()
        let cols = colXs.sorted()
        guard let rowFrom = rows.firstIndex(of: start.y), let rowTo = rows.firstIndex(of: target.y),
              let colFrom = cols.firstIndex(of: start.x), let colTo = cols.firstIndex(of: target.x) else { return nil }
        let dRow = rowTo - rowFrom
        let dCol = colTo - colFrom
        let horizontal = Array(repeating: dCol > 0 ? ArrowKey.right : .left, count: abs(dCol))
        let vertical = Array(repeating: dRow > 0 ? ArrowKey.down : .up, count: abs(dRow))
        return dRow < 0 ? vertical + horizontal : horizontal + vertical
    }
}

/// Листание вслед за Finder: стрелки уходят в Finder, а просмотр показывает то, что он выделил.
///
/// Чистый автомат без обращений к системе: на входе — шаги пользователя, новые выделения Finder и
/// таймаут «Finder не сдвинулся», на выходе — какие клавиши отправить и какую картинку показать.
/// Не-изображения пропускаются: Ementium сам делает ещё шаг в ту же сторону. Если за краем списка
/// остались только не-изображения, выделение возвращается назад, пока Finder не встанет на картинку.
nonisolated struct FinderNavigation: Sendable {
    enum Output: Equatable {
        case send(ArrowKey)
        case show(URL)
        /// Долетели до последнего подгруженного элемента (не картинки) — Finder подгрузил следующие,
        /// пора снова искать картинку в эту сторону.
        case lookAgain(ArrowKey)
    }

    enum Mode: Equatable {
        case idle
        /// Листаем по шагам пользователя; не-изображения пропускаем в ту же сторону.
        case stepping(ArrowKey)
        /// Ушли за край по не-изображениям — шагаем обратно, пока Finder не встанет на картинку.
        case returning(ArrowKey)
        /// Отправили пачку стрелок до известной картинки: промежуточные документы не обрабатываем.
        case jumping(ArrowKey, target: URL)
    }

    /// Предел пропуска подряд — защита от бесконечного хождения по папке без картинок.
    static let maxSkips = 500

    private(set) var shown: URL
    private(set) var mode = Mode.idle
    private(set) var lastObserved: URL
    private(set) var lastObservedIsImage = true
    private var skipped = 0
    /// Просмотр закрыт: доводим выделение Finder до картинки и больше не листаем.
    private(set) var isFinishing = false

    /// Можно забыть автомат: просмотр закрыт и Finder стоит там, где нужно.
    var isDone: Bool { isFinishing && mode == .idle }

    var isJumping: Bool {
        if case .jumping = mode { return true }
        return false
    }

    /// Пачка стрелок до заранее найденного элемента (заглядывание по элементам вида). Обычно цель —
    /// картинка; если картинки среди подгруженных нет — последний подгруженный элемент, и по прилёте
    /// будет `.lookAgain`. `direction` — куда продолжать, если пачка не долетит.
    mutating func jump(_ keys: [ArrowKey], direction: ArrowKey, to target: URL) -> [Output] {
        guard !isFinishing, !keys.isEmpty else { return [] }
        mode = .jumping(direction, target: target)
        skipped = 0
        return keys.map(Output.send)
    }

    /// Впереди картинок нет — стоим на месте, Finder не трогаем.
    mutating func stay() {
        mode = .idle
    }

    init(showing url: URL) {
        shown = url
        lastObserved = url
    }

    /// Пользователь нажал стрелку. `key` — уже переведённая для текущего вида клавиша Finder.
    mutating func userStep(_ key: ArrowKey) -> [Output] {
        guard !isFinishing else { return [] }
        mode = .stepping(key)
        skipped = 0
        return [.send(key)]
    }

    /// Finder выделил один файл.
    mutating func selectionChanged(to url: URL, isImage: Bool) -> [Output] {
        // Повтор уведомления о том же выделении — не новый ответ Finder.
        guard url != lastObserved else { return [] }
        let cameFromNonImage = !lastObservedIsImage
        lastObserved = url
        lastObservedIsImage = isImage

        guard isImage else {
            switch mode {
            case .jumping(let key, let target) where url == target:
                // Долетели до последнего подгруженного: Finder прокрутил и подгрузил следующие.
                mode = .stepping(key)
                return [.lookAgain(key)]
            case .idle, .jumping:
                // В прыжке промежуточные документы ожидаемы — Finder сам дойдёт до цели.
                return []
            case .returning(let key):
                return [.send(key)]
            case .stepping(let key):
                skipped += 1
                guard skipped <= Self.maxSkips else {
                    mode = .returning(key.opposite)
                    return [.send(key.opposite)]
                }
                return [.send(key)]
            }
        }

        skipped = 0
        switch mode {
        case .returning:
            mode = .idle
        case .jumping(let key, _):
            // Долетели (или Finder встал на другую картинку) — дальше как после обычного шага.
            mode = .stepping(key)
        case .stepping(let key) where url == shown && cameFromNonImage && !isFinishing:
            // Шаг с хвоста не-изображений обратно на показанную картинку: пользователь хотел дальше.
            return [.send(key)]
        case .stepping, .idle:
            // Режим «шагаем» не сбрасываем: ответы на шаги, ещё «в полёте», тоже нужно обработать.
            // Его завершит таймаут.
            break
        }
        if isFinishing {
            mode = .idle
            return []
        }
        guard url != shown else { return [] }
        shown = url
        return [.show(url)]
    }

    /// Finder не сдвинулся в ответ на последний шаг — это край списка.
    mutating func timedOut() -> [Output] {
        switch mode {
        case .idle:
            return []
        case .returning:
            // Дальше вернуться некуда.
            mode = .idle
            return []
        case .stepping(let key):
            if lastObservedIsImage {
                mode = .idle
                return []
            }
            mode = .returning(key.opposite)
            return [.send(key.opposite)]
        case .jumping(let key, _):
            if lastObservedIsImage {
                mode = .idle
                return []
            }
            // Пачка не дошла до цели (часть стрелок потерялась) — дальше по одному шагу.
            mode = .stepping(key)
            return [.send(key)]
        }
    }

    /// Просмотр закрыт. Если Finder стоит на не-изображении — вернуть выделение на картинку,
    /// чтобы после Esc было выделено то, что пользователь видел последним.
    mutating func finish() -> [Output] {
        isFinishing = true
        guard !lastObservedIsImage else {
            mode = .idle
            return []
        }
        switch mode {
        case .idle:
            return []
        case .stepping(let key), .jumping(let key, _):
            mode = .returning(key.opposite)
            return [.send(key.opposite)]
        case .returning(let key):
            return [.send(key)]
        }
    }
}
