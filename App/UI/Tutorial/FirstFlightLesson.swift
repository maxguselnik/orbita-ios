import Foundation
import OrbitPhysics

/// Шаги урока «Первый полёт» по порядку. Пороги — из `AscentGuide`, шаги совпадают с `MissionChecklist`.
enum LessonStep: Int, CaseIterable, Sendable {
    case intro, throttleMax, launch, vertical, turn, follow, separate
    case apoapsisCut, warpToApoapsis, circularize, finish

    /// Тангаж, до которого игрок разворачивает нос на шаге «разворот», град.
    static let turnPitch = 80.0
    /// Высота окончания шага «следовать метке», м.
    static let followAltitude = 10_000.0
    /// Отклонение носа от целевого тангажа, град, и время, с, после которых шаг считается ошибочным.
    static let pitchLimit = 15.0
    static let pitchTime = 3.0
    /// Ап ниже этого значения на шаге скругления считается падением (с запасом от `cutoffApoapsis`), м.
    static let apoapsisFloor = AscentGuide.cutoffApoapsis - 5_000
    /// До апоцентра столько секунд — конец шага «лететь до Ап», с.
    static let apoapsisArrival = 30.0
    /// Порог «тяга выставлена»: доля шкалы.
    static let throttleHigh = 0.95
    static let throttleLow = 0.05

    var kind: LessonKind {
        switch self {
        case .intro, .finish: .pause
        case .vertical, .follow, .circularize: .live
        default: .wait
        }
    }

    /// Подсвечиваемый элемент в фазе ожидания действия.
    var target: LessonElement? {
        switch self {
        case .intro: .mission
        case .throttleMax, .apoapsisCut: .throttle
        case .launch, .separate: .stageButton
        case .turn: .dpadRight
        case .warpToApoapsis: .warp
        default: nil
        }
    }

    /// Следит ли шаг за отклонением носа от метки (фазы разворота и следования).
    var watchesPitch: Bool {
        switch self {
        case .turn, .follow, .separate, .apoapsisCut: true
        default: false
        }
    }

    /// Шаг начинается сразу; иначе (отделение, Ап 80 км) он сначала ждёт события в полёте.
    func isArmed(_ t: FlightTelemetry) -> Bool {
        switch self {
        case .separate: Self.stageEmpty(t)
        case .apoapsisCut: (t.orbit?.apoapsisAltitude ?? 0) >= AscentGuide.cutoffApoapsis
        default: true
        }
    }

    /// Игрок сделал нужное действие на шаге ожидания.
    func trigger(_ i: LessonInput) -> Bool {
        let t = i.telemetry
        switch self {
        case .throttleMax: return i.throttle >= Self.throttleHigh
        case .launch: return t.nextStageAction != .ignite
        case .turn: return i.yawRightHeld
        case .separate: return t.nextStageAction != .separate
        case .apoapsisCut: return i.throttle <= Self.throttleLow
        case .warpToApoapsis: return t.warpIndex > 0 || Self.arrivedAtApoapsis(t)
        default: return false
        }
    }

    /// Шаг выполнен, можно переходить к следующему.
    func isComplete(_ i: LessonInput) -> Bool {
        let t = i.telemetry
        switch self {
        case .intro, .finish: return false
        case .throttleMax, .launch: return trigger(i)
        // Над рельефом: площадка выше уровня моря (≈ 1.8 км), иначе шаг кончался бы сразу после отрыва.
        case .vertical: return t.mission.launched && t.heightAboveTerrain > AscentGuide.verticalLimit
        case .turn: return t.pitch * 180 / .pi <= Self.turnPitch
        case .follow: return t.altitude >= Self.followAltitude || Self.stageEmpty(t)
        case .separate: return trigger(i) || Self.apoapsis(t) >= AscentGuide.cutoffApoapsis
        case .apoapsisCut: return isArmed(t) && trigger(i)
        case .warpToApoapsis: return Self.arrivedAtApoapsis(t)
        case .circularize: return (t.orbit?.periapsisAltitude ?? -.infinity) > AscentGuide.spaceAltitude
        }
    }

    static func stageEmpty(_ t: FlightTelemetry) -> Bool {
        guard t.nextStageAction == .separate, let stage = t.stages.first else { return false }
        return stage.fuelCapacity > 0 && stage.fuelFraction < 0.01
    }

    static func arrivedAtApoapsis(_ t: FlightTelemetry) -> Bool {
        if let peri = t.orbit?.periapsisAltitude, peri > AscentGuide.spaceAltitude { return true }
        guard let toApo = t.orbit?.timeToApoapsis, toApo.isFinite else { return false }
        return toApo <= apoapsisArrival
    }

    static func apoapsis(_ t: FlightTelemetry) -> Double {
        t.orbit?.apoapsisAltitude ?? 0
    }

    /// Тангаж носа, град.
    static func pitchDegrees(_ t: FlightTelemetry) -> Double { t.pitch * 180 / .pi }
}

/// Чистая логика урока: шаг, фаза, счётчик ошибки. Без UI и без физики — всё через `LessonInput`.
struct FirstFlightLesson: Equatable {
    private(set) var step: LessonStep = .intro
    private(set) var phase: LessonPhase = .holding
    /// Сколько секунд нос подряд дальше `pitchLimit` от метки.
    private(set) var pitchErrorTime = 0.0
    private(set) var failure: String?
    private var phaseBeforeFailure: LessonPhase = .running

    /// Физика стоит: пауза-объяснение, ожидание действия, откат или ошибка.
    var holdsPhysics: Bool {
        phase == .holding || phase == .ready || phase == .failed
    }

    /// Первая фаза шага: ждущие шаги с условием начала — `waiting`, живые — `running`.
    static func startPhase(_ step: LessonStep, _ t: FlightTelemetry) -> LessonPhase {
        if !step.isArmed(t) { return .waiting }
        return step.kind == .live ? .running : .holding
    }

    /// Кнопка в пузыре: «Понятно» на знакомстве, «Поехали» после отката. Возвращает true, если шаг сменился.
    @discardableResult
    mutating func acknowledge(_ t: FlightTelemetry) -> Bool {
        if phase == .ready {
            phase = Self.startPhase(step, t)
            return false
        }
        guard step == .intro, phase == .holding else { return false }
        advance(t)
        return true
    }

    /// Кадр урока. Возвращает true, если шаг сменился (нужна контрольная точка).
    @discardableResult
    mutating func update(_ i: LessonInput, delta: Double) -> Bool {
        var advanced = false
        let t = i.telemetry
        for _ in 0..<LessonStep.allCases.count {
            guard step != .intro, step != .finish else { break }
            if phase == .waiting {
                if step.isComplete(i) { advance(t); advanced = true; continue }
                if step.isArmed(t) { phase = step.kind == .live ? .running : .holding; continue }
                checkFailure(i, delta: delta)
            } else if phase == .holding {
                if step.isComplete(i) { advance(t); advanced = true; continue }
                if step.trigger(i) { phase = .running }
            } else if phase == .running {
                if step.isComplete(i) { advance(t); advanced = true; continue }
                checkFailure(i, delta: delta)
            }
            break
        }
        return advanced
    }

    /// Шаг откатили: ошибка и таймер сброшены, ждём «Поехали» (живой/ждущий шаг) или действия (шаг-пауза).
    mutating func didRestore(_ t: FlightTelemetry) {
        pitchErrorTime = 0
        failure = nil
        let start = Self.startPhase(step, t)
        phase = (start == .holding) ? .holding : .ready
    }

    /// Нет контрольной точки: сбросить ошибку и продолжить как было.
    mutating func dismissFailure() {
        guard phase == .failed else { return }
        pitchErrorTime = 0
        failure = nil
        phase = phaseBeforeFailure
    }

    /// Начать урок заново.
    mutating func reset() {
        self = FirstFlightLesson()
    }

    private mutating func advance(_ t: FlightTelemetry) {
        if let next = LessonStep(rawValue: step.rawValue + 1) {
            step = next
            pitchErrorTime = 0
            phase = Self.startPhase(next, t)
        }
    }

    private mutating func checkFailure(_ i: LessonInput, delta: Double) {
        guard phase == .running || phase == .waiting else { return }
        let t = i.telemetry
        if step.watchesPitch {
            let target = AscentGuide.targetPitchDegrees(altitude: t.altitude, heightAboveTerrain: t.heightAboveTerrain)
            let error = abs(LessonStep.pitchDegrees(t) - target)
            if error > LessonStep.pitchLimit {
                pitchErrorTime += max(delta, 0)
            } else {
                pitchErrorTime = 0
            }
            if pitchErrorTime > LessonStep.pitchTime {
                fail("Нос ушёл на \(Int(error.rounded()))° от метки")
            }
        } else if step == .circularize {
            let apo = LessonStep.apoapsis(t)
            if t.orbit != nil, apo < LessonStep.apoapsisFloor {
                fail("Апоцентр падает: держите ПРОГРАДИЕНТ")
            }
        }
    }

    private mutating func fail(_ message: String) {
        phaseBeforeFailure = phase
        failure = message
        phase = .failed
    }
}

/// Тексты шагов: пузыри и живые плашки.
extension LessonStep {
    func bubble(_ t: FlightTelemetry) -> LessonBubble? {
        switch self {
        case .intro:
            return LessonBubble(title: "Цель урока",
                                text: "Выйти на орбиту 80 км. Шаги и прогресс — в карточке слева.", button: "Понятно")
        case .throttleMax:
            return LessonBubble(title: "Тяга", text: "Проведите пальцем по дуге вверх до MAX.", button: nil)
        case .launch:
            return LessonBubble(title: "Пуск", text: "Нажмите ПУСК — двигатели запустятся.", button: nil)
        case .turn:
            return LessonBubble(title: "Разворот на восток",
                                text: "Удерживайте ▶, пока тангаж не станет \(Int(Self.turnPitch))°.", button: nil)
        case .separate:
            return LessonBubble(title: "Топливо кончилось",
                                text: "Нижняя ступень пуста. Нажмите ОТДЕЛИТЬ.", button: nil)
        case .apoapsisCut:
            return LessonBubble(title: "Апоцентр 80 км",
                                text: "Высшая точка уже 80 км. Опустите тягу до 0.", button: nil)
        case .warpToApoapsis:
            let left = t.orbit?.timeToApoapsis.map { HUDFormat.countdown($0) } ?? HUDFormat.dash
            return LessonBubble(title: "Ускорение времени",
                                text: "До Ап \(left). Нажмите ▶▶, игра сама замедлится перед ним.", button: nil)
        case .finish:
            let apo = HUDFormat.distance(t.orbit?.apoapsisAltitude)
            let peri = HUDFormat.distance(t.orbit?.periapsisAltitude)
            return LessonBubble(title: "Вы на орбите!", text: "Ап \(apo), Пе \(peri). Урок пройден.", button: "В ангар")
        case .vertical, .follow, .circularize:
            return nil
        }
    }

    /// Живая плашка для шага в полёте (nil — плашки нет).
    func plate(_ t: FlightTelemetry, phase: LessonPhase) -> LivePlate? {
        let pitch = Int(Self.pitchDegrees(t).rounded())
        let target = Int(AscentGuide.targetPitchDegrees(altitude: t.altitude, heightAboveTerrain: t.heightAboveTerrain).rounded())
        switch self {
        case .vertical:
            return LivePlate(head: "Держите нос вверх · высота ", value: HUDFormat.distance(t.heightAboveTerrain),
                             tail: " из 1\(HUDFormat.thinSpace)000 м")
        case .turn:
            return LivePlate(head: "Тангаж ", value: "\(pitch)°", tail: " → цель \(Int(Self.turnPitch))°")
        case .follow:
            return LivePlate(head: "Держите нос у жёлтой метки · сейчас ", value: "\(pitch)°",
                             tail: " → цель \(target)°")
        case .separate:
            let fuel = Int(((t.stages.first?.fuelFraction ?? 0) * 100).rounded())
            return LivePlate(head: "Следуйте метке · топливо ступени ", value: "\(fuel)%")
        case .apoapsisCut:
            return LivePlate(head: "Следуйте метке · Ап ", value: HUDFormat.distance(t.orbit?.apoapsisAltitude),
                             tail: " → 80 км")
        case .warpToApoapsis:
            return LivePlate(head: "Летим до апоцентра · до Ап ",
                             value: HUDFormat.countdown(t.orbit?.timeToApoapsis))
        case .circularize:
            return LivePlate(head: "SAS «Прогрейд» и тяга MAX · Пе ",
                             value: HUDFormat.distance(t.orbit?.periapsisAltitude), tail: " → 70 км")
        case .intro, .throttleMax, .launch, .finish:
            return nil
        }
    }
}

// MARK: - Протокол урока

extension FirstFlightLesson: TutorialLesson {
    var stepIndex: Int { step.rawValue }
    var reachedEnd: Bool { step == .finish }
    var isClosed: Bool { false }
    /// К скруглению игра сама возвращается к ×1.
    var forcesRealTime: Bool { step == .circularize }

    @discardableResult
    mutating func acknowledge(_ i: LessonInput) -> Bool { acknowledge(i.telemetry) }

    /// Шагов «попробуйте» в этом уроке нет.
    @discardableResult
    mutating func skip(_ i: LessonInput) -> Bool { false }

    mutating func didRestore(_ i: LessonInput) { didRestore(i.telemetry) }

    func scene(_ i: LessonInput) -> LessonScene {
        let t = i.telemetry
        switch phase {
        case .holding:
            var bubble = step.bubble(t)
            if step == .finish {
                bubble?.role = .hangar
                bubble?.exitTitle = "Остаться на орбите"
            }
            let waits = bubble?.button == nil
            return LessonScene(bubble: bubble, target: step.target, dims: true, passThrough: waits, pausedTag: waits)
        case .ready:
            return LessonScene(bubble: .restart, dims: true)
        case .waiting, .running, .failed:
            return LessonScene(plateBar: true)
        }
    }

    func plate(_ i: LessonInput) -> LivePlate? {
        switch phase {
        case .running, .waiting: step.plate(i.telemetry, phase: phase)
        case .holding, .ready, .failed: nil
        }
    }
}
