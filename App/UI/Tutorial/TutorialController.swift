import Foundation
import Observation
import OrbitPhysics

/// Контрольная точка начала шага: состояние физики и положение ручки тяги.
struct LessonCheckpoint {
    let sim: SimCheckpoint
    let throttle: Double
}

/// Что показывает оверлей урока. Меняется только при смене шага/фазы (не каждый кадр).
struct TutorialDisplay: Equatable {
    var step: LessonStep
    var phase: LessonPhase
    var bubble: LessonBubble?
    var target: LessonElement?
    var failure: String?
    /// Есть контрольная точка: на ошибке можно откатить шаг.
    var canRepeat: Bool
}

/// Контроллер урока: логика (`FirstFlightLesson`) плюс наблюдаемое состояние для оверлея.
/// Игровой цикл дёргает `update` каждый кадр; наблюдаемые поля пишутся только при изменении значения.
@MainActor
@Observable
final class TutorialController {
    let id: TutorialID
    private(set) var display: TutorialDisplay
    /// Живая плашка; меняется, когда меняется текст (высота, тангаж, Ап).
    private(set) var plate: LivePlate?
    /// Урок идёт; после «Выйти из урока» — false, полёт обычный.
    private(set) var isActive = true

    @ObservationIgnored private(set) var lesson = FirstFlightLesson()
    @ObservationIgnored private(set) var saved: LessonCheckpoint?

    init(id: TutorialID, telemetry: FlightTelemetry = FlightTelemetry()) {
        self.id = id
        let lesson = FirstFlightLesson()
        self.display = Self.makeDisplay(lesson, telemetry, canRepeat: false)
        self.plate = nil
    }

    /// Игра должна стоять (пауза-объяснение, ожидание действия, откат, ошибка).
    var holdsPhysics: Bool { isActive && lesson.holdsPhysics }

    var step: LessonStep { lesson.step }

    /// Кадр урока. Возвращает true, если начался новый шаг (вызывающий сохраняет контрольную точку).
    func update(_ input: LessonInput, delta: Double) -> Bool {
        guard isActive else { return false }
        let advanced = lesson.update(input, delta: delta)
        if advanced, lesson.step == .finish { TutorialProgress.markFirstFlightDone() }
        refresh(input.telemetry)
        return advanced
    }

    /// «Понятно» / «Поехали». Возвращает true, если начался новый шаг.
    func acknowledge(_ telemetry: FlightTelemetry) -> Bool {
        let advanced = lesson.acknowledge(telemetry)
        refresh(telemetry)
        return advanced
    }

    func saveCheckpoint(_ checkpoint: LessonCheckpoint?, telemetry: FlightTelemetry) {
        saved = checkpoint
        refresh(telemetry)
    }

    /// Мир откатили к контрольной точке.
    func didRestore(_ telemetry: FlightTelemetry) {
        lesson.didRestore(telemetry)
        refresh(telemetry)
    }

    /// Ошибка без отката (нет контрольной точки): продолжить.
    func dismissFailure(_ telemetry: FlightTelemetry) {
        lesson.dismissFailure()
        refresh(telemetry)
    }

    /// Урок с начала (перезапуск полёта).
    func restartLesson(_ telemetry: FlightTelemetry) {
        lesson.reset()
        saved = nil
        refresh(telemetry)
    }

    func exit() {
        isActive = false
        plate = nil
    }

    private func refresh(_ t: FlightTelemetry) {
        let next = Self.makeDisplay(lesson, t, canRepeat: saved != nil)
        if display != next { display = next }
        let nextPlate = livePlate(t)
        if plate != nextPlate { plate = nextPlate }
    }

    private func livePlate(_ t: FlightTelemetry) -> LivePlate? {
        switch lesson.phase {
        case .running, .waiting: lesson.step.plate(t, phase: lesson.phase)
        case .holding, .ready, .failed: nil
        }
    }

    private static func makeDisplay(_ lesson: FirstFlightLesson, _ t: FlightTelemetry, canRepeat: Bool) -> TutorialDisplay {
        var bubble: LessonBubble?
        var target: LessonElement?
        switch lesson.phase {
        case .holding:
            bubble = lesson.step.bubble(t)
            target = lesson.step.target
        case .ready:
            bubble = LessonBubble(title: "Шаг сначала", text: "Полёт возвращён к началу шага. Готовы?", button: "Поехали")
        case .waiting, .running, .failed:
            break
        }
        return TutorialDisplay(step: lesson.step, phase: lesson.phase, bubble: bubble, target: target,
                               failure: lesson.failure, canRepeat: canRepeat)
    }
}
