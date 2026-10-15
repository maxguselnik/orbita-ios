import OrbitPhysics
import simd

/// Тряска камеры: постоянная — по скоростному напору q (пик на max Q) и работе двигателей в атмосфере,
/// разовые толчки — зажигание, разделение, max Q, касание, авария. Результат — угловое смещение
/// точки взгляда в долях расстояния до цели (x — вбок, y — вверх).
struct CameraShake {
    /// Напор, при котором тряска максимальна, Па.
    static let fullQ = 25_000.0
    /// Сила тряски от напора и тяги, 0…1 (сглаженная).
    private var steady = 0.0
    /// Затухающий толчок от событий.
    private var kick = 0.0
    /// Ощущение скорости 0…1 (для лёгкого расширения поля зрения), сглаженное.
    private(set) var speedFeel = 0.0

    mutating func update(telemetry t: FlightTelemetry, events: [SimEvent], time: Double, dt: Double) -> SIMD2<Double> {
        let qn = clampd(t.dynamicPressure / Self.fullQ, 0, 1)
        let thrust = t.maxThrust > 0 ? clampd(t.thrust / t.maxThrust, 0, 1) : 0
        let air = clampd(t.staticPressure, 0, 1)
        let grounded = t.situation == .landed || t.situation == .splashed || t.situation == .prelaunch
        let nearGround = grounded ? 0 : thrust * (1 - clampd(t.heightAboveTerrain / 150, 0, 1))
        let target = min(1, qn * 0.85 + thrust * (0.12 + 0.18 * air) * (t.solidBurning ? 1.6 : 1) + nearGround * 0.12)
        let k = 1 - exp(-max(0, dt) * 4)
        steady += (target - steady) * k
        speedFeel += (qn - speedFeel) * (1 - exp(-max(0, dt) * 1.5))

        for e in events {
            switch e {
            case .ignition: kick = max(kick, 0.6)
            case .separation: kick = max(kick, 1)
            case .maxQ: kick = max(kick, 0.35)
            case .chuteOpened: kick = max(kick, 0.5)
            case .touchdown(let speed), .splashdown(let speed): kick = max(kick, clampd(speed / 20, 0, 0.4))
            case .crash: kick = max(kick, 1.6)
            default: break
            }
        }
        kick *= exp(-max(0, dt) * 5)
        if kick < 0.001 { kick = 0 }

        // Амплитуда в радианах: напор до ~0.5°, толчок до ~0.7°.
        let amp = steady * 0.009 + kick * 0.012
        guard amp > 1e-5 else { return .zero }
        let x = sin(time * 37.1) * 0.5 + sin(time * 23.7 + 1.3) * 0.3 + sin(time * 61.3 + 0.7) * 0.2
        let y = sin(time * 41.9 + 2.1) * 0.5 + sin(time * 19.3 + 0.4) * 0.3 + sin(time * 71.7) * 0.2
        return SIMD2(x, y) * amp
    }
}
