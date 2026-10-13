import Foundation

/// Простой автопилот поверх публичного API `FlightSim`: выставляет тягу, направление, ступени и ускорение времени.
/// Используется тестами; позже может стать подсказкой игроку.
public final class Autopilot {
    public enum Goal: Sendable, Hashable {
        /// Выход на орбиту Терры.
        case orbit
        /// Орбита, затем перелёт до входа в SOI Луны.
        case lunaEncounter
        /// Орбита, перелёт, захват Луной и посадка.
        case lunaLanding
        /// Полная миссия: посадка на Луну, взлёт, возврат и посадка на Терру с парашютом.
        case lunaReturn
    }

    public enum Phase: String, Sendable, Hashable {
        case prelaunch, ascent, coastToApoapsis, circularize, parked
        case waitPhase, transferBurn, coastToLuna
        case lunaCorrection, coastToPeriapsis, lunaCapture, deorbit, descent
        case returnPlan, returnBurn, coastHome, reentry
        case done, failed
    }

    public let goal: Goal
    /// Целевой апоцентр, м над уровнем моря.
    public var targetApoapsis = 80_000.0
    /// Перицентр, при котором циркуляризация заканчивается, м.
    public var targetPeriapsis = 74_000.0
    /// Перицентр у Луны для захвата, м.
    public var lunaPeriapsis = 15_000.0
    /// Шаг реального времени между вызовами `update` (для выбора ускорения).
    public let frameDelta: Double

    public private(set) var phase: Phase = .prelaunch
    public var isFinished: Bool { phase == .done || phase == .failed }

    private var lastStageTime = -1e9
    private var returnNode: ManeuverNode?
    private var lastCheck = -1e9
    /// Перицентр у Терры для возврата, м.
    public var returnPeriapsis = 35_000.0

    public init(goal: Goal, frameDelta: Double = 0.1) {
        self.goal = goal
        self.frameDelta = frameDelta
    }

    // MARK: Помощники

    private func setThrottle(_ sim: FlightSim, _ t: Double) {
        sim.setInput(ControlInput(throttle: clamp(t, 0, 1)))
    }

    /// Ступень, если следующая только зажигает двигатели или отделяет отработавшие.
    private func autoStage(_ sim: FlightSim) {
        guard sim.time - lastStageTime > 0.5 else { return }
        if sim.currentStageHasUnlitEngines {
            sim.send(.stage)
            lastStageTime = sim.time
        } else if sim.spentSeparationReady {
            sim.send(.stage)
            lastStageTime = sim.time
        }
    }

    /// Ускорение времени так, чтобы не перескочить `dt` секунд.
    private func warp(_ sim: FlightSim, toCover dt: Double) {
        var idx = 0
        let railsOK = sim.railsBlockReason() == nil
        for (i, level) in TimeWarp.levels.enumerated() {
            if i >= TimeWarp.physicalCount && !railsOK { break }
            if level * frameDelta <= dt * 0.25 { idx = i }
        }
        if idx != sim.warpIndex { sim.send(.setWarp(index: idx)) }
    }

    private func stopWarp(_ sim: FlightSim) {
        if sim.warpIndex != 0 { sim.send(.setWarp(index: 0)) }
    }

    private func burnTime(_ sim: FlightSim, _ dv: Double) -> Double {
        let perf = sim.currentStagePerformance
        return TrajectoryPredictor.burnTime(deltaV: dv, mass: sim.activeMass, thrust: perf.thrust, isp: perf.isp)
    }

    // MARK: Шаг

    public func update(_ sim: FlightSim) {
        let s = sim.activeStateVector
        let body = Bodies.body(sim.activeBody)
        let r = s.position, v = s.velocity
        let rm = r.length
        let up = r / rm
        let alt = rm - body.radius
        let el = sim.activeElements
        let situation = sim.activeSituation
        if situation == .crashed { phase = .failed; return }

        switch phase {
        case .prelaunch:
            sim.send(.setSAS(.hold))
            setThrottle(sim, 1)
            sim.autopilotDirection = up
            sim.send(.stage)
            lastStageTime = sim.time
            phase = .ascent

        case .ascent:
            autoStage(sim)
            let east = Vec3.unitZ.cross(up).normalized
            let theta: Double
            if sim.activeBody == .terra {
                theta = clamp((alt - 1_000) / 45_000, 0, 1).squareRoot() * 88 * Double.pi / 180
            } else {
                let hT = sim.snapshot.telemetry.heightAboveTerrain
                theta = (hT < 300 ? 0 : clamp((hT - 300) / 4_000, 0, 1).squareRoot() * 75) * Double.pi / 180
            }
            sim.autopilotDirection = up * cos(theta) + east * sin(theta)
            setThrottle(sim, 1)
            let airborne = situation != .landed && situation != .prelaunch && situation != .splashed
            if airborne && el.isClosed && el.apoapsisRadius - body.radius >= targetApoapsis {
                setThrottle(sim, 0)
                phase = .coastToApoapsis
            }

        case .coastToApoapsis:
            let apAlt = el.apoapsisRadius - body.radius
            sim.autopilotDirection = horizontalPrograde(r, v)
            if alt < body.atmosphereHeight {
                stopWarp(sim)
                // Добираем апоцентр, потерянный на сопротивлении.
                setThrottle(sim, apAlt < targetApoapsis - 100 ? 0.3 : 0)
                if apAlt < targetApoapsis - 100 { autoStage(sim) }
                break
            }
            setThrottle(sim, 0)
            if sim.spentSeparationReady { autoStage(sim) }
            let vAp = el.angularMomentum.length / el.apoapsisRadius
            let dv = (body.mu / el.apoapsisRadius).squareRoot() - vAp
            let bt = burnTime(sim, dv)
            let tAp = el.timeToApoapsis ?? 0
            let wait = tAp - bt / 2
            if wait <= 1 {
                stopWarp(sim)
                phase = .circularize
            } else {
                warp(sim, toCover: wait - 1)
            }

        case .circularize:
            stopWarp(sim)
            autoStage(sim)
            let vr = v.dot(up)
            let c = clamp(-vr * 0.02, -0.35, 0.35)
            sim.autopilotDirection = horizontalPrograde(r, v) * cos(c) + up * sin(c)
            let vh = (v - up * vr).length
            let dvRem = (body.mu / rm).squareRoot() - vh
            let perf = sim.currentStagePerformance
            let acc = perf.thrust / sim.activeMass
            setThrottle(sim, acc > 0 ? clamp(dvRem / (acc * 2), 0.05, 1) : 1)
            if el.periapsisRadius - body.radius >= targetPeriapsis || dvRem < 0.2 {
                setThrottle(sim, 0)
                if sim.activeBody == .luna {
                    phase = .returnPlan
                } else {
                    phase = goal == .orbit ? .done : .parked
                }
            }

        case .parked:
            setThrottle(sim, 0)
            phase = .waitPhase

        case .waitPhase:
            setThrottle(sim, 0)
            sim.autopilotDirection = v
            let phi = TrajectoryPredictor.lunaPhase(position: r, velocity: v, time: sim.time)
            let req = TrajectoryPredictor.hohmannLunaPhase(radius: rm)
            let dv = TrajectoryPredictor.hohmannLunaDeltaV(radius: rm)
            let bt = burnTime(sim, dv)
            let ws = (body.mu / (rm * rm * rm)).squareRoot()
            let rel = ws - World.lunaAngularRate
            let lead = rel * bt / 2
            let diff = wrap2Pi(phi - req - lead)
            let wait = diff / rel
            if wait < 1 || diff > 2 * Double.pi - 0.002 {
                stopWarp(sim)
                phase = .transferBurn
            } else {
                warp(sim, toCover: wait)
            }

        case .transferBurn:
            stopWarp(sim)
            autoStage(sim)
            sim.autopilotDirection = v
            let target = Bodies.luna.orbitRadius
            let ra = el.isClosed ? el.apoapsisRadius : .infinity
            setThrottle(sim, clamp((target - ra) / 400_000, 0.05, 1))
            if ra >= target {
                setThrottle(sim, 0)
                phase = sim.predictTrajectory().encounter != nil ? .coastToLuna : .failed
            }

        case .coastToLuna:
            setThrottle(sim, 0)
            if sim.activeBody == .luna {
                stopWarp(sim)
                phase = goal == .lunaEncounter ? .done : .lunaCorrection
            } else {
                // Шаг ускорения выбирается по времени до встречи.
                let enc = sim.predictTrajectory().encounter
                warp(sim, toCover: max(1, (enc?.time ?? sim.time + 1e5) - sim.time))
            }

        case .lunaCorrection:
            // Поднять перицентр у Луны до безопасного (траектория Гомана целит почти в центр).
            stopWarp(sim)
            autoStage(sim)
            let pe = el.periapsisRadius - body.radius
            if pe >= lunaPeriapsis {
                setThrottle(sim, 0)
                phase = .coastToPeriapsis
                break
            }
            let vh = v.normalized
            // Смещаем скорость вбок от прицельной линии на центр Луны.
            var away = up - vh * up.dot(vh)
            if away.lengthSquared < 1e-9 { away = vh.cross(.unitZ) }
            sim.autopilotDirection = away.normalized
            let nose = sim.snapshot.vessels.first { $0.id == sim.snapshot.activeVessel }?.attitude.nose ?? away
            let aligned = nose.dot(away.normalized) > 0.98
            setThrottle(sim, aligned ? clamp((lunaPeriapsis - pe) / 50_000 + 0.05, 0.05, 1) : 0)

        case .coastToPeriapsis:
            setThrottle(sim, 0)
            sim.autopilotDirection = -v
            let vPe = el.angularMomentum.length / el.periapsisRadius
            let vCirc = (body.mu / el.periapsisRadius).squareRoot()
            let bt = burnTime(sim, vPe - vCirc)
            let wait = (el.timeToPeriapsis ?? 0) - bt / 2
            if wait <= 1 {
                stopWarp(sim)
                phase = .lunaCapture
            } else {
                warp(sim, toCover: wait - 1)
            }

        case .lunaCapture:
            autoStage(sim)
            sim.autopilotDirection = -v
            setThrottle(sim, 1)
            if el.isClosed && el.apoapsisRadius < body.radius + 60_000 {
                setThrottle(sim, 0)
                phase = .deorbit
            }

        case .deorbit:
            // Гасим горизонтальную скорость, затем снижение.
            stopWarp(sim)
            autoStage(sim)
            let vr = v.dot(up)
            let vhVec = v - up * vr
            sim.autopilotDirection = -vhVec
            let nose = sim.snapshot.vessels.first { $0.id == sim.snapshot.activeVessel }?.attitude.nose ?? -vhVec
            setThrottle(sim, nose.dot(-vhVec.normalized) > 0.95 ? clamp(vhVec.length / 100, 0.05, 1) : 0)
            if vhVec.length < 3 { phase = .descent }

        case .descent:
            stopWarp(sim)
            if situation == .landed || situation == .splashed {
                setThrottle(sim, 0)
                if goal == .lunaReturn {
                    // Взлёт к низкой орбите Луны.
                    targetApoapsis = 20_000
                    targetPeriapsis = 15_000
                    phase = .ascent
                    setThrottle(sim, 1)
                    sim.autopilotDirection = up
                } else {
                    phase = .done
                }
                break
            }
            let hgt = sim.snapshot.telemetry.heightAboveTerrain
            let vr = v.dot(up)
            let vhVec = v - up * vr
            let g = body.mu / (rm * rm)
            let perf = sim.currentStagePerformance
            let amax = perf.thrust / sim.activeMass
            // Скорость снижения: тормозной путь при 60 % тяги + небольшой запас.
            let brake = max(0.1, amax * 0.6 - g)
            let vTarget = -min((2 * brake * max(0, hgt - 5)).squareRoot(), 200) - 1.5
            let aUp = g + (vTarget - vr) * 1.5
            let a = up * max(0, aUp) - vhVec * 0.5
            sim.autopilotDirection = a.lengthSquared > 1e-6 ? a : up
            setThrottle(sim, amax > 0 ? a.length / amax : 0)
            autoStage(sim)

        case .returnPlan:
            setThrottle(sim, 0)
            stopWarp(sim)
            returnNode = planReturn(sim)
            phase = returnNode == nil ? .failed : .returnBurn

        case .returnBurn:
            guard let node = returnNode else { phase = .failed; break }
            sim.autopilotDirection = v
            let bt = burnTime(sim, node.prograde)
            let wait = node.time - bt / 2 - sim.time
            if wait > 1 && sim.snapshot.telemetry.thrust == 0 {
                setThrottle(sim, 0)
                warp(sim, toCover: wait - 1)
                break
            }
            stopWarp(sim)
            autoStage(sim)
            // Перицентр у Терры очень чувствителен к Δv (≈ 7 км на 1 м/с): после выхода на
            // траекторию возврата проверяем каждый кадр и сбрасываем тягу.
            let escaping = !el.isClosed || el.apoapsisRadius > body.soiRadius
            if escaping || sim.time - lastCheck >= 1 {
                lastCheck = sim.time
                let ret = sim.predictTrajectory().returnToTerra
                if let ret, ret.periapsisAltitude <= returnPeriapsis {
                    setThrottle(sim, 0)
                    phase = .coastHome
                    break
                }
                let pe = ret?.periapsisAltitude ?? .infinity
                setThrottle(sim, clamp((pe - returnPeriapsis) / 1_500_000, 0.03, 1))
            }

        case .coastHome:
            setThrottle(sim, 0)
            sim.autopilotDirection = -v
            if sim.activeBody == .terra && alt < body.atmosphereHeight {
                stopWarp(sim)
                // Перед входом сбросить отработавшие ступени: в атмосферу — капсула (с экраном, если есть).
                for _ in 0..<4 where sim.snapshot.telemetry.nextStageAction == .separate { sim.send(.stage) }
                sim.send(.deployChute)
                phase = .reentry
                break
            }
            let horizon: Double
            if sim.activeBody == .luna {
                horizon = (sim.predictTrajectory(maxPatches: 2).returnToTerra?.time ?? sim.time + 1e4) - sim.time
            } else {
                horizon = el.timeToPeriapsis ?? 1e4
            }
            warp(sim, toCover: max(1, horizon))

        case .reentry:
            if situation == .landed || situation == .splashed {
                setThrottle(sim, 0)
                phase = .done
                break
            }
            if alt > body.atmosphereHeight && v.dot(up) > 0 {
                // Выскочили из атмосферы — ещё виток на рельсах.
                phase = .coastHome
                break
            }
            let t = sim.snapshot.telemetry
            let air = v - World.surfaceVelocity(body: sim.activeBody, position: r)
            if t.chute == .open && t.heightAboveTerrain < 400 && sim.currentStageHasFuel {
                // Мягкое касание двигателем под куполом.
                let vr = v.dot(up)
                let g = body.mu / (rm * rm)
                let amax = sim.currentStagePerformance.thrust / sim.activeMass
                let aUp = g + (-3 - vr) * 1.0
                sim.autopilotDirection = up
                setThrottle(sim, amax > 0 ? max(0, aUp - g * 0.0) / amax : 0)
            } else if t.chute == .open || t.chute == .deploying {
                setThrottle(sim, 0)
                sim.autopilotDirection = up
            } else if t.thermal.ablatorCapacity > 0 && air.length > 1_000 {
                // Быстро и есть экран: щитом к потоку (нос против воздушной скорости).
                setThrottle(sim, 0)
                sim.autopilotDirection = -air
            } else {
                // Боком к потоку: сопротивление растёт с углом атаки (×3.5), купол раскроется выше.
                setThrottle(sim, 0)
                let a = air.normalized
                let side = up - a * up.dot(a)
                sim.autopilotDirection = side.lengthSquared > 1e-6 ? side : nil
            }

        case .done, .failed:
            setThrottle(sim, 0)
        }
    }

    /// Время и прогрейд-импульс выхода с орбиты Луны, дающие перицентр у Терры около `returnPeriapsis`.
    private func planReturn(_ sim: FlightSim) -> ManeuverNode? {
        let el = sim.activeElements
        guard el.isClosed else { return nil }
        let rp = el.periapsisRadius
        let mu = Bodies.luna.mu
        // Нужный избыток скорости ≈ скорость Луны минус апоцентровая скорость возвратного эллипса.
        let r2 = Bodies.luna.orbitRadius, r1 = Bodies.terra.radius + returnPeriapsis
        let vApo = (Bodies.terra.mu * (2 / r2 - 2 / (r1 + r2))).squareRoot()
        let vInf = r2 * World.lunaAngularRate - vApo
        let vNeeded = (vInf * vInf + 2 * mu / rp).squareRoot()
        let dv0 = vNeeded - (mu / rp).squareRoot()
        var best: (score: Double, node: ManeuverNode)?
        for k in 0..<72 {
            let t = sim.time + 120 + el.period * Double(k) / 72
            let node = ManeuverNode(time: t, prograde: dv0 * 1.02)
            guard let p = sim.predictManeuver(node), let ret = p.trajectory.returnToTerra else { continue }
            let score = abs(ret.periapsisAltitude - returnPeriapsis * 0.5)
            if best == nil || score < best!.score { best = (score, node) }
        }
        return best?.node
    }

    private func horizontalPrograde(_ r: Vec3, _ v: Vec3) -> Vec3 {
        let n = r.cross(v).normalized
        return n.cross(r.normalized)
    }
}
