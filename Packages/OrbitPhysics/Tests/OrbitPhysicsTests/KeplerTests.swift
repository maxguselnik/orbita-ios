import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Кеплер")
struct KeplerTests {
    let mu = Bodies.terra.mu

    @Test func ellipseMatchesRK4OverDay() {
        // Эллипс LKO-типа с наклоном: Пе ≈ 100 км, Ап ≈ 200 км.
        let r0 = Vec3(700_000, 0, 0)
        let v0 = Vec3(0, 2_330, 300)
        let el = OrbitElements(position: r0, velocity: v0, mu: mu)
        #expect(el.isClosed && el.eccentricity > 0.01)
        let day = 86_400.0
        let k = Kepler.propagate(position: r0, velocity: v0, mu: mu, dt: day)
        let n = Kepler.rk4(position: r0, velocity: v0, mu: mu, dt: day, step: 1)
        #expect((k.position - n.position).length < 1)
        #expect((k.velocity - n.velocity).length < 1e-3)
    }

    @Test func hyperbolaMatchesRK4OverDay() {
        let r0 = Vec3(700_000, 0, 0)
        let v0 = Vec3(0, 4_000, 200)
        let el = OrbitElements(position: r0, velocity: v0, mu: mu)
        #expect(el.eccentricity > 1)
        let day = 86_400.0
        let k = Kepler.propagate(position: r0, velocity: v0, mu: mu, dt: day)
        let n = Kepler.rk4(position: r0, velocity: v0, mu: mu, dt: day, step: 1)
        #expect((k.position - n.position).length < 1)
        // Обратно во времени.
        let back = Kepler.propagate(position: k.position, velocity: k.velocity, mu: mu, dt: -day)
        #expect((back.position - r0).length < 1)
    }

    @Test func nearParabolicMatchesRK4() {
        let r0 = Vec3(0, -800_000, 0)
        let vesc = (2 * mu / 800_000).squareRoot()
        for f in [1 - 1e-9, 1.0, 1 + 1e-9] {
            let v0 = Vec3(vesc * f, 0, 0)
            let k = Kepler.propagate(position: r0, velocity: v0, mu: mu, dt: 6 * 3_600)
            let n = Kepler.rk4(position: r0, velocity: v0, mu: mu, dt: 6 * 3_600, step: 1)
            #expect((k.position - n.position).length < 1)
        }
    }

    @Test func fullPeriodReturnsToStart() {
        let r0 = Vec3(678_000, 0, 0)
        let v0 = Vec3(0, (mu / 678_000).squareRoot() * 1.05, 0)
        let el = OrbitElements(position: r0, velocity: v0, mu: mu)
        let k = Kepler.propagate(position: r0, velocity: v0, mu: mu, dt: el.period * 3)
        #expect((k.position - r0).length < 1e-3)
    }

    @Test func summaryOfCircularAndElliptic() {
        let r = Bodies.terra.radius + 80_000
        let vc = (mu / r).squareRoot()
        let s = OrbitElements(position: Vec3(r, 0, 0), velocity: Vec3(0, vc, 0), mu: mu).summary(body: Bodies.terra)
        #expect(abs(s.apoapsisAltitude - 80_000) < 1)
        #expect(abs(s.periapsisAltitude - 80_000) < 1)
        #expect(abs(s.period - 2 * .pi * (r * r * r / mu).squareRoot()) < 1e-6)
        #expect(s.inclination < 1e-12)
        #expect(s.body == .terra)

        // В перицентре эллипса: до апоцентра — полпериода.
        let e = OrbitElements(position: Vec3(r, 0, 0), velocity: Vec3(0, 0, vc * 1.1), mu: mu)
        #expect(abs((e.timeToApoapsis ?? 0) - e.period / 2) < 1e-3)
        #expect(abs(e.inclination - .pi / 2) < 1e-12)
        #expect(abs(e.periapsisRadius - r) < 1e-3)

        // Гипербола после перицентра: ни Ап, ни Пе впереди.
        let h = OrbitElements(position: Vec3(r, 0, 0), velocity: Vec3(100, vc * 1.6, 0), mu: mu).summary(body: Bodies.terra)
        #expect(h.apoapsisAltitude == .infinity && h.timeToApoapsis == nil && h.timeToPeriapsis == nil)
        #expect(h.period == .infinity)
        // Гипербола до перицентра: время до Пе совпадает с пропагатором.
        let hin = OrbitElements(position: Vec3(r * 3, 0, 0), velocity: Vec3(-2_000, 1_000, 0), mu: mu)
        let tpe = hin.timeToPeriapsis ?? -1
        #expect(tpe > 0)
        let atPe = Kepler.propagate(position: Vec3(r * 3, 0, 0), velocity: Vec3(-2_000, 1_000, 0), mu: mu, dt: tpe)
        #expect(abs(atPe.position.length - hin.periapsisRadius) < 1)
    }
}
