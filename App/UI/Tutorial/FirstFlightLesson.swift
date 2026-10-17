import Foundation
import OrbitPhysics

/// Шаги урока «Первый полёт» по порядку. Пороги — из `AscentGuide`, шаги совпадают с `MissionChecklist`.
enum LessonStep: Int, CaseIterable, Sendable {
    case intro, throttleMax, launch, vertical, turn, follow, separate
    case apoapsisCut, openMap, circularize, execute, finish

    /// Тангаж, до которого игрок разворачивает нос на шаге «разворот», град.
    static let turnPitch = 80.0
    /// Высота окончания шага «следовать метке», м.
    static let followAltitude = 10_000.0
    /// Отклонение носа от целевого тангажа, град, и время, с, после которых шаг считается ошибочным.
    static let pitchLimit = 15.0
    static let pitchTime = 3.0
    /// Порог «тяга выставлена»: доля шкалы.
    static let throttleHigh = 0.95
    static let throttleLow = 0.05

    var kind: LessonKind {
        switch self {
        case .intro, .finish: .pause
        case .vertical, .follow: .live
        default: .wait
        }
    }

    /// Где идёт шаг: скругление — на карте, прочие — в полёте.
    var screen: LessonScreen {
        switch self {
        case .circularize, .execute: .map
        case .openMap, .finish: .any
        default: .flight
        }
    }

    /// «Шаг N из M»: вводный и итоговый шаги не считаются.
    static var numberedCount: Int { allCases.count - 2 }

    /// Подсвечиваемый элемент в фазе ожидания действия.
    var target: LessonElement? {
        switch self {
        case .intro: .mission
        case .throttleMax, .apoapsisCut: .throttle
        case .launch, .separate: .stageButton
        case .turn: .dpadRight
        case .openMap: .mapButton
        case .circularize: .mapCircularize
        case .execute: .mapExecute
        default: nil
        }
    }

    /// Дополнительная рамка: «Ап 80 км» у высотомера рядом с тягой.
    var alsoTargets: [LessonElement] { self == .apoapsisCut ? [.apoapsis] : [] }

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
        case .execute: return i.autoBurn
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
        case .openMap: return i.mapOpen
        case .circularize: return t.maneuver != nil
        case .execute: return !i.autoBurn && Self.inOrbit(t)
        }
    }

    static func stageEmpty(_ t: FlightTelemetry) -> Bool {
        guard t.nextStageAction == .separate, let stage = t.stages.first else { return false }
        return stage.fuelCapacity > 0 && stage.fuelFraction < 0.01
    }

    /// Перицентр выше атмосферы Терры: орбита.
    static func inOrbit(_ t: FlightTelemetry) -> Bool {
        (t.orbit?.periapsisAltitude ?? -.infinity) > AscentGuide.spaceAltitude
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
                // Узел удалили до запуска автопрожига: снова «Скруглить орбиту».
                if step == .execute, gate(i) == nil, t.maneuver == nil {
                    step = .circularize
                    phase = Self.startPhase(step, t)
                    advanced = true
                    break
                }
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
        } else if step == .execute {
            if t.maneuver == nil, !i.autoBurn, !LessonStep.inOrbit(t) {
                fail("Манёвр не вывел на орбиту — повторите шаг")
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
                                text: "Выйти на орбиту 80 км. Шаги и прогресс — в строке сверху.", button: "Понятно",
                                why: "Орбита — это когда корабль летит вокруг Терры так быстро, что не падает.")
        case .throttleMax:
            return LessonBubble(title: "Тяга", text: "Нажмите MAX над шкалой ТЯГА или проведите по ней вверх до 100 %.", button: nil,
                                why: "Полная тяга нужна, чтобы оторваться от площадки и набрать скорость.")
        case .launch:
            return LessonBubble(title: "Пуск", text: "Нажмите ПУСК — двигатели запустятся.", button: nil,
                                why: "Пока двигатели не зажжены, ракета стоит на месте.")
        case .turn:
            return LessonBubble(title: "Разворот на восток",
                                text: "Отведите джойстик «Направление» вправо и держите, пока тангаж не станет \(Int(Self.turnPitch))°.", button: nil,
                                why: "Орбита — это не высота, а скорость вбок. Чем раньше нос уходит к востоку, тем лучше разгон.")
        case .separate:
            return LessonBubble(title: "Топливо кончилось",
                                text: "Нижняя ступень пуста. Нажмите ОТДЕЛИТЬ.", button: nil,
                                why: "Пустая ступень — лишний вес. Без неё верхняя ступень разгоняется лучше.")
        case .apoapsisCut:
            let now = HUDFormat.distance(t.altitude)
            return LessonBubble(title: "Тяга 0",
                                text: "Сейчас \(now). Двигатель уже разогнал ракету — дальше она сама долетит до 80 км (Ап). Опустите тягу до 0.",
                                button: nil,
                                why: "Ап — высшая точка полёта. Она уже 80 км, топливо больше не жжём: оно нужно для выхода на орбиту.")
        case .openMap:
            return LessonBubble(title: "Карта", text: "Нажмите кнопку «Карта» справа вверху.", button: nil,
                                why: "Орбиту планируют на карте: там видна траектория и точка, где включать двигатель.")
        case .circularize:
            return LessonBubble(title: "Скруглить орбиту", text: "Нажмите «Скруглить орбиту» слева.", button: nil,
                                why: "Сейчас ракета летит по дуге и упадёт обратно. Игра поставит узел в высшей точке — там нужно добавить скорость вбок.")
        case .execute:
            return LessonBubble(title: "Выполнить манёвр", text: "Нажмите «Выполнить манёвр» справа.",
                                button: nil,
                                why: "Корабль сам долетит до узла, развернётся и включит двигатель на нужное время.")
        case .finish:
            let apo = HUDFormat.distance(t.orbit?.apoapsisAltitude)
            let peri = HUDFormat.distance(t.orbit?.periapsisAltitude)
            return LessonBubble(title: "Вы на орбите!", text: "Ап \(apo), Пе \(peri). Урок пройден.", button: "В ангар")
        case .vertical, .follow:
            return nil
        }
    }

    /// Живая плашка для шага в полёте (nil — плашки нет).
    func plate(_ i: LessonInput, phase: LessonPhase) -> LivePlate? {
        let t = i.telemetry
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
        case .execute:
            return LivePlate.burn(i)
        case .intro, .throttleMax, .launch, .openMap, .circularize, .finish:
            return nil
        }
    }
}

// MARK: - Протокол урока

extension FirstFlightLesson: TutorialLesson {
    var stepIndex: Int { step.rawValue }
    var reachedEnd: Bool { step == .finish }
    var isClosed: Bool { false }
    /// Автопрожиг сам выбирает ускорение (в атмосфере — физическое ×4, выше — рельсы).
    var forcesRealTime: Bool { false }

    var progress: LessonProgress? {
        guard step != .intro, step != .finish else { return nil }
        return LessonProgress(step: step.rawValue, total: LessonStep.numberedCount)
    }

    @discardableResult
    mutating func acknowledge(_ i: LessonInput) -> Bool { acknowledge(i.telemetry) }

    /// Шагов «попробуйте» в этом уроке нет.
    @discardableResult
    mutating func skip(_ i: LessonInput) -> Bool { false }

    mutating func didRestore(_ i: LessonInput) { didRestore(i.telemetry) }

    /// Шаг не на своём экране (карта вместо полёта и наоборот): попросить открыть или закрыть карту.
    func gate(_ i: LessonInput) -> LessonGate? {
        guard phase == .holding, step.kind != .pause else { return nil }
        switch step.screen {
        case .map: return i.mapOpen ? nil : .openMap
        case .flight: return i.mapOpen ? .closeMap : nil
        case .any: return nil
        }
    }

    func scene(_ i: LessonInput) -> LessonScene {
        let t = i.telemetry
        switch phase {
        case .holding:
            if let gate = gate(i) {
                return LessonScene(bubble: gate.bubble, target: gate.target, dims: true, passThrough: true,
                                   pausedTag: true)
            }
            var bubble = step.bubble(t)
            if step == .finish {
                bubble?.role = .hangar
                bubble?.exitTitle = "Остаться на орбите"
            }
            let waits = bubble?.button == nil
            return LessonScene(bubble: bubble, target: step.target, alsoTargets: step.alsoTargets, dims: true,
                               passThrough: waits, pausedTag: waits)
        case .ready:
            return LessonScene(bubble: .restart, dims: true)
        case .waiting, .running, .failed:
            return LessonScene(plateBar: true)
        }
    }

    func plate(_ i: LessonInput) -> LivePlate? {
        switch phase {
        case .running, .waiting: step.plate(i, phase: phase)
        case .holding, .ready, .failed: nil
        }
    }
}
