import Foundation
import OrbitPhysics

/// Итог полёта для панели результата.
struct FlightResult: Equatable {
    enum Outcome: Equatable {
        case crashed, landed, splashed, landedLuna
    }

    var outcome: Outcome
    var mission: MissionRecord
    var missionTime: Double

    var title: String {
        switch outcome {
        case .crashed: "Авария"
        case .landed: "Посадка"
        case .splashed: "Приводнение"
        case .landedLuna: "Посадка на Луну"
        }
    }

    /// «Продолжить» есть только после благополучной посадки (например, чтобы взлететь с Луны).
    var canContinue: Bool { outcome != .crashed }
}

/// Подсказка первого полёта; в каждый момент показывается не больше одной.
enum HUDHint: Hashable {
    case stage, throttle, turn, warp, chute, chuteStages

    /// Ключ `@AppStorage`: после первой успешной посадки подсказки больше не нужны.
    static let doneKey = "hintsDone"

    var text: String {
        switch self {
        case .stage: "Нажмите «Зажигание», чтобы запустить двигатели"
        case .throttle: "Двигатель зажжён: установите тягу MAX слева"
        case .turn: "Плавно наклоняйте на восток (джойстик вправо)"
        case .warp: "Ускорение времени — в верхней панели"
        case .chute: "Нажмите «Парашют» — он раскроется при безопасной скорости"
        case .chuteStages: "Сначала завершите ступени кнопкой справа, затем вооружите парашют"
        }
    }
}

/// Решает по кадру телеметрии, когда показать экран результата и какую подсказку.
/// Чистая логика без UI; время — секунды кадра (`CACurrentMediaTime`), на паузе не вызывается.
struct FlightAdvisor {
    /// Задержка после аварии, чтобы был виден взрыв, с.
    static let crashDelay: TimeInterval = 1.5
    /// Сколько корабль должен стоять после посадки, с, и что считать «почти неподвижен», м/с.
    static let settleTime: TimeInterval = 2
    static let settleSpeed = 0.5

    private(set) var result: FlightResult?
    private(set) var hint: HUDHint?
    /// Крестик на плашке: подсказки скрыты до конца полёта.
    private(set) var hintsDismissed = false
    /// Корабль благополучно сел или приводнился — подсказки больше не нужны.
    private(set) var landedSafely = false

    private var crashAt: TimeInterval?
    private var stillSince: TimeInterval?
    private var resultDismissed = false
    private var ignited = false
    private var firstShown: [HUDHint: TimeInterval] = [:]

    mutating func dismissResult() {
        result = nil
        resultDismissed = true
    }

    mutating func dismissHints() {
        hintsDismissed = true
        hint = nil
    }

    mutating func update(_ t: FlightTelemetry, throttle: Double, events: [SimEvent], now: TimeInterval) {
        updateResult(t, now: now)
        updateHint(t, throttle: throttle, events: events, now: now)
    }

    // MARK: - Результат

    private mutating func updateResult(_ t: FlightTelemetry, now: TimeInterval) {
        switch t.situation {
        case .crashed:
            stillSince = nil
            let start = crashAt ?? now
            crashAt = start
            if !resultDismissed, result == nil, now - start >= Self.crashDelay {
                result = FlightResult(outcome: .crashed, mission: t.mission, missionTime: t.missionTime)
            }
        case .landed, .splashed:
            crashAt = nil
            guard t.mission.launched, t.surfaceSpeed < Self.settleSpeed else {
                stillSince = nil
                return
            }
            let start = stillSince ?? now
            stillSince = start
            guard now - start >= Self.settleTime else { return }
            landedSafely = true
            if !resultDismissed, result == nil {
                let outcome: FlightResult.Outcome = t.situation == .splashed
                    ? .splashed : (t.body == .luna ? .landedLuna : .landed)
                result = FlightResult(outcome: outcome, mission: t.mission, missionTime: t.missionTime)
            }
        default:
            // Снова в полёте: панель можно показать при следующей посадке.
            crashAt = nil
            stillSince = nil
            resultDismissed = false
            result = nil
        }
    }

    // MARK: - Подсказки

    private mutating func updateHint(_ t: FlightTelemetry, throttle: Double, events: [SimEvent], now: TimeInterval) {
        if !ignited, t.thrust > 0 || events.contains(where: { if case .ignition = $0 { true } else { false } }) {
            ignited = true
        }
        guard !hintsDismissed, !landedSafely else { hint = nil; return }
        guard let wanted = wantedHint(t, throttle: throttle, now: now) else { hint = nil; return }
        if firstShown[wanted] == nil { firstShown[wanted] = now }
        hint = wanted
    }

    private func wantedHint(_ t: FlightTelemetry, throttle: Double, now: TimeInterval) -> HUDHint? {
        // Подсказка без привязки к действию гаснет через `limit` секунд после первого показа.
        func fresh(_ hint: HUDHint, limit: TimeInterval) -> Bool {
            guard let first = firstShown[hint] else { return true }
            return now - first < limit
        }
        let vertical = t.verticalSpeed
        let horizontal = (max(0, t.surfaceSpeed * t.surfaceSpeed - vertical * vertical)).squareRoot()
        let airborne = t.situation == .flying || t.situation == .suborbital

        if t.body == .terra, t.mission.launched, airborne, vertical < -5, t.altitude < 30_000,
           t.chute == .stowed, t.chuteSafe {
            // `stages.count` совпадает с числом секций корабля: «Ступень» раскрывает парашют, только когда
            // секция одна (иначе сперва зажигает двигатели или отделяет нижнюю ступень).
            return t.nextStageAction == .armChute ? .chute : (t.nextStageAction == .none ? nil : .chuteStages)
        }
        if t.body == .terra, airborne || t.situation == .orbiting, t.altitude > 70_000, t.warpIndex == 0,
           fresh(.warp, limit: 10) {
            return .warp
        }
        if t.body == .terra, t.mission.launched, airborne, t.heightAboveTerrain > 1_000, t.altitude < 40_000,
           vertical > 20, horizontal < 0.25 * t.surfaceSpeed, fresh(.turn, limit: 15) {
            return .turn
        }
        if t.situation == .prelaunch {
            if !ignited { return .stage }
            if t.thrust < 1, throttle < 0.01 { return .throttle }
        }
        return nil
    }
}
