import Foundation
import Observation
import OrbitPhysics

/// Контрольная точка начала шага: состояние физики и положение ручки тяги.
struct LessonCheckpoint {
    let sim: SimCheckpoint
    let throttle: Double
}

/// Что показывает оверлей урока. Меняется только при смене шага/фазы/текста (не каждый кадр).
struct TutorialDisplay: Equatable {
    var stepIndex: Int
    var phase: LessonPhase
    var scene: LessonScene
    var failure: String?
    /// Есть контрольная точка: на ошибке можно откатить шаг.
    var canRepeat: Bool
    /// «Шаг N из M»; nil на вводном и итоговом шагах.
    var progress: LessonProgress?

    var bubble: LessonBubble? { scene.bubble }
    var target: LessonElement? { scene.target }
    /// Все рамки шага: главная цель первой.
    var targets: [LessonElement] { (scene.target.map { [$0] } ?? []) + scene.alsoTargets }
}

/// Контроллер урока: логика (`TutorialLesson`) плюс наблюдаемое состояние для оверлея.
/// Игровой цикл дёргает `update` каждый кадр; наблюдаемые поля пишутся только при изменении значения.
@MainActor
@Observable
final class TutorialController {
    let id: TutorialID
    private(set) var display: TutorialDisplay
    /// Живая плашка; меняется, когда меняется текст (высота, тангаж, Ап).
    private(set) var plate: LivePlate?
    /// Урок идёт; после «Выйти из урока» (или «Готово» тура) — false, полёт обычный.
    private(set) var isActive = true

    @ObservationIgnored private(set) var lesson: any TutorialLesson
    @ObservationIgnored private(set) var saved: LessonCheckpoint?
    @ObservationIgnored private var marked = false

    init(id: TutorialID, telemetry: FlightTelemetry = FlightTelemetry()) {
        self.id = id
        let lesson = Self.makeLesson(id)
        self.lesson = lesson
        let input = LessonInput(telemetry: telemetry, throttle: 0, yawRightHeld: false)
        self.display = Self.makeDisplay(lesson, input, canRepeat: false)
        self.plate = nil
    }

    /// Урок по его идентификатору.
    static func makeLesson(_ id: TutorialID) -> any TutorialLesson {
        switch id {
        case .firstFlight: return FirstFlightLesson()
        case .toLuna: return LunaLesson()
        }
    }

    /// Игра должна стоять (пауза-объяснение, ожидание действия, откат, ошибка).
    var holdsPhysics: Bool { isActive && lesson.holdsPhysics }

    /// Игра держит ускорение ×1 на этом шаге.
    var forcesRealTime: Bool { isActive && lesson.forcesRealTime }

    var stepIndex: Int { lesson.stepIndex }

    /// Шаг «Первого полёта» (nil — другой урок).
    var firstFlightStep: LessonStep? { (lesson as? FirstFlightLesson)?.step }

    /// Кадр урока. Возвращает true, если начался новый шаг (вызывающий сохраняет контрольную точку).
    func update(_ input: LessonInput, delta: Double) -> Bool {
        guard isActive else { return false }
        let advanced = lesson.update(input, delta: delta)
        refresh(input)
        return advanced
    }

    /// Кнопка пузыря «Понятно» / «Дальше» / «Поехали» / «Готово». Возвращает true, если начался новый шаг.
    func acknowledge(_ input: LessonInput) -> Bool {
        guard isActive else { return false }
        let advanced = lesson.acknowledge(input)
        refresh(input)
        return advanced
    }

    /// «Дальше» на шаге «попробуйте». Возвращает true, если начался новый шаг.
    func skip(_ input: LessonInput) -> Bool {
        guard isActive else { return false }
        let advanced = lesson.skip(input)
        refresh(input)
        return advanced
    }

    func saveCheckpoint(_ checkpoint: LessonCheckpoint?, input: LessonInput) {
        saved = checkpoint
        refresh(input)
    }

    /// Мир откатили к контрольной точке.
    func didRestore(_ input: LessonInput) {
        lesson.didRestore(input)
        refresh(input)
    }

    /// Ошибка без отката (нет контрольной точки): продолжить.
    func dismissFailure(_ input: LessonInput) {
        lesson.dismissFailure()
        refresh(input)
    }

    /// Урок с начала (перезапуск полёта).
    func restartLesson(_ input: LessonInput) {
        lesson.reset()
        saved = nil
        refresh(input)
    }

    func exit() {
        isActive = false
        plate = nil
    }

    private func refresh(_ input: LessonInput) {
        if lesson.reachedEnd, !marked {
            marked = true
            TutorialProgress.markDone(id)
        }
        if lesson.isClosed {
            exit()
            return
        }
        let next = Self.makeDisplay(lesson, input, canRepeat: saved != nil)
        if display != next { display = next }
        let nextPlate = lesson.plate(input)
        if plate != nextPlate { plate = nextPlate }
    }

    private static func makeDisplay(_ lesson: any TutorialLesson, _ input: LessonInput,
                                    canRepeat: Bool) -> TutorialDisplay {
        TutorialDisplay(stepIndex: lesson.stepIndex, phase: lesson.phase, scene: lesson.scene(input),
                        failure: lesson.failure, canRepeat: canRepeat, progress: lesson.progress)
    }
}
