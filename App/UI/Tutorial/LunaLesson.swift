import Foundation
import OrbitPhysics

/// Урок «Полёт к Луне»: корабль «Луна» уже на орбите Терры 80 км. Карта, «К Луне», «Выполнить манёвр»
/// (автопрожиг с коррекцией), ускорение до Луны, захват («Скруглить орбиту» + «Выполнить манёвр»), посадка.
typealias LunaLesson = ScriptLesson<LunaStep>

enum LunaStep: Int, CaseIterable, ScriptStep {
    case intro, openMap, lunaNode, encounter, execute
    case coast, captureNode, captureBurn, retro, brake, land, finish

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
    /// Скорость относительно грунта, ниже которой торможение окончено и начинается посадка, м/с.
    static let brakedSpeed = 100.0
    /// Порог «тяга 0».
    static let throttleLow = 0.05
    /// Апоцентр у Терры, выше которого перелёт считается выполненным без узла (узел удалили после прожига), м.
    static var transferApoapsis: Double { Bodies.luna.orbitRadius * 0.5 }

    var kind: LessonKind {
        switch self {
        case .intro, .encounter, .finish: .pause
        case .brake, .land: .live
        case .openMap, .lunaNode, .execute, .coast, .captureNode, .captureBurn, .retro: .wait
        }
    }

    var screen: LessonScreen {
        switch self {
        case .intro: .flight
        case .lunaNode, .encounter, .execute, .captureNode, .captureBurn: .map
        // SAS и тяга есть только в полёте: с карты шаг просит «Полёт».
        case .retro, .brake, .land: .flight
        case .openMap, .coast, .finish: .any
        }
    }

    var target: LessonElement? {
        switch self {
        case .intro, .finish: nil
        case .openMap: .mapButton
        case .encounter: .mapSummary
        case .lunaNode: .mapLuna
        case .execute, .captureBurn: .mapExecute
        case .captureNode: .mapCircularize
        case .land: .throttle
        case .coast: .warp
        case .retro: .sas
        case .brake: .throttle
        }
    }

    var numbered: Bool { self != .intro && self != .finish }

    func fallback(_ i: LessonInput) -> LunaStep? {
        switch self {
        case .execute where i.telemetry.maneuver == nil && !Self.transferDone(i.telemetry): .lunaNode
        case .captureBurn where i.telemetry.maneuver == nil && !Self.captured(i.telemetry): .captureNode
        default: nil
        }
    }

    func trigger(_ i: LessonInput, from start: LessonBaseline) -> Bool {
        switch self {
        case .execute, .captureBurn: i.autoBurn
        case .coast: i.telemetry.warpIndex > 0
        default: false
        }
    }

    func isComplete(_ i: LessonInput, from start: LessonBaseline) -> Bool {
        let t = i.telemetry
        switch self {
        case .intro, .encounter, .finish:
            return false
        case .openMap:
            return i.mapOpen
        case .lunaNode:
            return t.maneuver != nil
        case .execute:
            return !i.autoBurn && i.throttle <= Self.throttleLow && Self.transferDone(t)
        case .coast:
            return t.body == .luna
        case .captureNode:
            return t.body == .luna && t.maneuver != nil
        case .captureBurn:
            return !i.autoBurn && i.throttle <= Self.throttleLow && Self.captured(t)
        case .retro:
            return t.sas == .retrograde
        case .brake:
            return Self.landedOnLuna(t) || t.surfaceSpeed < Self.brakedSpeed
        case .land:
            return Self.landedOnLuna(t)
        }
    }

    func failure(_ i: LessonInput) -> String? {
        let t = i.telemetry
        switch self {
        case .execute:
            return t.maneuver == nil && !Self.transferDone(t) ? "Узел удалён — повторите шаг" : nil
        case .captureBurn:
            return t.maneuver == nil && !Self.captured(t) ? "Узел удалён — повторите шаг" : nil
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
            return LessonBubble(title: "Карта", text: "Нажмите кнопку «Карта» справа вверху.", button: nil,
                                why: "Перелёт планируют на карте: там видны орбита, Луна и точка, где включать двигатель.")
        case .lunaNode:
            return LessonBubble(title: "Куда летим?", text: "Нажмите «К Луне» слева.", button: nil,
                                why: "Игра сама поставит узел — точку прожига — в нужном месте орбиты.")
        case .encounter:
            return LessonBubble(title: "Встреча с Луной",
                                text: "Фиолетовая линия ведёт к Луне. Справа «Пролёт над Луной» — "
                                    + "\(Self.periapsisRangeText) км с ✓: так и нужно.",
                                button: "Дальше",
                                why: "Пролёт — как низко корабль пройдёт над Луной. Слишком низко — упадёте, слишком высоко — пролетите мимо.")
        case .execute:
            return LessonBubble(title: "Выполнить манёвр", text: "Нажмите «Выполнить манёвр» справа.",
                                button: nil,
                                why: "Корабль сам долетит до узла, развернётся, сделает прожиг и поправит курс.")
        case .coast:
            let way = Self.timeToEncounter(i).map { "До Луны \(HUDFormat.countdown($0))." } ?? "До Луны несколько часов."
            return LessonBubble(title: "Ускорение времени", text: way + " Увеличьте ускорение вверху слева: «+» на карте или «×1 ▾» в полёте.", button: nil,
                                why: "Лететь долго. На ускорении время идёт быстрее; у Луны игра сама вернёт обычную скорость.")
        case .captureNode:
            return LessonBubble(title: "Захват", text: "Вы у Луны. Откройте карту и нажмите «Скруглить орбиту».",
                                button: nil,
                                why: "Сейчас корабль пролетит мимо. Торможение у ближней точки (Пе) превратит пролёт в орбиту вокруг Луны.")
        case .captureBurn:
            return LessonBubble(title: "Выполнить манёвр", text: "Нажмите «Выполнить манёвр» справа.",
                                button: nil, why: "Корабль сам затормозит в самой низкой точке над Луной — и Луна его «поймает».")
        case .retro:
            return LessonBubble(title: "Ретро", text: "Нажмите «SAS ▾» и выберите «Против вектора скорости» — нос развернётся против движения.",
                                button: nil,
                                why: "Двигатель тормозит, только если смотрит против полёта. Чтобы сесть, нужно погасить скорость.")
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
        case .execute, .captureBurn:
            return LivePlate.burn(i)
        case .coast:
            return LivePlate(head: "Летим к Луне · до встречи ", value: HUDFormat.countdown(Self.timeToEncounter(i)))
        case .brake:
            return LivePlate(head: "Тяга MAX, нос по ретро · скорость ", value: HUDFormat.speed(t.surfaceSpeed),
                             tail: " → меньше \(Int(Self.brakedSpeed)) м/с")
        case .land:
            let value = HUDFormat.distance(t.heightAboveTerrain) + ", скорость " + HUDFormat.speed(t.surfaceSpeed)
            return LivePlate(head: "Тяга по ситуации · высота ", value: value, tail: " → у грунта < 5 м/с")
        case .intro, .openMap, .lunaNode, .encounter, .captureNode, .retro, .finish:
            return nil
        }
    }
}
