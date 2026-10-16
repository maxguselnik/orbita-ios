import OrbitPhysics
import Testing
@testable import Orbita

@Suite("Звук и вибрация РСУ")
struct RCSFeedbackTests {
    private func vessel(tr: Vec3 = .zero, rot: Vec3 = .zero, fuels: Set<FuelType> = [],
                        situation: VesselSituation = .flying) -> VesselState {
        var v = VesselState(id: 1, body: BodyID.allCases[0], position: .zero, velocity: .zero, mass: 1000,
                            situation: situation, rcsTranslation: tr, rcsRotation: rot)
        v.rcsFuels = fuels
        return v
    }

    @Test func zeroWithoutCommandOrVessel() {
        let none = RCSCue.levels(nil)
        #expect(none.mono == 0 && none.gas == 0)
        let idle = RCSCue.levels(vessel(fuels: [.mono, .gas]))
        #expect(idle.mono == 0 && idle.gas == 0)
    }

    @Test func onlyMono() {
        let l = RCSCue.levels(vessel(tr: Vec3(0, 0.5, 0), fuels: [.mono]))
        #expect(l.mono == 0.5)
        #expect(l.gas == 0)
    }

    @Test func both() {
        let l = RCSCue.levels(vessel(rot: Vec3(0, 0, -0.4), fuels: [.mono, .gas]))
        #expect(l.mono == 0.4)
        #expect(l.gas == 0.4)
    }

    @Test func typeWithoutFuelIsSilent() {
        let l = RCSCue.levels(vessel(tr: Vec3(1, 0, 0), fuels: [.gas]))
        #expect(l.mono == 0)
        #expect(l.gas == 1)
    }

    @Test func crashedIsSilent() {
        let l = RCSCue.levels(vessel(tr: Vec3(1, 0, 0), fuels: [.mono, .gas], situation: .crashed))
        #expect(l.mono == 0 && l.gas == 0)
    }

    @Test func levelIsMaxOfComponentsAndClamped() {
        let l = RCSCue.levels(vessel(tr: Vec3(0.2, -0.3, 0), rot: Vec3(0.1, 0, 0.7), fuels: [.mono]))
        #expect(l.mono == 0.7)
        let over = RCSCue.levels(vessel(tr: Vec3(-2, 0, 0), fuels: [.mono]))
        #expect(over.mono == 1)
    }

    @Test func limiterSpacing() {
        var limiter = RCSTapLimiter()
        let first = limiter.allow(now: 10)
        let early = limiter.allow(now: 10.05)
        let later = limiter.allow(now: 10.1)
        #expect(first)
        #expect(!early)
        #expect(later)
    }

    @Test func onsetOnlyAfterQuietPause() {
        var onset = RCSOnset()
        // уровень, время → ожидаемое включение: первое, удержание, выкл., пауза 0.1 с (мало), выкл., пауза 0.2 с.
        let steps: [(Double, Double, Bool)] = [(0.6, 0, true), (0.6, 0.02, false), (0, 0.1, false),
                                               (0.6, 0.2, false), (0, 0.3, false), (0.6, 0.5, true)]
        let fired = steps.map { onset.update(level: $0.0, now: $0.1) }
        #expect(fired == steps.map(\.2))
    }

    @Test func onsetHysteresisIgnoresSASJitter() {
        // SAS у цели: уровень дрожит около 0.005–0.04 — ни одного включения.
        var onset = RCSOnset()
        var fired = 0
        for i in 0..<200 where onset.update(level: i % 2 == 0 ? 0.04 : 0.005, now: Double(i) * 0.02) { fired += 1 }
        #expect(fired == 0)
        // После включения уровень 0.02 держит сопла включёнными — повторных включений нет.
        let first = onset.update(level: 0.3, now: 10)
        var repeats = 0
        for i in 1...50 where onset.update(level: 0.02, now: 10 + Double(i) * 0.02) { repeats += 1 }
        #expect(first)
        #expect(repeats == 0)
    }
}
