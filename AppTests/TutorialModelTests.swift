import CoreGraphics
import Testing
import OrbitPhysics
@testable import Orbita

/// Урок «К Луне» в модели полёта: карта на паузе урока.
@MainActor
struct TutorialModelTests {
    @Test func lessonUnavailableHidesExpertOnlyElements() {
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
        #expect(tutorial.display.progress == LessonProgress(step: 1, total: 10))

        model.toggleMap()
        model.tick(now: 1.1)
        #expect(tutorial.stepIndex == LunaStep.lunaNode.rawValue)
        #expect(tutorial.display.target == .mapLuna)
        // Прогноз карты считается и на паузе урока: фаза Луны есть — кнопка «К Луне» видна.
        #expect(model.map.snapshot.lunaPhase != nil)
        let time = model.snapshot.time

        // Кнопка цели «К Луне» в колонке «Куда летим?».
        #expect(model.availableGoals.contains(.toLuna))
        #expect(!model.mapExpert)
        model.planManeuver(.toLuna)
        #expect(model.maneuverGoal == .toLuna)
        model.tick(now: 1.2)
        #expect(tutorial.stepIndex == LunaStep.encounter.rawValue)
        #expect(model.snapshot.time == time)
        model.tick(now: 1.25)
        #expect(model.map.snapshot.maneuver != nil)
        // «К Луне» сам доводит прогрейд: Пе у Луны по прогнозу карты сразу в диапазоне 15–60 км.
        let peri = try #require(model.lessonInput().lunaPeriapsis)
        #expect((25_000...35_000).contains(peri))
        #expect(LunaStep.periapsisRange.contains(peri))
    }
}
