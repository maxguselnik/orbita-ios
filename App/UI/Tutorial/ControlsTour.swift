import Foundation
import OrbitPhysics

/// Урок «Все кнопки»: тур по HUD сверху вниз, затем карта. Шаги «попробуйте» засчитываются по действию
/// или «Дальше»; шаги про элементы, которых нет на экране, пропускаются.
typealias ControlsTour = ScriptLesson<TourStep>

enum TourStep: Int, CaseIterable, ScriptStep {
    case time, altimeter, crew, corner, stages, mission, stageButton, navball, throttle, speed
    case sas, rcs, dpad, fine, mapNode, mapHandles, mapPanel, mapFocus

    static var sequence: [TourStep] { allCases }
    static var endsWithSummary: Bool { false }

    /// Тяга сдвинута на эту долю шкалы — шаг «Дуга тяги» засчитан.
    static let throttleMove = 0.05

    var kind: LessonKind {
        switch self {
        case .time, .throttle, .sas, .dpad: .practice
        default: .pause
        }
    }

    var screen: LessonScreen {
        switch self {
        case .mapNode, .mapHandles, .mapPanel, .mapFocus: .map
        default: .flight
        }
    }

    var target: LessonElement? {
        switch self {
        case .time: .timeBar
        case .altimeter: .altimeter
        case .crew: .crew
        case .corner: .corner
        case .stages: .stageStack
        case .mission: .mission
        case .stageButton: .stageButton
        case .navball: .navball
        case .throttle: .throttle
        case .speed: .speed
        case .sas: .sas
        case .rcs: .rcs
        case .dpad: .dpad
        case .fine: .fine
        case .mapNode: .mapNode
        case .mapHandles: .mapHandle
        case .mapPanel: .mapPanel
        case .mapFocus: .mapFocus
        }
    }

    func isAvailable(_ i: LessonInput) -> Bool {
        switch self {
        // Узел рассказывается и без узла (как его поставить); подсветка — только если он есть.
        case .mapNode: true
        default: target.map { !i.unavailable.contains($0) } ?? true
        }
    }

    func isComplete(_ i: LessonInput, from start: LessonBaseline) -> Bool {
        switch self {
        case .time:
            i.telemetry.warpIndex != start.warpIndex || i.warpMenuCount > start.warpMenuCount
        case .throttle:
            abs(i.throttle - start.throttle) > Self.throttleMove
        case .sas:
            i.telemetry.sas != start.sas
        case .dpad:
            i.dpadHeld
        default:
            false
        }
    }

    func bubble(_ i: LessonInput) -> LessonBubble? {
        let text = Self.texts(self)
        return LessonBubble(title: text.title, text: text.body, button: text.button)
    }

    /// Заголовок, текст и кнопка (nil — «попробуйте»: движок ставит «Дальше» для пропуска).
    static func texts(_ step: TourStep) -> (title: String, body: String, button: String?) {
        switch step {
        case .time:
            ("Время полёта",
             "T+ — сколько прошло с пуска. ▶ ×1 — ускорение: нажмите, чтобы выбрать ×2…×100 000. Около атмосферы и при тяге быстрее нельзя.",
             nil)
        case .altimeter:
            ("Высота", "У земли — над рельефом, выше — над морем. Подпись снизу говорит, какая.", "Дальше")
        case .crew:
            ("Экипаж", "Экипаж реагирует на полёт: перегрузки, тряску, невесомость и посадку.", "Дальше")
        case .corner:
            ("Углы экрана",
             "Карта — орбиты и узлы. Камера — свободная / следом / по курсу. Пауза — меню, ангар, обучение.", "Дальше")
        case .stages:
            ("Ступени и топливо", "Текущая ступень, её топливо, Δv и TWR. Тап — подробно по всем ступеням.", "Дальше")
        case .mission:
            ("Миссия", "Шаги текущей цели. Тап — развернуть.", "Дальше")
        case .stageButton:
            ("ПУСК / ОТДЕЛИТЬ / ПАРАШЮТ", "Одна кнопка: пишет, что сделает сейчас. Цифра — номер ступени.", "Дальше")
        case .navball:
            ("Навбол",
             "Синее — небо, коричневое — земля, жёлтая галочка — нос. Зелёный круг — куда летите, жёлтая метка — куда нужно.",
             "Дальше")
        case .throttle:
            ("Тяга", "Ведите по дуге: вверху MAX, внизу 0.", nil)
        case .speed:
            ("Табло скорости", "ОРБ — орбитальная, ПОВ — относительно земли. Тап меняет. G — перегрузка.", "Дальше")
        case .sas:
            ("Стабилизация",
             "SAS держит нос сам. ▾ — режим: держать, прогрейд, ретро, нормаль, радиаль, узел. Выберите «Прогрейд».",
             nil)
        case .rcs:
            ("Двигатели ориентации", "Мелкие сопла для точного сдвига и стыковки. Нужен блок РСУ на корабле.", "Дальше")
        case .dpad:
            ("Поворот", "▲▼ — нос вверх/вниз, ◀▶ — влево/вправо. Держите — поворот нарастает.", nil)
        case .fine:
            ("Крен и точно", "⟲ ⟳ — вращение вокруг оси. ТОЧНО — в 3 раза мягче для прицеливания.", "Дальше")
        case .mapNode:
            ("Узел манёвра", "Тап по орбите ставит узел — точку будущего прожига.", "Дальше")
        case .mapHandles:
            ("Ручки Δv",
             "Зелёные — по ходу/против, фиолетовые — вбок, голубые — к центру/наружу. Тяните и смотрите, как меняется линия.",
             "Дальше")
        case .mapPanel:
            ("Панель узла", "Точные шаги Δv и времени, «К узлу» — ускорение до прожига, «Удалить».", "Дальше")
        case .mapFocus:
            ("Фокус и «?»", "Вращать карту вокруг корабля, Терры или Луны. «?» — что значат цвета линий.", "Готово")
        }
    }
}
