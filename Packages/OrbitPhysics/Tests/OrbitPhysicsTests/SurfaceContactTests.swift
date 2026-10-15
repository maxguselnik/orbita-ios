import Testing
@testable import OrbitPhysics

@Suite("Опоры на рельефе")
struct SurfaceContactTests {
    @Test(arguments: [0.0, 0.4, 1.2])
    func tiltedLanderDoesNotPenetrateTerrain(tilt: Double) {
        let design = VesselDesign(name: "Контакт", parts: [.podK1, .t800, .legs, .shtil])
        let up = Vec3(0.3, 0.9, 0.1).normalized
        let ground = Bodies.luna.radius + Terrain.surfaceHeight(body: .luna, direction: up)
        let q = Quat(axis: .unitZ, angle: tilt) * Quat.looking(nose: up, zHint: .unitZ)
        let sim = FlightSim(design: design, body: .luna, position: up * (ground + 12),
                            velocity: up * -1, attitude: q)
        var contacts = 0
        for _ in 0..<900 {
            for event in sim.advance(realDelta: 1.0 / 60) { if case .touchdown = event { contacts += 1 } }
        }
        #expect(sim.activeSituation == .landed)
        #expect(contacts == 1)
        let vessel = sim.active
        for point in vessel.ship.contactPoints {
            let world = vessel.r + vessel.q.rotate(point)
            let height = world.length - Bodies.luna.radius - Terrain.surfaceHeight(body: .luna, direction: world.normalized)
            #expect(height >= 0.019)
        }
        // Посадка не должна навсегда блокировать взлёт новой командой.
        sim.send(.stage)
        sim.setInput(ControlInput(throttle: 1))
        _ = sim.advance(realDelta: 0.1)
        if tilt == 0 {
            #expect(sim.activeSituation != .landed && sim.activeSituation != .crashed)
            #expect(sim.activeStateVector.velocity.dot(up) > 0)
        }
    }
}
