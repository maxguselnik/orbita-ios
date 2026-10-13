import CoreGraphics
import Testing
import OrbitPhysics
@testable import Orbita

/// Урок «Все кнопки»: «попробуйте» по действию или «Дальше», пропуск отсутствующих элементов, карта.
@MainActor
struct ControlsTourTests {
    private var pad: FlightTelemetry {
        var t = FlightTelemetry(situation: .prelaunch)
        t.nextStageAction = .ignite
        return t
    }

    private func input(_ t: FlightTelemetry? = nil, throttle: Double = 0, map: Bool = false,
                       unavailable: Set<LessonElement> = []) -> LessonInput {
        var i = LessonInput(telemetry: t ?? pad, throttle: throttle, yawRightHeld: false)
        i.mapOpen = map
        i.unavailable = unavailable
        return i
    }

    /// Тур, доведённый до шага `target` кнопками «Дальше» (карта открыта для шагов карты).
    private func tour(at target: TourStep, unavailable: Set<LessonElement> = []) -> ControlsTour {
        var l = ControlsTour()
        for _ in 0..<TourStep.allCases.count {
            if l.step == target { break }
            let i = input(map: l.step.screen == .map, unavailable: unavailable)
            l.update(i, delta: 0.02)
            if l.step == target { break }
            if l.step.kind == .practice { l.skip(i) } else { l.acknowledge(i) }
        }
        #expect(l.step == target)
        return l
    }

    @Test func eighteenStepsTopToBottomThenMap() {
        #expect(TourStep.sequence.count == 18)
        #expect(TourStep.sequence.first == .time && TourStep.sequence.last == .mapFocus)
        let practice = TourStep.sequence.filter { $0.kind == .practice }
        #expect(practice == [.time, .throttle, .sas, .dpad])
        let map = TourStep.sequence.filter { $0.screen == .map }
        #expect(map == [.mapNode, .mapHandles, .mapPanel, .mapFocus])
        for step in TourStep.sequence {
            #expect(step.bubble(input()) != nil)
        }
    }

    @Test func practiceStepHasNextButtonAndPassesTouchesToTheElement() {
        let l = ControlsTour()
        let scene = l.scene(input())
        #expect(scene.target == .timeBar && scene.dims && scene.passThrough && scene.pausedTag)
        #expect(scene.bubble?.button == "Дальше" && scene.bubble?.role == .skip)
        #expect(l.holdsPhysics)
    }

    @Test func warpStepCountsChosenWarpOrOpenedMenu() {
        var byWarp = ControlsTour()
        byWarp.update(input(), delta: 0.02)
        var warped = pad
        warped.warpIndex = 1
        byWarp.update(input(warped), delta: 0.02)
        #expect(byWarp.step == .altimeter)

        var byMenu = ControlsTour()
        byMenu.update(input(), delta: 0.02)
        var opened = input()
        opened.warpMenuCount = 1
        byMenu.update(opened, delta: 0.02)
        #expect(byMenu.step == .altimeter)

        var bySkip = ControlsTour()
        bySkip.update(input(), delta: 0.02)
        let skipped = bySkip.skip(input())
        #expect(skipped && bySkip.step == .altimeter)
    }

    @Test func throttleSasAndDPadCountRealActions() {
        var l = tour(at: .throttle)
        l.update(input(throttle: 0.03), delta: 0.02)
        #expect(l.step == .throttle)
        l.update(input(throttle: 0.4), delta: 0.02)
        #expect(l.step == .speed)

        var sas = tour(at: .sas)
        sas.update(input(), delta: 0.02)
        #expect(sas.step == .sas)
        var t = pad
        t.sas = .prograde
        sas.update(input(t), delta: 0.02)
        #expect(sas.step == .rcs)

        var dpad = tour(at: .dpad)
        dpad.update(input(), delta: 0.02)
        #expect(dpad.step == .dpad)
        var held = input()
        held.dpadHeld = true
        dpad.update(held, delta: 0.02)
        #expect(dpad.step == .fine)
    }

    @Test func pauseStepsNeedTheButton() {
        var l = tour(at: .altimeter)
        l.update(input(), delta: 1)
        #expect(l.step == .altimeter)
        #expect(l.scene(input()).bubble?.button == "Дальше" && !l.scene(input()).passThrough)
        let advanced = l.acknowledge(input())
        #expect(advanced && l.step == .crew)
    }

    @Test func missingElementsAreSkipped() {
        let absent: Set<LessonElement> = [.crew, .rcs, .stageStack, .mission, .mapHandle, .mapPanel]
        var l = tour(at: .altimeter, unavailable: absent)
        l.acknowledge(input(unavailable: absent))
        l.update(input(unavailable: absent), delta: 0.02)
        #expect(l.step == .corner)
        l.acknowledge(input(unavailable: absent))
        l.update(input(unavailable: absent), delta: 0.02)
        #expect(l.step == .stageButton)

        var sas = tour(at: .sas, unavailable: absent)
        sas.skip(input(unavailable: absent))
        sas.update(input(unavailable: absent), delta: 0.02)
        #expect(sas.step == .dpad)

        var map = tour(at: .mapNode, unavailable: absent)
        map.acknowledge(input(map: true, unavailable: absent))
        map.update(input(map: true, unavailable: absent), delta: 0.02)
        #expect(map.step == .mapFocus)
    }

    @Test func presentElementsAreShown() {
        var l = tour(at: .altimeter)
        l.acknowledge(input())
        l.update(input(), delta: 0.02)
        #expect(l.step == .crew && l.scene(input()).target == .crew)
    }

    @Test func mapStepsAskToOpenTheMap() {
        var l = tour(at: .mapNode)
        let closed = input()
        let scene = l.scene(closed)
        #expect(scene.target == .mapButton && scene.passThrough)
        let refused = l.acknowledge(closed)
        #expect(!refused && l.step == .mapNode)
        #expect(l.scene(input(map: true)).target == .mapNode)
        let advanced = l.acknowledge(input(map: true))
        #expect(advanced && l.step == .mapHandles)
    }

    @Test func flightStepsAskToCloseTheMap() {
        let l = ControlsTour()
        let scene = l.scene(input(map: true))
        #expect(scene.target == .mapFlight && scene.bubble?.title == "Полёт")
    }

    @Test func lastStepClosesTheTour() {
        var l = tour(at: .mapFocus)
        #expect(l.scene(input(map: true)).bubble?.button == "Готово")
        #expect(!l.reachedEnd)
        l.acknowledge(input(map: true))
        #expect(l.isClosed && l.reachedEnd && !l.holdsPhysics)
        #expect(l.scene(input(map: true)) == .empty)
    }

    @Test func controllerExitsWhenTourIsDone() {
        let controller = TutorialController(id: .controls)
        #expect(controller.display.target == .timeBar)
        for _ in 0..<TourStep.allCases.count * 2 {
            guard controller.isActive else { break }
            let step = TourStep.sequence[controller.stepIndex]
            let i = input(map: step.screen == .map)
            _ = controller.update(i, delta: 0.02)
            if step.kind == .practice { _ = controller.skip(i) } else { _ = controller.acknowledge(i) }
        }
        #expect(!controller.isActive && !controller.holdsPhysics)
        #expect(TutorialProgress.isDone(.controls))
    }
}
