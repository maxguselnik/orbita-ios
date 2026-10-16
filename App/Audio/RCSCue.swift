import OrbitPhysics

/// Уровень команды РСУ по типам топлива для звука и вибрации (контракт «Звук, вибрация и струи РСУ»).
enum RCSCue {
    /// `max(|tr|, |rot|)` по осям, обрезан до 0…1; тип не в `rcsFuels` или корабль разбит — 0.
    static func levels(_ v: VesselState?) -> (mono: Double, gas: Double) {
        guard let v, v.situation != .crashed else { return (0, 0) }
        let tr = v.rcsTranslation, rot = v.rcsRotation
        let raw = max(abs(tr.x), abs(tr.y), abs(tr.z), abs(rot.x), abs(rot.y), abs(rot.z))
        let level = min(max(raw, 0), 1)
        return (v.rcsFuels.contains(.mono) ? level : 0, v.rcsFuels.contains(.gas) ? level : 0)
    }
}

/// Включение сопел типа для щелчка клапана и вибро-тапа: гистерезис (вкл. ≥ `onLevel`, выкл. < `offLevel`)
/// и пауза: новое включение засчитывается, только если сопла молчали ≥ `quiet` с. Иначе SAS, который держит
/// ориентацию у порога, «тикал» бы без команды игрока.
struct RCSOnset {
    var onLevel = 0.05
    var offLevel = 0.01
    var quiet = 0.15
    private var on = false
    private var offSince: Double?

    /// true — сопла этого типа только что включились после паузы.
    mutating func update(level: Double, now: Double) -> Bool {
        if on {
            if level < offLevel {
                on = false
                offSince = now
            }
            return false
        }
        guard level >= onLevel else { return false }
        on = true
        if let offSince, now - offSince < quiet - 1e-9 { return false }
        return true
    }
}

/// Ограничитель частоты вибро-тапов РСУ: не чаще одного за `minInterval` секунд.
struct RCSTapLimiter {
    var minInterval = 0.1
    private var last: Double?

    mutating func allow(now: Double) -> Bool {
        if let last, now - last < minInterval - 1e-9 { return false }
        last = now
        return true
    }
}
