import CoreGraphics
import Testing
import OrbitPhysics
@testable import Orbita

/// Уроки «К Луне» и «Все кнопки» в модели полёта: карта на паузе урока, тур поверх текущего полёта.
@MainActor
struct TutorialModelTests {
    @Test func tourStartsOverCurrentFlightWithoutRestart() throws {
        let model = FlightHUDModel(makeSimulation: { FlightSim(design: .orbit) })
        #expect(model.tutorial == nil)
        model.tick(now: 1)
        model.throttle = 0.3
        model.pause()
        model.startTour()
        let tour = try #require(model.tutorial)
        #expect(tour.id == .controls && !model.isPaused && tour.holdsPhysics)
        #expect(model.throttle == 0.3)

        model.tick(now: 1.05)
        #expect(tour.stepIndex == TourStep.time.rawValue)
        model.noteWarpMenu()
        model.tick(now: 1.1)
        #expect(tour.stepIndex == TourStep.altimeter.rawValue)
        model.tutorialAcknowledge()
        model.tick(now: 1.15)
        let next: TourStep = CrewPlaceholder.hasCabin(model.parts) ? .crew : .corner
        #expect(tour.stepIndex == next.rawValue)

        model.exitTutorial()
        #expect(!tour.isActive && !tour.holdsPhysics)
    }

    @Test func tourSkipsCrewAndRcsWhenShipHasNone() {
        let model = FlightHUDModel(makeSimulation: { FlightSim(design: .orbit) })
        let unavailable = model.lessonInput().unavailable
        #expect(unavailable.contains(.rcs) == !model.rcs.available)
        #expect(unavailable.contains(.mapHandle) && unavailable.contains(.mapPanel))
    }

    @Test func lunaLessonPlacesNodeOnMapWhilePhysicsIsHeld() throws {
        let model = FlightHUDModel(makeSimulation: { TutorialID.toLuna.makeSimulation() }, tutorial: .toLuna)
        let tutorial = try #require(model.tutorial)
        #expect(model.telemetry.situation == .orbiting)
        model.tick(now: 1)
        #expect(tutorial.stepIndex == LunaStep.intro.rawValue && tutorial.holdsPhysics)
        model.tutorialAcknowledge()
        model.tick(now: 1.05)
        #expect(tutorial.stepIndex == LunaStep.openMap.rawValue)
        #expect(tutorial.display.target == .mapButton)

        model.toggleMap()
        model.tick(now: 1.1)
        #expect(tutorial.stepIndex == LunaStep.mapIntro.rawValue)
        // Прогноз карты считается и на паузе урока: фаза Луны есть — кнопка «К Луне» видна.
        #expect(model.map.snapshot.lunaPhase != nil)
        let time = model.snapshot.time
        model.tutorialAcknowledge()
        model.tick(now: 1.15)
        #expect(tutorial.stepIndex == LunaStep.lunaNode.rawValue)

        model.send(.setManeuver(DemoScenario.lunaTransferNode(model.snapshot)))
        model.tick(now: 1.2)
        #expect(tutorial.stepIndex == LunaStep.encounter.rawValue)
        #expect(model.snapshot.time == time)
        model.tick(now: 1.25)
        #expect(model.map.snapshot.maneuver != nil)
        // «К Луне» сам доводит прогрейд: Пе у Луны по прогнозу карты сразу в диапазоне шага «Ручки Δv».
        let peri = try #require(model.lessonInput().lunaPeriapsis)
        #expect((25_000...35_000).contains(peri))
        #expect(LunaStep.periapsisRange.contains(peri))
    }
}
