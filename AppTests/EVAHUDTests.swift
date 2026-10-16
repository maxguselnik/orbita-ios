import OrbitPhysics
import SwiftUI
import Testing
import UIKit
@testable import Orbita

/// Заглушка: MockFlight с космонавтом в снимке (физики EVA в заглушке нет).
private final class EVAStubFlight: FlightSimulation {
    private let base = MockFlight()
    var cosmonaut: CosmonautState
    var inputs: [EVAInput] = []

    init(_ cosmonaut: CosmonautState) { self.cosmonaut = cosmonaut }

    var snapshot: WorldSnapshot {
        var s = base.snapshot
        s.cosmonauts = [cosmonaut]
        s.controlledCosmonaut = cosmonaut.memberID
        return s
    }
    func setInput(_ input: ControlInput) { base.setInput(input) }
    func send(_ command: FlightCommand) { base.send(command) }
    func advance(realDelta: Double) -> [SimEvent] { base.advance(realDelta: realDelta) }
    func predictTrajectory(maxPatches: Int) -> Trajectory { base.predictTrajectory(maxPatches: maxPatches) }
    func predictManeuver(_ node: ManeuverNode, maxPatches: Int) -> ManeuverPrediction? {
        base.predictManeuver(node, maxPatches: maxPatches)
    }
    func setEVAInput(_ input: EVAInput) { inputs.append(input) }
}

@MainActor
struct EVAHUDTests {
    private static func ground() -> CosmonautState {
        CosmonautState(memberID: "lera", name: "Лера", body: .luna, position: Vec3(200_000, 0, 0), onGround: true,
                       jetpackOn: false, fuel: 12, surfaceSpeed: 1.2, hatchDistance: 1.6, canBoard: true,
                       flagBlocker: nil, sampleBlocker: .duplicate)
    }

    private static func orbit() -> CosmonautState {
        let orbit = OrbitSummary(body: .luna, apoapsisAltitude: 31_200, periapsisAltitude: 29_800, timeToApoapsis: 10,
                                 timeToPeriapsis: 20, eccentricity: 0.01, inclination: 0, period: 3_000)
        return CosmonautState(memberID: "lera", name: "Лера", body: .luna, position: Vec3(230_000, 0, 0), jetpackOn: true,
                              fuel: 3, altitude: 30_000, heightAboveTerrain: 30_000, orbit: orbit, hatchDistance: 6.4)
    }

    @Test func statusTexts() {
        let g = EVAHUDState(Self.ground())
        #expect(g.title == "Лера · Луна")
        #expect(g.detail == "скорость 1.2 м/с · до люка 1.6 м")
        #expect(g.fuelPercent == 50 && !g.fuelLow && g.warning == nil && g.stickLabel == "идти")
        let o = EVAHUDState(Self.orbit())
        #expect(o.title == "Лера · орбита Луны")
        #expect(o.detail == "Ап 31.2 км · Пе 29.8 км · до люка 6.4 м")
        #expect(o.fuelLow && o.warning == "Мало топлива ранца — вернитесь к люку" && o.stickLabel == "лететь")
        var fall = Self.orbit()
        fall.verticalSpeed = -9.4
        fall.heightAboveTerrain = 60
        #expect(EVAHUDState(fall).warning == "Скорость падения 9 м/с — опасно")
    }

    @Test func eventToasts() {
        #expect(FlightHUDModel.message(for: .evaExited(memberID: "lera")) == "Лера вышла")
        #expect(FlightHUDModel.message(for: .evaBoarded(memberID: "lera")) == "Лера в капсуле")
        #expect(FlightHUDModel.message(for: .evaInjured(memberID: "lera", speed: 12)) == "Лера травмирована · 12 м/с")
        #expect(FlightHUDModel.message(for: .evaDied(memberID: "lera", speed: 17)) == "Лера погибла · 17 м/с")
        #expect(FlightHUDModel.message(for: .flagPlanted(body: .luna)) == "Флаг установлен")
        #expect(FlightHUDModel.message(for: .jetpackEmpty(memberID: "lera")) == "Ранец пуст")
        #expect(FlightHUDModel.message(for: .evaLanded(memberID: "lera", speed: 3)) == nil)
    }

    @Test func shipGetsNeutralInputInEVA() {
        let stub = EVAStubFlight(Self.ground())
        let model = FlightHUDModel(makeSimulation: { stub })
        model.throttle = 0.7
        model.tick(now: 1)
        model.tick(now: 1.05)
        #expect(model.eva != nil)
        #expect(model.throttle == 0)
        #expect(stub.inputs.last == .neutral)
    }

    /// Раскладка HUD EVA на 740 × 371 и 852 × 393: всё внутри кадра, элементы не пересекаются.
    @Test(arguments: [CGSize(width: 740, height: 371), CGSize(width: 852, height: 393)], [true, false])
    func layoutFits(size: CGSize, ground: Bool) async throws {
        let stub = EVAStubFlight(ground ? Self.ground() : Self.orbit())
        let model = FlightHUDModel(makeSimulation: { stub })
        model.tick(now: 1)
        model.tick(now: 1.05)
        if !ground {
            // Орбита: плашка падения показывается, чтобы проверить и её.
            var fall = stub.cosmonaut
            fall.verticalSpeed = -9
            fall.heightAboveTerrain = 50
            stub.cosmonaut = fall
            model.tick(now: 1.1)
        }
        final class Box { var frames: [String: CGRect] = [:] }
        let box = Box()
        let root = EVALayer(model: model)
            .onPreferenceChange(EVAFrameKey.self) { box.frames = $0 }
            .background(.black)
        let controller = UIHostingController(rootView: root)
        let fitted = controller.sizeThatFits(in: size)
        #expect(fitted.width <= size.width && fitted.height <= size.height)
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        await Task.yield()
        controller.view.layoutIfNeeded()
        let frames = box.frames
        let screen = CGRect(origin: .zero, size: size)
        #expect(frames.count >= 8)
        for (name, rect) in frames {
            #expect(screen.contains(rect), "\(name) выходит за кадр: \(rect)")
        }
        let names = frames.keys.sorted()
        for (i, a) in names.enumerated() {
            for b in names[(i + 1)...] where frames[a]!.intersects(frames[b]!) {
                Issue.record("\(a) и \(b) пересекаются: \(frames[a]!) \(frames[b]!)")
            }
        }
        window.isHidden = true
    }
}
