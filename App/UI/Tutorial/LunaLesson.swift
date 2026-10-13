import Foundation
import OrbitPhysics

/// Урок «Полёт к Луне»: корабль «Луна» уже на орбите Терры 80 км. Карта, узел «К Луне», подстройка ручкой,
/// «К узлу», SAS «УЗЕЛ», прожиг по остатку, перелёт, торможение у Луны, посадка.
typealias LunaLesson = ScriptLesson<LunaStep>

enum LunaStep: Int, CaseIterable, ScriptStep {
    case intro, openMap, mapIntro, lunaNode, encounter, tune, toNode, sasNode
    case burn, coast, brake, land, finish

    static var sequence: [LunaStep] { allCases }
    static var endsWithSummary: Bool { true }

    /// Пе у Луны, к которому подстраивают узел, м.
    static let periapsisRange = 20_000.0...40_000.0
    /// Шаг «К узлу» закончен, когда до начала прожига осталось столько секунд.
    static let burnArrival = ManeuverStatus.warpLead + 5
    /// Апоцентр у Луны, ниже которого орбита считается пойманной, м.
    static let captureApoapsis = 100_000.0
    /// Порог «тяга 0».
    static let throttleLow = 0.05
    /// Апоцентр у Терры, выше которого перелёт считается выполненным без узла (узел удалили после прожига), м.
    static var transferApoapsis: Double { Bodies.luna.orbitRadius * 0.5 }

    var kind: LessonKind {
        switch self {
        case .intro, .mapIntro, .encounter, .finish: .pause
        case .burn, .brake, .land: .live
        case .openMap, .lunaNode, .tune, .toNode, .sasNode, .coast: .wait
        }
    }

    var screen: LessonScreen {
        switch self {
        case .intro: .flight
        case .mapIntro, .lunaNode, .encounter, .tune, .toNode, .sasNode: .map
        case .openMap, .burn, .coast, .brake, .land, .finish: .any
        }
    }

    var target: LessonElement? {
        switch self {
        case .intro, .finish: nil
        case .openMap: .mapButton
        case .mapIntro, .encounter: .mapSummary
        case .lunaNode: .mapLuna
        case .tune: .mapHandle
        case .toNode: .mapToNode
        case .sasNode: .mapSASNode
        case .burn, .land: .throttle
        case .coast: .warp
        case .brake: .sas
        }
    }

    /// Ручку тянут, глядя на линию и сводку: без затемнения, остальные ручки и «К Луне» доступны.
    var freeHands: Bool { self == .tune }
    var platesWhileHolding: Bool { self == .tune }

    func trigger(_ i: LessonInput, from start: LessonBaseline) -> Bool {
        switch self {
        case .toNode, .coast: i.telemetry.warpIndex > 0
        default: false
        }
    }

    func isComplete(_ i: LessonInput, from start: LessonBaseline) -> Bool {
        let t = i.telemetry
        switch self {
        case .intro, .mapIntro, .encounter, .finish:
            return false
        case .openMap:
            return i.mapOpen
        case .lunaNode:
            return t.maneuver != nil
        case .tune:
            return i.lunaPeriapsis.map { Self.periapsisRange.contains($0) } ?? false
        case .toNode:
            guard let m = t.maneuver else { return false }
            return m.timeToBurn <= Self.burnArrival
        case .sasNode:
            return t.sas == .maneuver
        case .burn:
            return i.throttle <= Self.throttleLow && Self.transferDone(t)
        case .coast:
            return t.body == .luna
        case .brake:
            return Self.landedOnLuna(t) || Self.captured(t)
        case .land:
            return Self.landedOnLuna(t)
        }
    }

    func failure(_ i: LessonInput) -> String? {
        let t = i.telemetry
        switch self {
        case .burn:
            return t.maneuver == nil && !Self.transferDone(t) ? "Узел удалён — повторите шаг" : nil
        case .brake, .land:
            if t.situation == .crashed { return Self.crashText(i) }
            if t.body == .terra, t.mission.enteredLunaSOI { return "Корабль пролетел мимо Луны" }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Условия

    /// Прожиг перелёта выполнен: узел отработан (или удалён после прожига — орбита уже вытянута к Луне).
    static func transferDone(_ t: FlightTelemetry) -> Bool {
        if let m = t.maneuver { return m.isDone }
        if t.body == .luna { return true }
        guard let apo = t.orbit?.apoapsisAltitude else { return false }
        return apo > transferApoapsis
    }

    /// Орбита вокруг Луны замкнута и Ап ниже `captureApoapsis`.
    static func captured(_ t: FlightTelemetry) -> Bool {
        guard t.body == .luna, let apo = t.orbit?.apoapsisAltitude, apo.isFinite else { return false }
        return apo < captureApoapsis
    }

    static func landedOnLuna(_ t: FlightTelemetry) -> Bool {
        t.body == .luna && t.situation == .landed
    }

    static func crashText(_ i: LessonInput) -> String {
        guard let speed = i.touchdownSpeed else { return "Авария — повторите шаг" }
        return "Авария на \(HUDFormat.speed(speed)) — повторите шаг"
    }

    /// Время до входа в SOI Луны, с.
    static func timeToEncounter(_ i: LessonInput) -> Double? {
        guard let at = i.encounterTime else { return nil }
        let left = at - i.time
        return left > 0 ? left : nil
    }

    // MARK: - Тексты

    func bubble(_ i: LessonInput) -> LessonBubble? {
        switch self {
        case .intro:
            return LessonBubble(title: "Полёт к Луне",
                                text: "Вы на орбите Терры. Цель — перелететь к Луне и сесть.", button: "Понятно")
        case .openMap:
            return LessonBubble(title: "Карта", text: "Перелёт планируют на карте. Нажмите кнопку карты.", button: nil)
        case .mapIntro:
            return LessonBubble(title: "Орбита и Луна",
                                text: "Голубая линия — ваша орбита. Справа Луна, пунктир вокруг — где её притяжение сильнее Терры.",
                                button: "Дальше")
        case .lunaNode:
            return LessonBubble(title: "Узел манёвра",
                                text: "Нажмите «К Луне»: игра поставит точку прожига в нужном месте орбиты.", button: nil)
        case .encounter:
            return LessonBubble(title: "Фиолетовая — встреча",
                                text: "После прожига вы долетите до Луны. Вверху — Пе у Луны и время в пути.",
                                button: "Дальше")
        case .tune:
            return LessonBubble(title: "Ручки Δv",
                                text: "Ручка «разгон» — импульс по ходу. Потяните её чуть-чуть, чтобы Пе у Луны стал 20–40 км.",
                                button: nil)
        case .toNode:
            return LessonBubble(title: "Ускорение до узла",
                                text: "Нажмите «К узлу»: время ускорится и остановится за \(Int(ManeuverStatus.warpLead)) с до прожига.",
                                button: nil)
        case .sasNode:
            return LessonBubble(title: "Нос на узел",
                                text: "Включите SAS «УЗЕЛ» — корабль сам повернётся к синей метке прожига.", button: nil)
        case .coast:
            let way = Self.timeToEncounter(i).map { "До Луны \(HUDFormat.countdown($0))." } ?? "До Луны несколько часов."
            return LessonBubble(title: "Долго лететь",
                                text: way + " Ускорьте время — у Луны игра сама замедлится.", button: nil)
        case .finish:
            let soft = i.touchdownSpeed.map { "Посадка мягкая: \(HUDFormat.speed($0))." } ?? "Посадка мягкая."
            return LessonBubble(title: "Вы на Луне!",
                                text: soft + " Можно взлететь обратно — урок «Возврат» позже.",
                                button: "В ангар", role: .hangar, exitTitle: "Остаться на Луне")
        case .burn, .brake, .land:
            return nil
        }
    }

    func plate(_ i: LessonInput) -> LivePlate? {
        let t = i.telemetry
        switch self {
        case .tune:
            guard let peri = i.lunaPeriapsis else {
                return LivePlate(head: "Встречи с Луной нет · ", value: "тяните «разгон»")
            }
            return LivePlate(head: "Пе у Луны ", value: HUDFormat.distance(peri), tail: " · цель 20–40 км")
        case .toNode:
            return LivePlate(head: "Летим к узлу · до прожига ", value: HUDFormat.countdown(t.maneuver?.timeToBurn))
        case .burn:
            return Self.burnPlate(i)
        case .coast:
            return LivePlate(head: "Летим к Луне · до встречи ", value: HUDFormat.countdown(Self.timeToEncounter(i)))
        case .brake:
            let apo = t.body == .luna ? t.orbit?.apoapsisAltitude ?? .infinity : .infinity
            return LivePlate(head: "SAS «Ретро», тяга MAX у Пе · Ап у Луны ", value: HUDFormat.distance(apo),
                             tail: " → меньше 100 км")
        case .land:
            let value = HUDFormat.distance(t.heightAboveTerrain) + ", скорость " + HUDFormat.speed(t.surfaceSpeed)
            return LivePlate(head: "Ретро, тяга по ситуации · высота ", value: value, tail: " → у грунта < 5 м/с")
        case .intro, .openMap, .mapIntro, .lunaNode, .encounter, .sasNode, .finish:
            return nil
        }
    }

    static func burnPlate(_ i: LessonInput) -> LivePlate {
        guard let m = i.telemetry.maneuver, !m.isDone else {
            return LivePlate(head: "Прожиг выполнен · ", value: "тяга 0")
        }
        if m.timeToBurn > 0, m.remainingDeltaV >= m.deltaV - 0.5 {
            return LivePlate(head: "Прожиг через ", value: HUDFormat.countdown(m.timeToBurn), tail: " · затем тяга MAX")
        }
        return LivePlate(head: "Тяга MAX · осталось ", value: HUDFormat.speed(m.remainingDeltaV),
                         tail: " из \(HUDFormat.grouped(m.deltaV)) · тяга 0 при 0")
    }
}
