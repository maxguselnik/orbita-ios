import Foundation
import OrbitPhysics

/// Фейковый полёт для HUD (этап 1): правдоподобные числа без настоящей физики.
/// Движение — в плоскости экватора Терры (на восток), ступени, топливо, SAS, ускорение
/// времени и события упрощены. Заменяется физикой потока A при интеграции.
/// Используется только с главного актёра.
final class MockFlight: FlightSimulation {
    private struct Stage {
        let dryMass: Double
        var fuelMass: Double
        let fuelCapacity: Double
        /// Тяга на полном газе, Н (0 — без двигателя, например капсула).
        let thrust: Double
        /// Удельный импульс, с.
        let isp: Double
        let solid: Bool

        var mass: Double { dryMass + fuelMass }
        /// Расход топлива на полной тяге, кг/с.
        var fuelFlow: Double { thrust > 0 ? thrust / (isp * MockFlight.g0) : 0 }
    }

    static let g0 = 9.80665
    private static let terrainHeight = 72.0
    private static let padAltitude = 75.0
    /// Площадь × коэффициент сопротивления корпуса и раскрытого купола, м².
    private static let bodyDragArea = 0.8
    private static let chuteDragArea = 400.0

    private let body = Bodies.terra
    private let omega: Double

    private var stages: [Stage]
    private var input = ControlInput.neutral
    private var sas: SASMode = .off
    private var warpIndex = 0
    private var chute: ChuteState = .stowed
    private var maneuverNode: ManeuverNode?
    /// `warpToManeuver`: ускорение сбрасывается за `ManeuverStatus.warpLead` до начала прожига.
    private var warpingToManeuver = false
    private var chuteTimer = 0.0

    private var time = 0.0
    private var missionTime = 0.0
    private var situation: VesselSituation = .prelaunch
    private var altitude: Double
    /// Угол вдоль экватора, рад.
    private var longitude = 0.0
    private var vVert = 0.0
    /// Инерциальная горизонтальная скорость на восток, м/с.
    private var vHoriz: Double
    /// Ориентация относительно горизонта, рад.
    private var pitch = Double.pi / 2
    private var heading = Double.pi / 2
    private var roll = 0.0

    private var engineRunning = false
    private var solidIgnited = false
    private var thrustNow = 0.0
    private var dynamicPressure = 0.0
    private var peakQ = 0.0
    private var maxQReported = false
    private var accel = 0.0
    private var pendingEvents: [SimEvent] = []

    init() {
        omega = 2 * .pi / Bodies.terra.rotationPeriod
        altitude = Self.padAltitude
        vHoriz = omega * (Bodies.terra.radius + Self.padAltitude)
        stages = [
            Stage(dryMass: 1_500, fuelMass: 6_000, fuelCapacity: 6_000, thrust: 230_000, isp: 210, solid: true),
            Stage(dryMass: 900, fuelMass: 4_000, fuelCapacity: 4_000, thrust: 70_000, isp: 310, solid: false),
            Stage(dryMass: 300, fuelMass: 1_000, fuelCapacity: 1_000, thrust: 20_000, isp: 340, solid: false),
            Stage(dryMass: 1_200, fuelMass: 0, fuelCapacity: 0, thrust: 0, isp: 1, solid: false),
        ]
    }

    // MARK: - FlightSimulation

    var snapshot: WorldSnapshot { makeSnapshot() }

    func setInput(_ input: ControlInput) {
        self.input = input
    }

    func send(_ command: FlightCommand) {
        switch command {
        case .stage:
            if stages.count > 1 {
                pendingEvents.append(.separation(stage: stages.count - 1))
                stages.removeFirst()
                engineRunning = false
                solidIgnited = false
            } else if chute == .stowed {
                send(.deployChute)
            }
        case .setSAS(let mode):
            sas = mode
        case .setWarp(let index):
            warpingToManeuver = false
            let clamped = min(max(index, 0), TimeWarp.levels.count - 1)
            if clamped >= TimeWarp.physicalCount, let reason = warpBlocked {
                warpIndex = 0
                pendingEvents.append(.warpReset(reason))
            } else {
                warpIndex = clamped
            }
        case .deployChute:
            guard chute == .stowed else { return }
            chute = .armed
        case .setManeuver(let node):
            maneuverNode = node
            if node == nil { warpingToManeuver = false }
        case .warpToManeuver:
            guard let status = maneuverStatus(), status.timeToBurn > ManeuverStatus.warpLead else { return }
            if let reason = warpBlocked {
                pendingEvents.append(.warpReset(reason))
                return
            }
            warpingToManeuver = true
            warpIndex = TimeWarp.levels.count - 1
        }
    }

    func predictTrajectory(maxPatches: Int) -> Trajectory {
        let (position, velocity) = stateVectors()
        return TrajectoryPredictor.predict(body: body.id, state: StateVector(position: position, velocity: velocity),
                                           time: time, maxPatches: maxPatches)
    }

    func predictManeuver(_ node: ManeuverNode, maxPatches: Int) -> ManeuverPrediction? {
        guard !onGround else { return nil }
        let (position, velocity) = stateVectors()
        let stage = stages.first
        return TrajectoryPredictor.predict(node: node, body: body.id,
                                           state: StateVector(position: position, velocity: velocity),
                                           time: time, mass: totalMass, thrust: stage?.thrust ?? 0,
                                           isp: stage?.isp ?? 0, maxPatches: maxPatches)
    }

    func advance(realDelta: Double) -> [SimEvent] {
        let simDelta = max(0, realDelta) * TimeWarp.levels[warpIndex]
        if simDelta > 0 {
            // Шаг ≤ 0.02 с, но не больше 2000 шагов за кадр (на «рельсах» шаг крупнее).
            let steps = min(2_000, max(1, Int((simDelta / 0.02).rounded(.up))))
            let dt = simDelta / Double(steps)
            for _ in 0..<steps {
                step(dt)
            }
        }
        if warpIndex >= TimeWarp.physicalCount, let reason = warpBlocked {
            warpIndex = 0
            warpingToManeuver = false
            pendingEvents.append(.warpReset(reason))
        }
        if warpingToManeuver, let status = maneuverStatus(), status.timeToBurn <= ManeuverStatus.warpLead {
            warpIndex = 0
            warpingToManeuver = false
            pendingEvents.append(.warpReset(.maneuver))
        }
        let events = pendingEvents
        pendingEvents.removeAll()
        return events
    }

    // MARK: - Шаг

    private var radius: Double { body.radius + altitude }
    private var onGround: Bool { situation == .prelaunch || situation == .landed || situation == .crashed }
    private var surfaceHorizontal: Double { vHoriz - omega * radius }
    private var surfaceSpeed: Double { (vVert * vVert + surfaceHorizontal * surfaceHorizontal).squareRoot() }
    private var totalMass: Double { stages.reduce(0) { $0 + $1.mass } }

    private var chuteSafe: Bool {
        body.density(altitude: altitude) > 0 && altitude < 34_000 && surfaceSpeed < 450
    }

    private var warpBlocked: WarpResetReason? {
        if thrustNow > 0 { return .thrust }
        if !onGround && altitude < body.atmosphereHeight { return .atmosphere }
        return nil
    }

    private func step(_ dt: Double) {
        time += dt
        if situation != .prelaunch { missionTime += dt }

        updateAttitude(dt)
        updateEngine(dt)
        updateChute(dt)

        let mass = totalMass
        let thrustAccel = thrustNow / mass
        let r = radius
        let g = body.mu / (r * r)

        if onGround {
            if situation == .crashed || thrustAccel * sin(pitch) <= g {
                vVert = 0
                vHoriz = omega * r
                accel = situation == .crashed ? 0 : 1
                dynamicPressure = 0
                return
            }
            situation = .flying
        }

        // Сопротивление по скорости относительно вращающейся атмосферы.
        let rho = body.density(altitude: altitude)
        let relH = surfaceHorizontal
        let relSpeed = surfaceSpeed
        let area = Self.bodyDragArea + (chute == .open ? Self.chuteDragArea : chute == .deploying ? Self.chuteDragArea * 0.2 : 0)
        dynamicPressure = 0.5 * rho * relSpeed * relSpeed
        let drag = relSpeed > 0 ? dynamicPressure * area / mass : 0
        let dragV = relSpeed > 0 ? drag * vVert / relSpeed : 0
        let dragH = relSpeed > 0 ? drag * relH / relSpeed : 0

        let thrustV = thrustAccel * sin(pitch)
        let thrustH = thrustAccel * cos(pitch) * sin(heading)

        let aV = thrustV - g + vHoriz * vHoriz / r - dragV
        let aH = thrustH - dragH - vVert * vHoriz / r
        accel = ((thrustV - dragV) * (thrustV - dragV) + (thrustH - dragH) * (thrustH - dragH)).squareRoot() / g0Surface
        vVert += aV * dt
        vHoriz += aH * dt
        altitude += vVert * dt
        longitude += vHoriz / r * dt

        trackMaxQ()

        if altitude - Self.terrainHeight <= 0 {
            land()
        } else {
            updateSituation()
        }
    }

    private var g0Surface: Double { body.surfaceGravity }

    private func updateAttitude(_ dt: Double) {
        let rate = 0.35 * dt   // рад/с при полном отклонении
        let manual = abs(input.pitch) > 0.05 || abs(input.yaw) > 0.05
        if manual || sas == .off || sas == .hold {
            pitch = min(max(pitch + input.pitch * rate, -.pi / 2), .pi / 2)
            heading = wrap(heading + input.yaw * rate)
        } else if let target = sasTarget() {
            pitch += min(max(target.pitch - pitch, -rate), rate)
            heading = wrap(heading + min(max(angleDiff(target.heading, heading), -rate), rate))
        }
        roll = wrapSigned(roll + input.roll * rate * 1.5)
    }

    private func sasTarget() -> (pitch: Double, heading: Double)? {
        let speed = (vVert * vVert + vHoriz * vHoriz).squareRoot()
        let gamma = speed > 1 ? asin(min(max(vVert / speed, -1), 1)) : .pi / 2
        switch sas {
        case .off, .hold: return nil
        case .prograde: return (gamma, .pi / 2)
        case .retrograde: return (-gamma, 3 * .pi / 2)
        case .normal: return (0, 0)
        case .antiNormal: return (0, .pi)
        case .radialOut: return (.pi / 2, heading)
        case .radialIn: return (-.pi / 2, heading)
        case .maneuver:
            // В моке узел — только по скорости: прогрейд или ретрогрейд по знаку.
            guard let node = maneuverNode else { return nil }
            return node.prograde >= 0 ? (gamma, .pi / 2) : (-gamma, 3 * .pi / 2)
        }
    }

    private func updateEngine(_ dt: Double) {
        guard !stages.isEmpty, situation != .crashed else { thrustNow = 0; return }
        let stageNumber = stages.count - 1
        var stage = stages[0]
        let throttle: Double
        if stage.solid {
            if !solidIgnited && input.throttle > 0 && stage.fuelMass > 0 { solidIgnited = true }
            throttle = solidIgnited ? 1 : 0
        } else {
            throttle = min(max(input.throttle, 0), 1)
        }
        let running = stage.thrust > 0 && stage.fuelMass > 0 && throttle > 0
        if running && !engineRunning {
            pendingEvents.append(.ignition(stage: stageNumber, solid: stage.solid))
        }
        if running {
            stage.fuelMass = max(0, stage.fuelMass - stage.fuelFlow * throttle * dt)
            if stage.fuelMass == 0 {
                pendingEvents.append(.flameout(stage: stageNumber, solid: stage.solid))
            }
        }
        stages[0] = stage
        engineRunning = running && stage.fuelMass > 0
        thrustNow = running ? stage.thrust * throttle : 0
    }

    private func updateChute(_ dt: Double) {
        switch chute {
        case .armed where chuteSafe && !onGround:
            chute = .deploying
            chuteTimer = 0
            pendingEvents.append(.chuteDeployed)
        case .deploying:
            chuteTimer += dt
            if chuteTimer >= 2 {
                chute = .open
                pendingEvents.append(.chuteOpened)
            }
        default:
            break
        }
    }

    private func trackMaxQ() {
        guard !maxQReported else { return }
        if dynamicPressure > peakQ {
            peakQ = dynamicPressure
        } else if peakQ > 1_000 && dynamicPressure < peakQ * 0.97 {
            maxQReported = true
            pendingEvents.append(.maxQ(pascals: peakQ))
        }
    }

    private func land() {
        let speed = surfaceSpeed
        altitude = Self.terrainHeight
        if speed > 10 {
            situation = .crashed
            pendingEvents.append(.crash(speed: speed))
        } else {
            situation = .landed
            pendingEvents.append(.touchdown(speed: speed))
        }
        vVert = 0
        vHoriz = omega * radius
        engineRunning = false
    }

    private func updateSituation() {
        if altitude < body.atmosphereHeight {
            situation = .flying
        } else if let orbit = orbitSummary() {
            if orbit.apoapsisAltitude.isInfinite {
                situation = .escaping
            } else if orbit.periapsisAltitude > body.atmosphereHeight {
                situation = .orbiting
            } else {
                situation = .suborbital
            }
        }
    }

    // MARK: - Орбита

    private func orbitSummary() -> OrbitSummary? {
        let mu = body.mu
        let r = radius
        let v2 = vVert * vVert + vHoriz * vHoriz
        let energy = v2 / 2 - mu / r
        let h = r * vHoriz
        let e = max(0, 1 + 2 * energy * h * h / (mu * mu)).squareRoot()
        let p = h * h / mu
        guard p > 0 else { return nil }

        var nu = 0.0
        if e > 1e-6 {
            nu = acos(min(max((p / r - 1) / e, -1), 1))
            if vVert < 0 { nu = 2 * .pi - nu }
        }

        if energy < 0 && e < 1 {
            let a = -mu / (2 * energy)
            let period = 2 * .pi * (a * a * a / mu).squareRoot()
            let ecc = 2 * atan(((1 - e) / (1 + e)).squareRoot() * tan(nu / 2))
            var meanAnomaly = ecc - e * sin(ecc)
            if meanAnomaly < 0 { meanAnomaly += 2 * .pi }
            let n = 2 * .pi / period
            var toAp = (.pi - meanAnomaly) / n
            if toAp < 0 { toAp += period }
            let toPe = (2 * .pi - meanAnomaly) / n
            return OrbitSummary(
                body: body.id,
                apoapsisAltitude: a * (1 + e) - body.radius,
                periapsisAltitude: a * (1 - e) - body.radius,
                timeToApoapsis: toAp, timeToPeriapsis: toPe,
                eccentricity: e, inclination: 0, period: period)
        }
        return OrbitSummary(
            body: body.id,
            apoapsisAltitude: .infinity,
            periapsisAltitude: p / (1 + e) - body.radius,
            timeToApoapsis: nil, timeToPeriapsis: nil,
            eccentricity: e, inclination: 0, period: .infinity)
    }

    // MARK: - Узел манёвра

    /// Положение и скорость в инерциальной системе Терры.
    private func stateVectors() -> (position: Vec3, velocity: Vec3) {
        let up = Vec3(cos(longitude), sin(longitude), 0)
        let east = Vec3(-sin(longitude), cos(longitude), 0)
        return (up * radius, up * vVert + east * vHoriz)
    }

    /// Мок: прожиг не отслеживается, остаток равен полному импульсу.
    private func maneuverStatus() -> ManeuverStatus? {
        guard let node = maneuverNode else { return nil }
        let stage = stages.first
        let burn = TrajectoryPredictor.burnTime(deltaV: node.deltaV, mass: totalMass,
                                                thrust: stage?.thrust ?? 0, isp: stage?.isp ?? 0)
        let toNode = node.time - time
        return ManeuverStatus(node: node, timeToNode: toNode, deltaV: node.deltaV, remainingDeltaV: node.deltaV,
                              burnTime: burn, timeToBurn: burn.isFinite ? toNode - burn / 2 : toNode,
                              isDone: false)
    }

    // MARK: - Снимок

    private func makeSnapshot() -> WorldSnapshot {
        let up = Vec3(cos(longitude), sin(longitude), 0)
        let east = Vec3(-sin(longitude), cos(longitude), 0)
        let north = Vec3.unitZ
        let (position, velocity) = stateVectors()

        // Оси корабля: Y — нос, Z — «верх» кабины, X — вправо.
        let horizontal = north * cos(heading) + east * sin(heading)
        let nose = up * sin(pitch) + horizontal * cos(pitch)
        let top0 = up * cos(pitch) - horizontal * sin(pitch)
        let right0 = nose.cross(top0)
        let right = right0 * cos(roll) + top0 * sin(roll)
        let top = right.cross(nose)
        let attitude = Self.quaternion(x: right, y: nose, z: top)
        let toShip = attitude.conjugate

        let surfaceVelocity = velocity - Vec3(0, 0, omega).cross(position)
        let speed = velocity.length
        let normal = position.cross(velocity).normalized
        let radialOut = velocity.cross(normal).normalized
        let navball = NavballVectors(
            prograde: speed > 0.1 ? toShip.rotate(velocity.normalized) : nil,
            normal: normal.length > 0 ? toShip.rotate(normal) : nil,
            radialOut: radialOut.length > 0 ? toShip.rotate(radialOut) : toShip.rotate(up),
            surfacePrograde: surfaceVelocity.length > 0.1 ? toShip.rotate(surfaceVelocity.normalized) : nil,
            maneuver: maneuverNode.flatMap { (node: ManeuverNode) -> Vec3? in
                guard node.deltaV > 0.01 else { return nil }
                let dv = TrajectoryPredictor.deltaVVector(node: node, position: position, velocity: velocity)
                return toShip.rotate(dv.normalized)
            })

        let gSurface = body.surfaceGravity
        var massAbove = totalMass
        var stageInfos: [StageInfo] = []
        for stage in stages {
            let full = massAbove
            let dry = full - stage.fuelMass
            let deltaV = stage.thrust > 0 && dry > 0 ? stage.isp * Self.g0 * log(full / dry) : 0
            let twr = stage.thrust / (full * gSurface)
            stageInfos.append(StageInfo(
                deltaV: deltaV, twr: twr, twrVacuum: twr * 1.1,
                fuelFraction: stage.fuelCapacity > 0 ? stage.fuelMass / stage.fuelCapacity : 0,
                burnTime: stage.fuelFlow > 0 ? stage.fuelMass / stage.fuelFlow : 0,
                hasSolid: stage.solid))
            massAbove -= stage.mass
        }

        let rho = body.density(altitude: altitude)
        let orbit = onGround ? nil : orbitSummary()
        let telemetry = FlightTelemetry(
            altitude: altitude,
            heightAboveTerrain: max(0, altitude - Self.terrainHeight),
            speed: speed,
            surfaceSpeed: surfaceSpeed,
            verticalSpeed: vVert,
            dynamicPressure: dynamicPressure,
            mach: surfaceSpeed / 340,
            orbit: orbit,
            sas: sas,
            warpFactor: TimeWarp.levels[warpIndex],
            missionTime: missionTime,
            stages: stageInfos,
            thrust: thrustNow,
            maxThrust: stages.first?.thrust ?? 0,
            solidBurning: solidIgnited && thrustNow > 0,
            atmosphereDensity: rho,
            heating: min(1, max(0, (dynamicPressure * surfaceSpeed - 2e7) / 2e8)),
            gForce: accel,
            body: body.id,
            situation: situation,
            staticPressure: rho / body.seaLevelDensity,
            pitch: pitch,
            heading: heading,
            roll: roll,
            navball: navball,
            chute: chute,
            chuteSafe: chuteSafe,
            warpIndex: warpIndex,
            warpBlocked: warpBlocked,
            maneuver: maneuverStatus())

        let vessel = VesselState(
            id: 1, body: body.id, position: position, velocity: velocity,
            attitude: attitude, mass: totalMass, throttle: input.throttle,
            situation: situation)

        return WorldSnapshot(
            time: time, activeVessel: vessel.id, vessels: [vessel],
            terraRotation: (omega * time).truncatingRemainder(dividingBy: 2 * .pi),
            telemetry: telemetry)
    }

    // MARK: - Вспомогательное

    private func wrap(_ angle: Double) -> Double {
        let twoPi = 2 * Double.pi
        let a = angle.truncatingRemainder(dividingBy: twoPi)
        return a < 0 ? a + twoPi : a
    }

    private func wrapSigned(_ angle: Double) -> Double {
        let a = wrap(angle)
        return a > .pi ? a - 2 * .pi : a
    }

    private func angleDiff(_ a: Double, _ b: Double) -> Double {
        wrapSigned(a - b)
    }

    /// Кватернион из ортонормированного базиса (столбцы — оси корабля в инерциальных).
    private static func quaternion(x: Vec3, y: Vec3, z: Vec3) -> Quat {
        let m00 = x.x, m10 = x.y, m20 = x.z
        let m01 = y.x, m11 = y.y, m21 = y.z
        let m02 = z.x, m12 = z.y, m22 = z.z
        let trace = m00 + m11 + m22
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            return Quat(w: 0.25 * s, x: (m21 - m12) / s, y: (m02 - m20) / s, z: (m10 - m01) / s).normalized
        } else if m00 > m11 && m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            return Quat(w: (m21 - m12) / s, x: 0.25 * s, y: (m01 + m10) / s, z: (m02 + m20) / s).normalized
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            return Quat(w: (m02 - m20) / s, x: (m01 + m10) / s, y: 0.25 * s, z: (m12 + m21) / s).normalized
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            return Quat(w: (m10 - m01) / s, x: (m02 + m20) / s, y: (m12 + m21) / s, z: 0.25 * s).normalized
        }
    }
}
