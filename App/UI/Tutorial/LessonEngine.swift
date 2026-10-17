import Foundation
import OrbitPhysics

// MARK: - Общие типы уроков

/// Элемент HUD или карты, который урок подсвечивает (ключ рамки в `TutorialAnchorKey`).
enum LessonElement: Hashable, Sendable {
    // Полёт
    case mission, throttle, stageButton, dpadRight, warp
    case timeBar, altimeter, crew, corner, mapButton, stageStack
    case navball, speed, sas, rcs, dpad, fine
    /// Строка «Ап …» у высотомера.
    case apoapsis
    // Карта
    case mapLuna, mapSummary, mapHandle, mapToNode, mapSASNode, mapPanel, mapFocus, mapLegend, mapNode, mapFlight
    /// Колонка целей «Куда летим?» и кнопка «Выполнить манёвр» простой карты.
    case mapGoals, mapExecute
    /// Кнопка цели «Скруглить орбиту».
    case mapCircularize
    /// «Промотать до встречи» в карточке карты.
    case encounterWarp
}

/// Вид шага: `pause` — игра на паузе, ждём кнопку в пузыре; `wait` — пауза, ждём действие игрока
/// (после него пауза снимается); `live` — полёт идёт, сверху живая плашка; `practice` («попробуйте») — как `wait`,
/// но в пузыре есть «Дальше» для пропуска.
enum LessonKind: Sendable {
    case pause, wait, live, practice
}

/// Где идёт шаг: в полёте, на карте или где угодно. Шаг не на своём экране просит открыть/закрыть карту.
enum LessonScreen: Sendable {
    case flight, map, any
}

/// Что урок видит в игре за кадр.
struct LessonInput: Equatable {
    var telemetry: FlightTelemetry
    /// Положение ручки тяги 0…1 (на паузе физики она ещё не в снимке).
    var throttle: Double
    /// Удерживается ▶ крестовины (рыскание вправо — разворот на восток).
    var yawRightHeld: Bool
    /// Нажата любая кнопка крестовины (тангаж или рыскание).
    var dpadHeld = false
    /// Карта открыта.
    var mapOpen = false
    /// Идёт автопрожиг («Выполнить манёвр»).
    var autoBurn = false
    /// Сколько раз открывалось меню ускорения времени (счётчик растёт).
    var warpMenuCount = 0
    /// Пе у Луны по прогнозу карты (после узла, если он не выполнен), м; nil — встречи нет.
    var lunaPeriapsis: Double?
    /// Момент входа в SOI Луны по прогнозу карты (время симуляции), с.
    var encounterTime: Double?
    /// Время симуляции, с.
    var time = 0.0
    /// Скорость последнего касания поверхности, м/с.
    var touchdownSpeed: Double?
    /// Элементы, которых сейчас нет на экране (нет экипажа, РСУ, узла…): шаги про них пропускаются.
    var unavailable: Set<LessonElement> = []
}

/// Что делает кнопка пузыря.
enum LessonButtonRole: Equatable, Sendable {
    /// «Понятно», «Дальше», «Поехали», «Готово» — следующий шаг.
    case next
    /// «Дальше» на шаге «попробуйте» — пропустить.
    case skip
    /// «В ангар» на итоге.
    case hangar
}

/// Пузырь подсказки: заголовок, текст, кнопка (nil — ждём действие в игре).
struct LessonBubble: Equatable {
    var title: String
    var text: String
    var button: String?
    var role: LessonButtonRole = .next
    /// Подпись ссылки выхода (nil — «Выйти из урока»); на итоге — «Остаться на орбите» и т. п.
    var exitTitle: String?
    /// Пояснение «Зачем?» (1–2 строки); nil — кнопки «Зачем?» нет.
    var why: String?

    /// После отката шага.
    static let restart = LessonBubble(title: "Шаг сначала", text: "Полёт возвращён к началу шага. Готовы?",
                                      button: "Поехали")
}

/// Номер шага для плашки «Шаг N из M» (считаются только видимые шаги урока).
struct LessonProgress: Equatable, Sendable {
    var step: Int
    var total: Int

    var text: String { "Шаг \(step) из \(total)" }
}

extension LivePlate {
    /// Плашка автопрожига: путь к узлу, затем остаток Δv.
    static func burn(_ i: LessonInput) -> LivePlate {
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

/// Живая плашка: «голова», выделенное число и «хвост».
struct LivePlate: Equatable {
    var head: String
    var value: String
    var tail = ""
}

/// Состояние урока на текущем шаге.
enum LessonPhase: Equatable, Sendable {
    /// Шаг ещё не наступил (ждём в полёте: пустая ступень, Ап 80 км).
    case waiting
    /// Игра на паузе, затемнение, ждём действие игрока.
    case holding
    /// Полёт идёт, живая плашка.
    case running
    /// Шаг откатили; игра на паузе, ждём «Поехали».
    case ready
    /// Ошибка шага; игра на паузе, ждём «Повторить шаг».
    case failed
}

/// Что рисует оверлей на текущем шаге (без чисел кадра — они в `LivePlate`).
struct LessonScene: Equatable {
    var bubble: LessonBubble?
    var target: LessonElement?
    /// Дополнительные рамки шага (например, «Ап» рядом с тягой); стрелка ведёт к `target`.
    var alsoTargets: [LessonElement] = []
    /// Затемнение с вырезом вокруг цели.
    var dims = false
    /// Касания внутри выреза проходят к контролу (шаг ждёт действия).
    var passThrough = false
    /// Подсветка только рамкой, без затемнения; касания проходят везде.
    var ringOnly = false
    /// Метка «⏸ пауза — ждём действие».
    var pausedTag = false
    /// Полоса живой плашки / ошибки сверху.
    var plateBar = false

    static let empty = LessonScene()
}

/// Состояние игры в начале шага: с ним сравниваются действия «попробуйте» (тяга сдвинута, SAS сменил режим…).
struct LessonBaseline: Equatable, Sendable {
    var throttle = 0.0
    var sas: SASMode = .off
    var warpIndex = 0
    var warpMenuCount = 0

    init() {}

    init(_ i: LessonInput) {
        throttle = i.throttle
        sas = i.telemetry.sas
        warpIndex = i.telemetry.warpIndex
        warpMenuCount = i.warpMenuCount
    }
}

// MARK: - Протокол урока

/// Чистая логика урока (без UI и физики): шаг, фаза, ошибка, что показать. Реализации — `FirstFlightLesson`,
/// `ScriptLesson<LunaStep>`.
protocol TutorialLesson: Sendable {
    var phase: LessonPhase { get }
    /// Физика стоит: пауза-объяснение, ожидание действия, откат или ошибка.
    var holdsPhysics: Bool { get }
    var failure: String? { get }
    /// Номер текущего шага (для смены контрольной точки и тестов).
    var stepIndex: Int { get }
    /// «Шаг N из M»; nil на вводном и итоговом шагах.
    var progress: LessonProgress? { get }
    /// Урок пройден: дошли до итога.
    var reachedEnd: Bool { get }
    /// Урок закрылся сам — оверлей убирается.
    var isClosed: Bool { get }
    /// Игра держит ускорение ×1 (шаг, где рельсы мешают).
    var forcesRealTime: Bool { get }

    /// Кадр урока. Возвращает true, если шаг сменился (нужна контрольная точка).
    @discardableResult mutating func update(_ i: LessonInput, delta: Double) -> Bool
    /// Кнопка «Понятно» / «Дальше» / «Поехали» / «Готово». Возвращает true, если шаг сменился.
    @discardableResult mutating func acknowledge(_ i: LessonInput) -> Bool
    /// «Дальше» на шаге «попробуйте». Возвращает true, если шаг сменился.
    @discardableResult mutating func skip(_ i: LessonInput) -> Bool
    /// Мир откатили к началу шага.
    mutating func didRestore(_ i: LessonInput)
    /// Ошибка без отката: продолжить как было.
    mutating func dismissFailure()
    /// Урок с начала.
    mutating func reset()

    func scene(_ i: LessonInput) -> LessonScene
    func plate(_ i: LessonInput) -> LivePlate?
}

// MARK: - Урок по сценарию шагов

/// Шаг урока-сценария: вид, экран, подсветка, условия и тексты.
protocol ScriptStep: Hashable, Sendable {
    /// Шаги по порядку.
    static var sequence: [Self] { get }
    /// Последний шаг — итог с «В ангар»: урок пройден, когда до него дошли.
    static var endsWithSummary: Bool { get }

    var kind: LessonKind { get }
    var screen: LessonScreen { get }
    var target: LessonElement? { get }
    /// Дополнительные рамки шага.
    var alsoTargets: [LessonElement] { get }
    /// Шаг считается в «Шаг N из M» (вводный и итоговый — нет).
    var numbered: Bool { get }
    /// Шаг ожидания без затемнения: подсветка рамкой, остальной экран доступен (ручки карты).
    var freeHands: Bool { get }
    /// Живая плашка видна и пока игра стоит на шаге (иначе — только когда полёт идёт).
    var platesWhileHolding: Bool { get }

    /// Элемент шага есть на экране; иначе шаг пропускается.
    func isAvailable(_ i: LessonInput) -> Bool
    /// Шаг `wait`: игрок начал действие — пауза снимается.
    func trigger(_ i: LessonInput, from start: LessonBaseline) -> Bool
    /// Игра стоит на шаге, а то, что он делает (узел), исчезло: шаг, на который нужно вернуться.
    func fallback(_ i: LessonInput) -> Self?
    /// Шаг выполнен (для `pause` не спрашивается — только кнопкой).
    func isComplete(_ i: LessonInput, from start: LessonBaseline) -> Bool
    /// Ошибка шага в полёте (nil — всё в порядке).
    func failure(_ i: LessonInput) -> String?
    func bubble(_ i: LessonInput) -> LessonBubble?
    func plate(_ i: LessonInput) -> LivePlate?
}

extension ScriptStep {
    var alsoTargets: [LessonElement] { [] }
    var numbered: Bool { true }
    func fallback(_ i: LessonInput) -> Self? { nil }
    var freeHands: Bool { false }
    var platesWhileHolding: Bool { false }
    func isAvailable(_ i: LessonInput) -> Bool { true }
    func trigger(_ i: LessonInput, from start: LessonBaseline) -> Bool { false }
    func failure(_ i: LessonInput) -> String? { nil }
    func plate(_ i: LessonInput) -> LivePlate? { nil }
}

/// Шаг не на своём экране: попросить открыть или закрыть карту.
enum LessonGate: Equatable, Sendable {
    case openMap, closeMap

    var bubble: LessonBubble {
        switch self {
        case .openMap:
            LessonBubble(title: "Карта", text: "Этот шаг — на карте. Нажмите кнопку карты.", button: nil)
        case .closeMap:
            LessonBubble(title: "Полёт", text: "Этот шаг — в полёте. Нажмите «Полёт».", button: nil)
        }
    }

    var target: LessonElement {
        switch self {
        case .openMap: .mapButton
        case .closeMap: .mapFlight
        }
    }
}

/// Движок урока по списку шагов `Step.sequence`: паузы, ожидания, живые шаги, «попробуйте», пропуск отсутствующих
/// элементов, просьба открыть карту, ошибка и откат шага.
struct ScriptLesson<Step: ScriptStep>: TutorialLesson {
    private(set) var stepIndex = 0
    private(set) var phase: LessonPhase
    private(set) var failure: String?
    /// Закрыт кнопкой последнего шага.
    private(set) var finished = false
    /// Состояние игры в начале шага (ставится первым кадром шага).
    private(set) var baseline = LessonBaseline()
    private var hasBaseline = false
    private var phaseBeforeFailure: LessonPhase = .running

    init() {
        phase = Self.startPhase(Step.sequence[0])
    }

    var step: Step { Step.sequence[stepIndex] }
    var isLast: Bool { stepIndex == Step.sequence.count - 1 }

    var holdsPhysics: Bool {
        !finished && (phase == .holding || phase == .ready || phase == .failed)
    }

    var reachedEnd: Bool { finished || (Step.endsWithSummary && isLast) }

    var progress: LessonProgress? {
        guard step.numbered else { return nil }
        let numbered = Step.sequence.filter(\.numbered)
        guard let index = numbered.firstIndex(of: step) else { return nil }
        return LessonProgress(step: index + 1, total: numbered.count)
    }
    var isClosed: Bool { finished }
    var forcesRealTime: Bool { false }

    static func startPhase(_ step: Step) -> LessonPhase {
        step.kind == .live ? .running : .holding
    }

    /// Шаг ждёт не на своём экране (только пока игра стоит на шаге).
    func gate(_ i: LessonInput) -> LessonGate? {
        guard phase == .holding, step.kind != .live else { return nil }
        switch step.screen {
        case .map: return i.mapOpen ? nil : .openMap
        case .flight: return i.mapOpen ? .closeMap : nil
        case .any: return nil
        }
    }

    @discardableResult
    mutating func update(_ i: LessonInput, delta: Double) -> Bool {
        guard !finished else { return false }
        prepare(i)
        var advanced = false
        for _ in 0..<Step.sequence.count {
            let s = step
            if !s.isAvailable(i), !isLast {
                advance(i)
                advanced = true
                continue
            }
            if phase == .holding {
                if gate(i) == nil, let back = s.fallback(i), let index = Step.sequence.firstIndex(of: back) {
                    stepIndex = index
                    phase = Self.startPhase(step)
                    baseline = LessonBaseline(i)
                    advanced = true
                    break
                }
                if s.kind != .pause, s.isComplete(i, from: baseline), advance(i) {
                    advanced = true
                    continue
                }
                if s.kind == .wait, gate(i) == nil, s.trigger(i, from: baseline) { phase = .running }
            } else if phase == .running {
                if s.isComplete(i, from: baseline), advance(i) {
                    advanced = true
                    continue
                }
                if let message = s.failure(i) { fail(message) }
            }
            break
        }
        return advanced
    }

    @discardableResult
    mutating func acknowledge(_ i: LessonInput) -> Bool {
        prepare(i)
        if phase == .ready {
            phase = Self.startPhase(step)
            return false
        }
        guard !finished, phase == .holding, step.kind == .pause, gate(i) == nil else { return false }
        if isLast {
            finished = true
            return false
        }
        return advance(i)
    }

    @discardableResult
    mutating func skip(_ i: LessonInput) -> Bool {
        guard !finished, phase == .holding, step.kind == .practice else { return false }
        return advance(i)
    }

    mutating func didRestore(_ i: LessonInput) {
        failure = nil
        baseline = LessonBaseline(i)
        hasBaseline = true
        phase = step.kind == .live ? .ready : .holding
    }

    mutating func dismissFailure() {
        guard phase == .failed else { return }
        failure = nil
        phase = phaseBeforeFailure
    }

    mutating func reset() {
        self = ScriptLesson()
    }

    func scene(_ i: LessonInput) -> LessonScene {
        guard !finished else { return .empty }
        switch phase {
        case .ready:
            return LessonScene(bubble: .restart, dims: true)
        case .failed:
            return LessonScene(plateBar: true)
        case .running, .waiting:
            let live = step.kind == .live && step.target != nil
            return LessonScene(target: live ? step.target : nil, alsoTargets: live ? step.alsoTargets : [],
                               ringOnly: live, plateBar: true)
        case .holding:
            if let gate = gate(i) {
                return LessonScene(bubble: gate.bubble, target: gate.target, dims: true, passThrough: true,
                                   pausedTag: true)
            }
            let s = step
            var bubble = s.bubble(i)
            if s.kind == .practice, bubble != nil, bubble?.button == nil {
                bubble?.button = "Дальше"
                bubble?.role = .skip
            }
            let waits = s.kind != .pause
            return LessonScene(bubble: bubble, target: s.target, alsoTargets: s.alsoTargets, dims: !s.freeHands,
                               passThrough: waits,
                               ringOnly: s.freeHands, pausedTag: waits && !s.freeHands,
                               plateBar: s.platesWhileHolding && s.plate(i) != nil)
        }
    }

    func plate(_ i: LessonInput) -> LivePlate? {
        guard !finished else { return nil }
        switch phase {
        case .running, .waiting: return step.plate(i)
        case .holding: return gate(i) == nil && step.platesWhileHolding ? step.plate(i) : nil
        case .ready, .failed: return nil
        }
    }

    // MARK: - Внутреннее

    /// Первый кадр урока: запомнить состояние игры для сравнения действий.
    private mutating func prepare(_ i: LessonInput) {
        guard !hasBaseline else { return }
        baseline = LessonBaseline(i)
        hasBaseline = true
    }

    /// Следующий шаг; false — шаг последний.
    @discardableResult
    private mutating func advance(_ i: LessonInput) -> Bool {
        guard !isLast else { return false }
        stepIndex += 1
        phase = Self.startPhase(step)
        failure = nil
        baseline = LessonBaseline(i)
        hasBaseline = true
        return true
    }

    private mutating func fail(_ message: String) {
        phaseBeforeFailure = phase
        failure = message
        phase = .failed
    }
}
