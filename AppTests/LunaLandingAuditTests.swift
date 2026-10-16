import OrbitPhysics
import simd
import Testing
@testable import Orbita

/// Диагностика реальной посадки: физическое состояние и геометрия проверяются раздельно.
@MainActor
struct LunaLandingAuditTests {
    @Test func touchdownAndRenderedSurface() throws {
        let sim = DemoScenario.lunaTouchdown.makeSimulation()
        #expect(sim.snapshot.telemetry.body == .luna)
        var contacts = 0
        var landedFixed: Vec3?
        var maxDrift = 0.0
        var maxGroundError = 0.0
        var maxPostContactThrust = 0.0
        var maxBounceHeight = 0.0
        for _ in 0..<1_800 {
            let events = sim.advance(realDelta: 1.0 / 60)
            let newContacts = events.filter { if case .touchdown = $0 { return true }; return false }.count
            contacts += newContacts
            if newContacts > 0 {
                print("LUNA_AUDIT contact time=\(sim.snapshot.time) height=\(sim.snapshot.telemetry.heightAboveTerrain) thrust=\(sim.snapshot.telemetry.thrust) events=\(events)")
            }
            let snapshot = sim.snapshot
            if contacts > 0 && snapshot.telemetry.situation != .landed {
                maxBounceHeight = max(maxBounceHeight, snapshot.telemetry.heightAboveTerrain)
            }
            let vessel = try #require(snapshot.vessels.first { $0.id == snapshot.activeVessel })
            if vessel.situation == .landed {
                let fixed = World.toBodyFixed(vessel.position, body: .luna, time: snapshot.time)
                if let landedFixed { maxDrift = max(maxDrift, (fixed - landedFixed).length) }
                else { landedFixed = fixed }
                maxGroundError = max(maxGroundError, abs(snapshot.telemetry.heightAboveTerrain))
                maxPostContactThrust = max(maxPostContactThrust, snapshot.telemetry.thrust)
            }
        }
        #expect(contacts == 1)
        #expect(maxBounceHeight == 0)
        #expect(maxPostContactThrust == 0)
        #expect(landedFixed != nil)
        #expect(maxDrift < 1e-6)
        // Ось теперь стоит выше грунта на величину опорного габарита.
        #expect(maxGroundError < 1)
        print("LUNA_AUDIT contacts=\(contacts) fixedDrift=\(maxDrift)m groundError=\(maxGroundError)m postContactThrust=\(maxPostContactThrust)N bounceHeight=\(maxBounceHeight)m")
        let fixed = try #require(landedFixed)
        let vessel = try #require(sim.snapshot.vessels.first { $0.id == sim.snapshot.activeVessel })
        print("LUNA_AUDIT parts=\(vessel.parts) noseDotUp=\(vessel.attitude.nose.dot(fixed.normalized)) fixed=\(fixed)")
        var minFootClearance = Double.infinity
        var lowestFoot: D3?
        for (part, pl) in zip(vessel.parts, vessel.layout) where part == .legs {
            for foot in LandingLegGeometry.feet(diameter: pl.diameter, drop: max(0, pl.bottom)) {
                for x in [-1.0, 1.0] {
                    for z in [-1.0, 1.0] {
                        let local = pl.center + pl.geometryOrientation.rotate(foot + Vec3(
                            x * LandingLegGeometry.padHalfWidth,
                            LandingLegGeometry.padCenterOffset - LandingLegGeometry.padHalfHeight - pl.height / 2,
                            z * LandingLegGeometry.padHalfWidth))
                        let point = fixed + vessel.attitude.rotate(local)
                        let agl = point.length - Bodies.luna.radius - Terrain.surfaceHeight(body: .luna, direction: point.normalized)
                        if agl < minFootClearance { minFootClearance = agl; lowestFoot = point.d3 }
                    }
                }
            }
        }
        #expect(minFootClearance >= 0.015)
        let foot = try #require(lowestFoot)
        let renderedFootClearance = simd_length(foot) - (try meshRadius(direction: simd_normalize(foot), level: 10))
        #expect(renderedFootClearance >= 0.005)
        print("LUNA_AUDIT lowestFoot analytic=\(minFootClearance)m rendered=\(renderedFootClearance)m")
        let direction = fixed.normalized.d3
        for level in [8, 9, 10, 12, 14, 16] {
            let rendered = try meshRadius(direction: direction, level: level)
            print("LUNA_AUDIT LOD=\(level) meshMinusRoot=\(rendered - fixed.length)m cell=\(Bodies.luna.radius * .pi / 2 / pow(2, Double(level)) / Double(PatchBuilder.cells))m")
        }
    }

    @Test func cameraShakeSettlesAfterTouchdown() {
        var shake = CameraShake()
        var t = FlightTelemetry()
        t.maxThrust = 60_000
        t.heightAboveTerrain = 0
        t.thrust = 1
        t.situation = .flying
        var maxJolt = 0.0
        for i in 0..<180 {
            let jolt = shake.update(telemetry: t, events: [], time: Double(i) / 60, dt: 1.0 / 60)
            maxJolt = max(maxJolt, simd_length(jolt))
        }
        #expect(maxJolt * 180 / .pi < 0.01)
        t.thrust = 0
        t.situation = .landed
        var residual = SIMD2<Double>.zero
        for i in 0..<300 {
            residual = shake.update(telemetry: t, events: i == 0 ? [.touchdown(speed: 4.83)] : [],
                                    time: 3 + Double(i) / 60, dt: 1.0 / 60)
        }
        #expect(residual == .zero)
        print("LUNA_AUDIT camera 1N nearGround maxJolt=\(maxJolt * 180 / .pi)deg residualAfter5s=\(residual)")
    }

    /// Пересечение луча из центра Луны с фактическим Float-треугольником PatchBuilder.
    private func meshRadius(direction d: D3, level: Int) throws -> Double {
        let face = try #require(CubeSphere.faces.indices.max {
            simd_dot(d, CubeSphere.faces[$0].n) < simd_dot(d, CubeSphere.faces[$1].n)
        })
        let basis = CubeSphere.faces[face]
        let a = atan(simd_dot(d, basis.u) / simd_dot(d, basis.n)) * 4 / .pi
        let b = atan(simd_dot(d, basis.v) / simd_dot(d, basis.n)) * 4 / .pi
        let count = Double(1 << level)
        let key = PatchKey(body: .luna, face: UInt8(face), level: UInt8(level),
                           x: UInt32(min(count - 1, floor((a + 1) / 2 * count))),
                           y: UInt32(min(count - 1, floor((b + 1) / 2 * count))))
        let geo = PatchBuilder.build(key)
        // Юбки не являются верхней поверхностью.
        for index in stride(from: 0, to: PatchBuilder.cells * PatchBuilder.cells * 6, by: 3) {
            let p = (0..<3).map { geo.center + D3(geo.mesh.positions[Int(geo.mesh.indices[index + $0])]) }
            let e1 = p[1] - p[0], e2 = p[2] - p[0]
            let normal = simd_cross(e1, e2)
            let r = simd_dot(normal, p[0]) / simd_dot(normal, d)
            let q = d * r - p[0]
            let aa = simd_dot(e1, e1), ab = simd_dot(e1, e2), bb = simd_dot(e2, e2)
            let aq = simd_dot(q, e1), bq = simd_dot(q, e2)
            let det = aa * bb - ab * ab
            let u = (bb * aq - ab * bq) / det, v = (aa * bq - ab * aq) / det
            if u >= -1e-5 && v >= -1e-5 && u + v <= 1 + 1e-5 { return r }
        }
        throw AuditError.noTriangle
    }
    private enum AuditError: Error { case noTriangle }
}
