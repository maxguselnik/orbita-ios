import OrbitPhysics
import SwiftUI
import Testing
import UIKit
@testable import Orbita

/// Заглушка: MockFlight с ровером в снимке (физики ровера в заглушке нет).
private final class RoverStubFlight: FlightSimulation {
    private let base = MockFlight()
    var rover: RoverStatus
    var controllable = [ControllableVessel(id: 1, isRover: false, name: "Луна"),
                        ControllableVessel(id: 2, isRover: true, name: "Тропа")]
    var roverInputs: [RoverInput] = []
    var inputs: [ControlInput] = []
    var commands: [FlightCommand] = []

    init(_ rover: RoverStatus) { self.rover = rover }

    var snapshot: WorldSnapshot {
        var s = base.snapshot
        s.rover = rover
        s.controllable = controllable
        s.activeVessel = 2
        return s
    }
    func setInput(_ input: ControlInput) { inputs.append(input) }
    func send(_ command: FlightCommand) { commands.append(command); base.send(command) }
    func advance(realDelta: Double) -> [SimEvent] { base.advance(realDelta: realDelta) }
    func predictTrajectory(maxPatches: Int) -> Trajectory { base.predictTrajectory(maxPatches: maxPatches) }
    func predictManeuver(_ node: ManeuverNode, maxPatches: Int) -> ManeuverPrediction? {
        base.predictManeuver(node, maxPatches: maxPatches)
    }
    func setRoverInput(_ input: RoverInput) { roverInputs.append(input) }
}

@MainActor
struct RoverHUDTests {
    private static func driving() -> RoverStatus {
        RoverStatus(speed: 4.8, charge: 80, chargeCapacity: 100, charging: true, wheelsOnGround: 4, wheelCount: 4,
                    driverID: "lera", canDrive: true, distanceToShip: 120)
    }

    @Test func statusTexts() {
        let s = RoverHUDState(Self.driving(), name: "Тропа")
        #expect(s.speedText == "4.8 м/с")
        #expect(s.detail == "Лера · ровер «Тропа» · до корабля 120 м")
        #expect(s.chargePercent == 80 && !s.chargeLow && s.charging && s.canDrive && s.blocker == nil)
        var back = Self.driving()
        back.speed = -1.5
        back.charge = 10
        back.driverID = nil
        back.canDrive = false
        back.distanceToShip = nil
        let b = RoverHUDState(back, name: nil)
        #expect(b.speedText == "−1.5 м/с")
        #expect(b.detail == "без водителя · ровер")
        #expect(b.chargeLow && b.blocker == "Нет водителя")
        back.charge = 0
        #expect(RoverHUDState(back, name: nil).blocker == "Батарея разряжена")
    }

    @Test func buttonStates() {
        var r = Self.driving()
        r.handbrake = true
        r.stabilizer = true
        r.tipped = true
        let s = RoverHUDState(r, name: "Тропа")
        #expect(s.handbrake && s.stabilizer && s.tipped && s.driverID == "lera")
    }

    @Test func stickMapsToRoverInput() {
        let stub = RoverStubFlight(Self.driving())
        let model = FlightHUDModel(makeSimulation: { stub })
        model.tick(now: 1)
        model.tick(now: 1.05)
        #expect(model.rover != nil)
        model.roverStick = SIMD2(0.5, 0.8)
        model.tick(now: 1.1)
        #expect(stub.roverInputs.last == RoverInput(drive: 0.8, steer: 0.5))
        model.roverStick = SIMD2(-1, -0.6)
        model.tick(now: 1.15)
        #expect(stub.roverInputs.last == RoverInput(drive: -0.6, steer: -1))
        #expect(stub.inputs.last == .neutral)
    }

    @Test func noDriverGivesNeutralRoverInput() {
        var r = Self.driving()
        r.canDrive = false
        r.driverID = nil
        let stub = RoverStubFlight(r)
        let model = FlightHUDModel(makeSimulation: { stub })
        model.tick(now: 1)
        model.tick(now: 1.05)
        model.roverStick = SIMD2(1, 1)
        model.tick(now: 1.1)
        #expect(stub.roverInputs.last == .neutral)
    }

    @Test func switchCommands() {
        let stub = RoverStubFlight(Self.driving())
        let model = FlightHUDModel(makeSimulation: { stub })
        model.tick(now: 1)
        model.tick(now: 1.05)
        model.switchToShip()
        #expect(stub.commands.last == .selectVessel(1))
        model.roverStandUp()
        #expect(stub.commands.last == .evaExit)
    }

    /// Раскладка HUD ровера на 740 × 371 и 852 × 393: всё внутри кадра, элементы не пересекаются.
    @Test(arguments: [CGSize(width: 740, height: 371), CGSize(width: 852, height: 393)], [true, false])
    func layoutFits(size: CGSize, tipped: Bool) async throws {
        var r = Self.driving()
        r.tipped = tipped
        r.handbrake = tipped
        let stub = RoverStubFlight(r)
        let model = FlightHUDModel(makeSimulation: { stub })
        model.tick(now: 1)
        model.tick(now: 1.05)
        final class Box { var frames: [String: CGRect] = [:] }
        let box = Box()
        let root = RoverLayer(model: model)
            .onPreferenceChange(EVAFrameKey.self) { box.frames = $0 }
            .background(.black)
        let controller = UIHostingController(rootView: root)
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        await Task.yield()
        controller.view.layoutIfNeeded()
        let frames = box.frames
        let screen = CGRect(origin: .zero, size: size)
        #expect(frames.count >= 9)
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
