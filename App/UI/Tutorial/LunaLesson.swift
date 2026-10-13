import Foundation
import OrbitPhysics

/// Урок «Полёт к Луне»: корабль «Луна» уже на орбите Терры 80 км. Карта, цель «К Луне», «Выполнить манёвр»
/// (автопрожиг), перелёт, торможение у Луны, посадка.
typealias LunaLesson = ScriptLesson<LunaStep>

enum LunaStep: Int, CaseIterable, ScriptStep {
    case intro, openMap, mapIntro, lunaNode, encounter, execute
    case coast, brake, land, finish

    static var sequence: [LunaStep] { allCases }
    static var endsWithSummary: Bool { true }

    /// Пе у Луны, к которому подстраивают узел, м.
    static let periapsisRange = 15_000.0...60_000.0
    /// Границы диапазона Пе в км для текстов («15–60»).
    static var periapsisRangeText: String {
        "\(Int(periapsisRange.lowerBound / 1_000))–\(Int(periapsisRange.upperBound / 1_000))"
    }
    /// Апоцентр у Луны, ниже которого орбита считается пойманной, м.
    static let captureApoapsis = 100_000.0
    /// Порог «тяга 0».
    static let throttleLow = 0.05
    /// Апоцентр у Терры, выше которого перелёт считается выполненным без узла (узел удалили после прожига), м.
    static var transferApoapsis: Double { Bodies.luna.orbitRadius * 0.5 }

    var kind: LessonKind {
        switch self {
        case .intro, .mapIntro, .encounter, .finish: .pause
        case .brake, .land: .live
        case .openMap, .lunaNode, .execute, .coast: .wait
        }
    }

    var screen: LessonScreen {
        switch self {
        case .intro: .flight
        case .mapIntro, .lunaNode, .encounter, .execute: .map
        case .openMap, .coast, .brake, .land, .finish: .any
        }
    }

    var target: LessonElement? {
        switch self {
        case .intro, .finish: nil
        case .openMap: .mapButton
        case .mapIntro, .encounter: .mapSummary
        case .lunaNode: .mapLuna
        case .execute: .mapExecute
        case .land: .throttle
        case .coast: .warp
        case .brake: .sas
        }
    }

    func trigger(_ i: LessonInput, from start: LessonBaseline) -> Bool {
        switch self {
        case .execute: i.autoBurn
        case .coast: i.telemetry.warpIndex > 0
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
        case .execute:
            return !i.autoBurn && i.throttle <= Self.throttleLow && Self.transferDone(t)
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
        case .execute:
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
            return LessonBubble(title: "Куда летим?",
                                text: "Нажмите «К Луне»: игра сама поставит точку прожига в нужном месте орбиты.", button: nil)
        case .encounter:
            return LessonBubble(title: "Фиолетовая — встреча",
                                text: "После прожига вы долетите до Луны. В карточке «Результат» — Пе у Луны: "
                                    + "\(Self.periapsisRangeText) км и галочка — то, что нужно.",
                                button: "Дальше")
        case .execute:
            return LessonBubble(title: "Выполнить манёвр",
                                text: "Нажмите «Выполнить манёвр»: корабль сам долетит до узла, развернётся и сделает прожиг.",
                                button: nil)
        case .coast:
            let way = Self.timeToEncounter(i).map { "До Луны \(HUDFormat.countdown($0))." } ?? "До Луны несколько часов."
            return LessonBubble(title: "Долго лететь",
                                text: way + " Ускорьте время — у Луны игра сама замедлится.", button: nil)
        case .finish:
            let soft = i.touchdownSpeed.map { "Посадка мягкая: \(HUDFormat.speed($0))." } ?? "Посадка мягкая."
            return LessonBubble(title: "Вы на Луне!",
                                text: soft + " Можно взлететь обратно — урок «Возврат» позже.",
                                button: "В ангар", role: .hangar, exitTitle: "Остаться на Луне")
        case .brake, .land:
            return nil
        }
    }

    func plate(_ i: LessonInput) -> LivePlate? {
        let t = i.telemetry
        switch self {
        case .execute:
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
        case .intro, .openMap, .mapIntro, .lunaNode, .encounter, .finish:
            return nil
        }
    }

    /// Плашка автопрожига: путь к узлу, затем остаток Δv.
    static func burnPlate(_ i: LessonInput) -> LivePlate {
        guard let m = i.telemetry.maneuver, !m.isDone else {
            return LivePlate(head: "Прожиг выполнен · ", value: "тяга 0")
        }
        if m.timeToBurn > 0, m.remainingDeltaV >= m.deltaV - 0.5 {
            return LivePlate(head: "Летим к узлу · до прожига ", value: HUDFormat.countdown(m.timeToBurn))
        }
        return LivePlate(head: "Прожиг · осталось ", value: HUDFormat.speed(m.remainingDeltaV),
                         tail: " из \(HUDFormat.grouped(m.deltaV))")
    }
}
