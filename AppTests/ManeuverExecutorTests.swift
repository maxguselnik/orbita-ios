import Foundation
import Testing
import OrbitPhysics
@testable import Orbita

/// Автопрожиг узла: фазы, выравнивание, тяга у конца, ступени, отмена, ошибка.
struct ManeuverExecutorTests {
    // MARK: - Помощники

    private let mass = 10_000.0
    private let maxThrust = 100_000.0 // разгон 10 м/с²

    private func node() -> ManeuverNode {
        ManeuverNode(time: 1_000, prograde: 800)
    }

    private func status(toBurn: Double, remaining: Double = 800, done: Bool = false,
                        burnTime: Double = 80, node: ManeuverNode? = nil) -> ManeuverStatus {
        ManeuverStatus(node: node ?? self.node(), timeToNode: burnTime.isFinite ? toBurn + burnTime / 2 : toBurn, deltaV: 800,
                       remainingDeltaV: remaining, burnTime: burnTime, timeToBurn: toBurn, isDone: done)
    }

    /// Нос на узле: направление узла в осях корабля отклонено от +Y на `degrees`.
    private func telemetry(_ m: ManeuverStatus?, off degrees: Double = 0, maxThrust: Double? = nil,
                           action: StageAction = .none, sas: SASMode = .hold, warpBlocked: WarpResetReason? = nil,
                           solid: Bool = false) -> FlightTelemetry {
        let a = degrees * .pi / 180
        var t = FlightTelemetry(sas: sas, maxThrust: maxThrust ?? self.maxThrust, body: .terra, situation: .orbiting,
                                navball: NavballVectors(maneuver: Vec3(sin(a), cos(a), 0)),
                                warpBlocked: warpBlocked, maneuver: m)
        t.nextStageAction = action
        t.stages = [StageInfo(deltaV: 2_000, twr: 1, twrVacuum: 1, fuelFraction: 1, burnTime: 100, hasSolid: solid)]
        return t
    }

    // MARK: - Старт и ускорение

    @Test func firstStepSetsSASAndWarpsOnceWhenBurnIsFar() {
        var ex = ManeuverExecutor()
        let far = telemetry(status(toBurn: 1_900))
        let first = ex.step(far, mass: mass)
        #expect(first.commands == [.setSAS(.maneuver), .warpToManeuver])
        #expect(first.phase == .warping && first.throttle == 0 && !first.finished)
        let second = ex.step(far, mass: mass)
        #expect(second.commands.isEmpty && second.phase == .warping)
    }

    /// Смена сферы влияния сбросила рельсы на долгом перелёте: ускорение до узла просим снова, один раз.
    @Test func soiChangeRequestsWarpAgain() {
        var ex = ManeuverExecutor()
        var t = telemetry(status(toBurn: 3_000_000))
        #expect(ex.step(t, mass: mass).commands == [.setSAS(.maneuver), .warpToManeuver])
        t.warpIndex = 0
        t.body = .sol
        #expect(ex.step(t, mass: mass).commands == [.warpToManeuver])
        #expect(ex.step(t, mass: mass).commands.isEmpty)
    }

    @Test func noWarpWhenBurnIsClose() {
        var near = ManeuverExecutor()
        #expect(near.step(telemetry(status(toBurn: ManeuverStatus.warpLead + 5)), mass: mass).commands == [.setSAS(.maneuver)])
    }

    /// В атмосфере рельсов нет: физическое ×4, а как только можно — один раз «до узла».
    @Test func atmosphereUsesPhysicalWarpThenRailsOnceUnblocked() {
        var ex = ManeuverExecutor()
        var t = telemetry(status(toBurn: 1_900), warpBlocked: .atmosphere)
        let first = ex.step(t, mass: mass)
        #expect(first.commands == [.setSAS(.maneuver), .setWarp(index: TimeWarp.physicalCount - 1)])
        // Ускорение включено: повторно не шлём.
        t.warpIndex = TimeWarp.physicalCount - 1
        #expect(ex.step(t, mass: mass).commands.isEmpty)
        t.maneuver = status(toBurn: 1_200)
        #expect(ex.step(t, mass: mass).commands.isEmpty)
        // Вышли из атмосферы: рельсы до узла — ровно один раз.
        t.warpBlocked = nil
        t.maneuver = status(toBurn: 900)
        #expect(ex.step(t, mass: mass).commands == [.warpToManeuver])
        #expect(ex.step(t, mass: mass).commands.isEmpty)
    }

    @Test func physicalWarpReturnsToRealTimeBeforeTheBurn() {
        var ex = ManeuverExecutor()
        var t = telemetry(status(toBurn: 400), warpBlocked: .atmosphere)
        _ = ex.step(t, mass: mass)
        t.warpIndex = TimeWarp.physicalCount - 1
        t.maneuver = status(toBurn: ManeuverStatus.warpLead + 3)
        #expect(ex.step(t, mass: mass).commands == [.setWarp(index: 0)])
        t.warpIndex = 0
        #expect(ex.step(t, mass: mass).commands.isEmpty)
    }

    /// Игрок сам включил ×4 до старта: перед прожигом автопрожиг всё равно возвращает ×1.
    @Test func playerPhysicalWarpAlsoReturnsToRealTimeBeforeTheBurn() {
        var ex = ManeuverExecutor()
        var t = telemetry(status(toBurn: ManeuverStatus.warpLead + 3))
        t.warpIndex = TimeWarp.physicalCount - 1
        #expect(ex.step(t, mass: mass).commands == [.setSAS(.maneuver), .setWarp(index: 0)])
    }

    @Test func thrustOrSphereChangeBlocksDoNotTriggerPhysicalWarp() {
        for reason in [WarpResetReason.thrust, .soiChange] {
            var ex = ManeuverExecutor()
            let out = ex.step(telemetry(status(toBurn: 1_900), warpBlocked: reason), mass: mass)
            #expect(out.commands == [.setSAS(.maneuver)])
        }
        // Игрок уже сам включил ×4 — команду не дублируем.
        var ex = ManeuverExecutor()
        var t = telemetry(status(toBurn: 1_900), warpBlocked: .atmosphere)
        t.warpIndex = TimeWarp.physicalCount - 1
        #expect(ex.step(t, mass: mass).commands == [.setSAS(.maneuver)])
    }

    @Test func throttleStaysZeroUntilBurnTime() {
        var ex = ManeuverExecutor()
        let out = ex.step(telemetry(status(toBurn: 3)), mass: mass)
        #expect(out.throttle == 0 && out.phase == .warping)
    }

    // MARK: - Выравнивание

    @Test func misalignedAtBurnTimeWaitsInAligningPhase() {
        var ex = ManeuverExecutor()
        _ = ex.step(telemetry(status(toBurn: 5)), mass: mass)
        let late = ex.step(telemetry(status(toBurn: -1), off: 8), mass: mass)
        #expect(late.throttle == 0 && late.phase == .aligning)
        let aligned = ex.step(telemetry(status(toBurn: -2), off: 4), mass: mass)
        #expect(aligned.throttle == 1 && aligned.phase == .burning)
    }

    @Test func burnTolerancesAreFiveDegreesToStartAndFifteenWhileBurning() {
        var ex = ManeuverExecutor()
        #expect(ex.step(telemetry(status(toBurn: -1), off: 6), mass: mass).phase == .aligning)
        #expect(ex.step(telemetry(status(toBurn: -1), off: 4.5), mass: mass).phase == .burning)
        // Во время прожига 10° терпимы.
        #expect(ex.step(telemetry(status(toBurn: -2, remaining: 700), off: 10), mass: mass).phase == .burning)
        // 20° — тяга 0, а вернуться к тяге можно только в 5°.
        let off = ex.step(telemetry(status(toBurn: -3, remaining: 700), off: 20), mass: mass)
        #expect(off.throttle == 0 && off.phase == .aligning)
        #expect(ex.step(telemetry(status(toBurn: -4, remaining: 700), off: 10), mass: mass).phase == .aligning)
        #expect(ex.step(telemetry(status(toBurn: -5, remaining: 700), off: 3), mass: mass).phase == .burning)
    }

    @Test func angleToManeuverUsesNoseAxis() {
        #expect(abs(ManeuverExecutor.angle(toManeuver: Vec3(0, 1, 0))) < 1e-9)
        #expect(abs(ManeuverExecutor.angle(toManeuver: Vec3(1, 0, 0)) - 90) < 1e-9)
        #expect(abs(ManeuverExecutor.angle(toManeuver: Vec3(0, -3, 0)) - 180) < 1e-9)
        #expect(ManeuverExecutor.angle(toManeuver: nil) == 180)
    }

    // MARK: - Тяга

    @Test func throttleFollowsRemainingDeltaVAndFloorsAtFivePercent() {
        // Разгон 10 м/с²: полная тяга, пока остаток больше 20 м/с.
        #expect(ManeuverExecutor.throttle(remaining: 300, acceleration: 10) == 1)
        #expect(ManeuverExecutor.throttle(remaining: 20, acceleration: 10) == 1)
        #expect(abs(ManeuverExecutor.throttle(remaining: 10, acceleration: 10) - 0.5) < 1e-9)
        #expect(ManeuverExecutor.throttle(remaining: 0.2, acceleration: 10) == ManeuverExecutor.minThrottle)

        var ex = ManeuverExecutor()
        let burning = ex.step(telemetry(status(toBurn: -10, remaining: 5)), mass: mass)
        #expect(abs(burning.throttle - 0.25) < 1e-9 && burning.phase == .burning)
        // Масса из снимка корабля: тяжелее — меньше разгон, тяга выше.
        var heavy = ManeuverExecutor()
        let h = heavy.step(telemetry(status(toBurn: -10, remaining: 5)), mass: 2 * mass)
        #expect(abs(h.throttle - 0.5) < 1e-9)
    }

    // MARK: - Завершение

    @Test func doneZeroesThrottleHoldsSASDeletesNodeAndToasts() {
        var ex = ManeuverExecutor()
        _ = ex.step(telemetry(status(toBurn: -10)), mass: mass)
        // Физика уже считает узел выполненным (< 1 м/с), но автопрожиг дожигает до 0.1 м/с.
        let tail = ex.step(telemetry(status(toBurn: -90, remaining: 0.4, done: true)), mass: mass)
        #expect(tail.phase == .burning && tail.throttle > 0)
        let out = ex.step(telemetry(status(toBurn: -91, remaining: 0.05, done: true)), mass: mass)
        #expect(out.phase == .done && out.finished)
        #expect(out.throttle == 0)
        #expect(out.commands == [.setSAS(.hold), .setManeuver(nil)])
        #expect(out.toast == "Манёвр выполнен" && out.error == nil)
    }

    @Test func overshootFinishesBurn() {
        var ex = ManeuverExecutor()
        _ = ex.step(telemetry(status(toBurn: -1, remaining: 0.5)), mass: mass)
        _ = ex.step(telemetry(status(toBurn: -2, remaining: 0.3)), mass: mass)
        // Остаток начал расти — перелетели через ноль: гасим.
        let out = ex.step(telemetry(status(toBurn: -3, remaining: 0.4)), mass: mass)
        #expect(out.phase == .done && out.throttle == 0)
    }

    // MARK: - Ступени

    @Test func igniteStageWhenThereIsNoThrustAtBurnTime() {
        var ex = ManeuverExecutor()
        let none = telemetry(status(toBurn: -1, burnTime: .infinity), maxThrust: 0, action: .ignite)
        let out = ex.step(none, mass: mass)
        #expect(out.commands.contains(.stage) && out.throttle == 0 && out.error == nil && !out.finished)
        // Двигатель зажжён — дальше обычный прожиг.
        #expect(ex.step(telemetry(status(toBurn: -1)), mass: mass).phase == .burning)
    }

    @Test func liquidStageIsPreparedAheadOfTimeButSolidOnlyAtBurn() {
        var ahead = ManeuverExecutor()
        let early = telemetry(status(toBurn: 10, burnTime: .infinity), maxThrust: 0, action: .ignite)
        #expect(ahead.step(early, mass: mass).commands.contains(.stage))

        var solid = ManeuverExecutor()
        let early2 = telemetry(status(toBurn: 10, burnTime: .infinity), maxThrust: 0, action: .ignite, solid: true)
        #expect(!solid.step(early2, mass: mass).commands.contains(.stage))
        let late = telemetry(status(toBurn: -1, burnTime: .infinity), maxThrust: 0, action: .ignite, solid: true)
        #expect(solid.step(late, mass: mass).commands.contains(.stage))
    }

    @Test func emptyStageIsSeparatedThenNextIsIgnited() {
        var ex = ManeuverExecutor()
        _ = ex.step(telemetry(status(toBurn: -5, remaining: 400)), mass: mass)
        let empty = ex.step(telemetry(status(toBurn: -6, remaining: 380), maxThrust: 0, action: .separate), mass: mass)
        #expect(empty.commands == [.stage] && empty.throttle == 0 && empty.error == nil)
        let next = ex.step(telemetry(status(toBurn: -6, remaining: 380), maxThrust: 0, action: .ignite), mass: mass)
        #expect(next.commands == [.stage] && !next.finished)
        #expect(ex.step(telemetry(status(toBurn: -7, remaining: 380)), mass: mass).phase == .burning)
    }

    @Test func noFuelErrorWhenNothingLeftToStage() {
        var ex = ManeuverExecutor()
        _ = ex.step(telemetry(status(toBurn: -5, remaining: 400)), mass: mass)
        for action in [StageAction.none, .armChute] {
            var e = ex
            let out = e.step(telemetry(status(toBurn: -6, remaining: 380), maxThrust: 0, action: action), mass: mass)
            #expect(out.error == "Не хватает топлива" && out.finished && out.throttle == 0)
        }
    }

    @Test func noEnginesAtAllFailsBeforeTheBurnToo() {
        var ex = ManeuverExecutor()
        let out = ex.step(telemetry(status(toBurn: 10, burnTime: .infinity), maxThrust: 0, action: .none), mass: mass)
        #expect(out.error == "Не хватает топлива" && out.finished)
    }

    @Test func stagingGivesUpAfterSeveralAttempts() {
        var ex = ManeuverExecutor()
        let stuck = telemetry(status(toBurn: -6, remaining: 380), maxThrust: 0, action: .separate)
        var last = ex.step(stuck, mass: mass)
        for _ in 0..<ManeuverExecutor.maxStageCommands { last = ex.step(stuck, mass: mass) }
        #expect(last.error == "Не хватает топлива" && last.finished)
    }

    // MARK: - Отмена

    @Test func editedOrDeletedNodeStopsTheBurn() {
        var edited = ManeuverExecutor()
        _ = edited.step(telemetry(status(toBurn: 600)), mass: mass)
        var moved = node()
        moved.prograde += 5
        let out = edited.step(telemetry(status(toBurn: 600, node: moved)), mass: mass)
        #expect(out.finished && out.phase == .stopped && out.throttle == 0 && out.commands.isEmpty && out.error == nil)

        var deleted = ManeuverExecutor()
        _ = deleted.step(telemetry(status(toBurn: 600)), mass: mass)
        let gone = deleted.step(telemetry(nil), mass: mass)
        #expect(gone.finished && gone.phase == .stopped)
    }

    // MARK: - Подписи

    @Test func statusTextShowsPhase() {
        let far = telemetry(status(toBurn: 1_901))
        #expect(ManeuverExecutor.statusText(.warping, far) == "Летим к узлу " + HUDFormat.countdown(1_901))
        #expect(ManeuverExecutor.statusText(.aligning, far) == "Разворот")
        let burning = telemetry(status(toBurn: -3, remaining: 312))
        #expect(ManeuverExecutor.statusText(.burning, burning) == "Прожиг · ост " + HUDFormat.speed(312))
    }
}
