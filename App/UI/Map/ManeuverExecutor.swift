import Foundation
import OrbitPhysics

/// Результат одного шага автопрожига: что сделать с кораблём в этом кадре.
struct ExecutorOutput: Equatable {
    var throttle: Double
    var commands: [FlightCommand]
    var phase: ManeuverExecutor.Phase
    /// Ошибка: автопрожиг остановлен (тост для игрока).
    var error: String?
    /// Тост об успешном завершении.
    var toast: String?
    /// Автопрожиг закончен (успехом, ошибкой или остановкой) — модель его сбрасывает.
    var finished: Bool
}

/// Автопрожиг узла манёвра для простой карты. Чистая структура без UI: модель каждый кадр отдаёт телеметрию
/// и массу и выполняет то, что вернул `step` (тягу пишет в `throttle` до `setInput`, команды шлёт в симуляцию).
///
/// Порядок: SAS по узлу → один раз ускорение до узла (если до прожига далеко; в атмосфере — физическое ×4, пока
/// рельсы заблокированы, потом `warpToManeuver`) → тяга 0, пока не пришло время
/// и нос не развёрнут на узел (5°; во время прожига допускается 15°) → тяга по остатку Δv → узел выполнен.
/// Отмена игроком (тяга, кнопки ориентации, «Стоп») — на стороне модели; здесь отмена — удалённый или изменённый узел.
struct ManeuverExecutor: Equatable {
    enum Phase: Equatable, Sendable {
        /// Летим к узлу: до начала прожига ещё есть время.
        case warping
        /// Пора жечь, но нос ещё не на узле.
        case aligning
        /// Прожиг.
        case burning
        /// Узел выполнен.
        case done
        /// Остановлено: узел удалён/изменён, ошибка.
        case stopped
    }

    /// Допуск выравнивания до начала прожига и во время него, градусы.
    static let startAngle = 5.0
    static let burnAngle = 15.0
    /// За сколько секунд до конца прожига тяга успевает упасть до нуля (чем меньше остаток, тем мягче).
    static let tailSeconds = 2.0
    /// Нижняя граница тяги, пока прожиг идёт.
    static let minThrottle = 0.05
    /// Подготовка ступени (отделить пустую, зажечь) — за столько секунд до прожига; РДТТ — только в момент прожига.
    static let stageLead = ManeuverStatus.warpLead + 5
    /// Больше таких нажатий «Ступень» за один автопрожиг — значит, тяги не будет.
    static let maxStageCommands = 6
    /// Остаток Δv, при котором прожиг закончен, м/с, и рост остатка, считающийся перелётом.
    static let finishRemaining = 0.1
    static let overshootMargin = 0.05
    /// Последний физический уровень ускорения (×4).
    static let physicalTop = TimeWarp.physicalCount - 1
    static let noFuelText = "Не хватает топлива"
    static let doneText = "Манёвр выполнен"

    private(set) var phase: Phase = .warping
    /// Узел, с которым начали: его правка = отмена.
    private var node: ManeuverNode?
    private var warpRequested = false
    /// Физическое ускорение включено автопрожигом (рельсы заблокированы атмосферой).
    private var physicalWarp = false
    private var started = false
    /// Тяга включена: допуск выравнивания шире.
    private var engaged = false
    private var stageCommands = 0
    /// Наименьший остаток за прожиг: рост остатка — перелёт через ноль, пора гасить.
    private var minRemaining = Double.infinity

    /// Один кадр. `mass` — масса активного корабля, кг.
    mutating func step(_ t: FlightTelemetry, mass: Double) -> ExecutorOutput {
        guard let m = t.maneuver else {
            return stop(.stopped, error: nil)
        }
        if let node, node != m.node { return stop(.stopped, error: nil) }
        if t.situation == .crashed || t.situation == .prelaunch { return stop(.stopped, error: nil) }
        var commands: [FlightCommand] = []
        if !started {
            started = true
            node = m.node
            commands.append(.setSAS(.maneuver))
        }

        // Физика считает узел выполненным при остатке < 1 м/с, но Пе у Луны меняется на ~70 км на 1 м/с:
        // дожигаем до `finishRemaining`, гасим и при перелёте (остаток начал расти).
        let overshot = engaged && m.remainingDeltaV > minRemaining + Self.overshootMargin
        if engaged { minRemaining = min(minRemaining, m.remainingDeltaV) }
        if m.remainingDeltaV < Self.finishRemaining || overshot || (m.isDone && m.remainingDeltaV >= 1) {
            phase = .done
            return ExecutorOutput(throttle: 0, commands: [.setSAS(.hold), .setManeuver(nil)], phase: .done,
                                  error: nil, toast: Self.doneText, finished: true)
        }

        // Без тяги burnTime = ∞, и timeToBurn = −∞: до зажигания считаем от момента узла.
        let lead = m.burnTime.isFinite ? m.timeToBurn : m.timeToNode
        if lead > 0 {
            phase = .warping
            if lead > ManeuverStatus.warpLead + 5 {
                if !warpRequested {
                    if t.warpBlocked == nil {
                        // Рельсы можно: один раз летим до узла, дальше ускорение держит физика.
                        warpRequested = true
                        physicalWarp = false
                        commands.append(.warpToManeuver)
                    } else if Self.blockedByGround(t.warpBlocked), !physicalWarp, t.warpIndex < Self.physicalTop {
                        // В атмосфере (или низко над Луной) рельсов нет: физическое ×4, пока не выйдем выше.
                        physicalWarp = true
                        commands.append(.setWarp(index: Self.physicalTop))
                    }
                }
            } else if physicalWarp || (t.warpIndex > 0 && t.warpIndex <= Self.physicalTop) {
                // До прожига осталось мало: возвращаемся к ×1 (и с физического ускорения игрока),
                // чтобы развернуться и не проскочить.
                physicalWarp = false
                if t.warpIndex > 0 { commands.append(.setWarp(index: 0)) }
            }
            // Заранее: пустую ступень сбросить, жидкостный двигатель зажечь — к прожигу всё готово.
            if t.maxThrust <= 0, lead <= Self.stageLead, !(t.stages.first?.hasSolid ?? false) {
                if let error = stageIfNeeded(t, into: &commands) { return fail(error, commands) }
            }
            return ExecutorOutput(throttle: 0, commands: commands, phase: .warping, error: nil, toast: nil, finished: false)
        }

        // Пора жечь.
        if t.maxThrust <= 0 {
            if let error = stageIfNeeded(t, into: &commands) { return fail(error, commands) }
            phase = engaged ? .burning : .aligning
            return ExecutorOutput(throttle: 0, commands: commands, phase: phase, error: nil, toast: nil, finished: false)
        }
        let angle = Self.angle(toManeuver: t.navball.maneuver)
        if engaged, angle > Self.burnAngle { engaged = false }
        if !engaged, angle > Self.startAngle {
            phase = .aligning
            return ExecutorOutput(throttle: 0, commands: commands, phase: .aligning, error: nil, toast: nil, finished: false)
        }
        engaged = true
        phase = .burning
        let acceleration = t.maxThrust / max(mass, 1)
        let throttle = Self.throttle(remaining: m.remainingDeltaV, acceleration: acceleration)
        return ExecutorOutput(throttle: throttle, commands: commands, phase: .burning, error: nil, toast: nil,
                              finished: false)
    }

    /// Рельсы заблокированы высотой (атмосфера Терры, низкая орбита Луны), а не тягой или сменой сферы.
    static func blockedByGround(_ reason: WarpResetReason?) -> Bool {
        reason == .atmosphere || reason == .terrain
    }

    /// Тяга по остатку Δv: полная, пока остаток больше разгона за `tailSeconds`, потом плавно вниз до `minThrottle`.
    static func throttle(remaining: Double, acceleration: Double) -> Double {
        guard acceleration > 0, remaining.isFinite else { return minThrottle }
        return min(max(remaining / (acceleration * tailSeconds), minThrottle), 1)
    }

    /// Угол между носом (+Y) и направлением узла, градусы; направления нет — 180.
    static func angle(toManeuver direction: Vec3?) -> Double {
        guard let direction, direction.length > 1e-9 else { return 180 }
        let cosine = min(max(direction.normalized.y, -1), 1)
        return acos(cosine) * 180 / .pi
    }

    /// Нажатие «Ступень», если оно даёт тягу; nil — команда добавлена или ждать нечего, строка — ошибка.
    private mutating func stageIfNeeded(_ t: FlightTelemetry, into commands: inout [FlightCommand]) -> String? {
        switch t.nextStageAction {
        case .ignite, .separate:
            guard stageCommands < Self.maxStageCommands else { return Self.noFuelText }
            stageCommands += 1
            commands.append(.stage)
            return nil
        case .armChute, .none:
            return Self.noFuelText
        }
    }

    private func fail(_ error: String, _ commands: [FlightCommand]) -> ExecutorOutput {
        ExecutorOutput(throttle: 0, commands: commands, phase: .stopped, error: error, toast: nil, finished: true)
    }

    private mutating func stop(_ phase: Phase, error: String?) -> ExecutorOutput {
        self.phase = phase
        return ExecutorOutput(throttle: 0, commands: [], phase: phase, error: error, toast: nil, finished: true)
    }

    // MARK: - Подписи

    /// Строка фазы для кнопки «Стоп» и плашки узла: «Летим к узлу 31:41», «Разворот», «Прожиг · ост 312 м/с».
    static func statusText(_ phase: Phase, _ t: FlightTelemetry) -> String {
        switch phase {
        case .warping:
            let lead = t.maneuver.map { $0.burnTime.isFinite ? $0.timeToBurn : $0.timeToNode }
            return "Летим к узлу " + HUDFormat.countdown(lead)
        case .aligning:
            return "Разворот"
        case .burning:
            return "Прожиг · ост " + HUDFormat.speed(t.maneuver?.remainingDeltaV ?? 0)
        case .done:
            return doneText
        case .stopped:
            return "Остановлено"
        }
    }
}
