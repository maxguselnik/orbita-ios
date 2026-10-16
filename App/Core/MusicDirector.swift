import OrbitPhysics

/// Настроение музыки: где игрок и что происходит. Синтез — поток D (`GameMusic`).
enum MusicMood: String, CaseIterable, Sendable {
    /// Космоцентр, цех, исследования — тёплая спокойная тема.
    case spaceCenter
    /// На стартовом столе — ожидание, тихий пульс.
    case countdown
    /// Взлёт с тягой в атмосфере — подъём, ритм.
    case ascent
    /// Орбита или суборбита у Терры — простор, колокольчики.
    case orbit
    /// Перелёт: SOI Солнца или уход с орбиты — редкие низкие ноты, пустота.
    case voyage
    /// Полёт и орбита у чужого тела — окраска лада по телу.
    case alienOrbit
    /// Снижение к грунту чужого тела — напряжение.
    case descent
    /// Сильный нагрев при входе в атмосферу — тревога.
    case reentry
    /// На грунте чужого тела — изумление, редкие ноты.
    case surface
    /// Посадка или приводнение на Терре после полёта — разрешение, тёплый аккорд.
    case homecoming
    /// Авария — короткий низкий аккорд и тишина.
    case crash
}

/// Что играть: настроение, тело (тональность и окраска) и напряжённость 0…1 (плотность и громкость слоёв).
struct MusicCue: Equatable, Sendable {
    var mood: MusicMood
    var body: BodyID = .terra
    var intensity: Double = 0.5
}

/// Где сейчас игрок вне полёта/в полёте.
enum MusicPlace: Equatable {
    case menu
    case flight(FlightTelemetry)
}

/// Выбирает настроение по месту и телеметрии и сглаживает смены: новое настроение должно
/// продержаться `hold` секунд, срочные (авария, нагрев) — сразу.
@MainActor
final class MusicDirector {
    /// Сколько секунд кандидат должен держаться до смены.
    static let hold = 4.0

    private(set) var current: MusicCue?
    private var candidate: MusicMood?
    private var candidateSince = 0.0

    /// Возвращает реплику, когда настроение сменилось (или впервые), иначе nil.
    /// Напряжённость и тело внутри того же настроения тоже обновляются (без кроссфейда темы).
    func update(_ place: MusicPlace, now: Double) -> MusicCue? {
        var target = Self.cue(for: place, previous: current?.mood)
        // Шаг 0.1 — чтобы не слать реплику каждый кадр из-за дрожания тяги.
        target.intensity = (min(max(target.intensity, 0), 1) * 10).rounded() / 10
        guard let cur = current else {
            current = target
            candidate = nil
            return target
        }
        if target.mood == cur.mood {
            candidate = nil
            guard target != cur else { return nil }
            current = target
            return target
        }
        if Self.urgent(target.mood) || cur.mood == .crash && target.mood == .spaceCenter {
            current = target
            candidate = nil
            return target
        }
        if candidate != target.mood {
            candidate = target.mood
            candidateSince = now
            return nil
        }
        guard now - candidateSince >= Self.hold else { return nil }
        current = target
        candidate = nil
        return target
    }

    /// Сброс: новый полёт или возврат в меню — следующая реплика без ожидания.
    func reset() {
        current = nil
        candidate = nil
    }

    private static func urgent(_ mood: MusicMood) -> Bool {
        mood == .crash || mood == .reentry || mood == .spaceCenter || mood == .countdown
    }

    /// Чистое правило выбора; `previous` даёт гистерезис нагрева.
    static func cue(for place: MusicPlace, previous: MusicMood? = nil) -> MusicCue {
        guard case .flight(let t) = place else { return MusicCue(mood: .spaceCenter, intensity: 0.3) }
        let body = t.body
        let throttle = t.maxThrust > 0 ? min(max(t.thrust / t.maxThrust, 0), 1) : 0
        let heatEnter = previous == .reentry ? 0.15 : 0.3

        switch t.situation {
        case .crashed:
            return MusicCue(mood: .crash, body: body, intensity: 0)
        case .prelaunch:
            return MusicCue(mood: .countdown, body: body, intensity: 0.3)
        case .landed, .splashed:
            if body == .terra {
                // Покачался на площадке и сел — не «возвращение», а снова ожидание.
                return t.mission.maxAltitude > 1_000
                    ? MusicCue(mood: .homecoming, body: body, intensity: 0.4)
                    : MusicCue(mood: .countdown, body: body, intensity: 0.3)
            }
            return MusicCue(mood: .surface, body: body, intensity: 0.3)
        case .flying, .suborbital, .orbiting, .escaping:
            break
        }

        if t.heating >= heatEnter {
            return MusicCue(mood: .reentry, body: body, intensity: min(max(t.heating, 0), 1))
        }
        if body == .sol || t.situation == .escaping {
            return MusicCue(mood: .voyage, body: body, intensity: 0.2 + 0.5 * throttle)
        }
        let falling = t.situation != .orbiting && t.verticalSpeed < -5
        if body == .terra {
            if t.atmosphereDensity > 0, throttle > 0.05, t.verticalSpeed > 0, t.situation != .orbiting {
                return MusicCue(mood: .ascent, body: body, intensity: 0.4 + 0.6 * throttle)
            }
            return MusicCue(mood: .orbit, body: body, intensity: 0.3 + 0.4 * throttle)
        }
        // Чужое тело: снижение — низко над грунтом и падаем, иначе орбита/облёт.
        if falling, t.heightAboveTerrain < 15_000 {
            let closeness = 1 - min(max(t.heightAboveTerrain / 15_000, 0), 1)
            return MusicCue(mood: .descent, body: body, intensity: 0.4 + 0.6 * closeness)
        }
        return MusicCue(mood: .alienOrbit, body: body, intensity: 0.3 + 0.4 * throttle)
    }
}
