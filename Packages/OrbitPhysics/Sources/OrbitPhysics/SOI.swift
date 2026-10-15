import Foundation

extension World {
    enum EntrySearch {
        case none
        case entry(Double, StateVector, BodyID)
        case budget(Double, StateVector)
    }

    /// Общий консервативный поиск сразу всех дочерних SOI, с одним бюджетом Кеплера.
    /// Не пропускает планету между редкими точками прогноза на межпланетной орбите.
    static func childEntry(body: BodyID, state: StateVector, time: Double, horizon: Double,
                           calls: inout Int, budget: Int) -> EntrySearch {
        let mu = Bodies.body(body).mu
        let el = OrbitElements(position: state.position, velocity: state.velocity, mu: mu)
        let children = Bodies.children(of: body).filter {
            let child = Bodies.body($0)
            return el.apoapsisRadius >= child.orbitRadius - child.soiRadius
                && el.periapsisRadius <= child.orbitRadius + child.soiRadius
        }
        guard !children.isEmpty else { return .none }
        let alpha = 2 / state.position.length - state.velocity.lengthSquared / mu
        let rMin = el.timeToPeriapsis == nil ? state.position.length : el.periapsisRadius
        let margin = 1_000_000.0
        var t = 0.0
        var st = state
        while true {
            var step = horizon - t
            for id in children {
                let child = Bodies.body(id)
                let p = position(of: id, relativeTo: body, at: time + t)
                let v = velocity(of: id, relativeTo: body, at: time + t)
                let d = st.position - p
                let distance = d.length
                let f = distance - child.soiRadius
                if f <= 0 { return .entry(t, st, id) }
                let fd = d.dot(st.velocity - v) / distance
                let rLo = max(rMin, child.orbitRadius - child.soiRadius - (2 * f + margin), 1)
                let speed = max(0, mu * (2 / rLo - alpha)).squareRoot() + v.length
                let acc = speed * speed / child.soiRadius + mu / (rLo * rLo)
                    + child.orbitRadius * pow(orbitalRate(id), 2)
                var dt = (fd + (fd * fd + 2 * acc * f).squareRoot()) / acc
                dt = min(dt, (f + margin) / max(speed, 1))
                step = min(step, max(dt, 0.01))
            }
            if t + step >= horizon { return .none }
            if calls >= budget - 1 { return .budget(t, st) }
            t += step
            st = Kepler.propagate(position: state.position, velocity: state.velocity, mu: mu, dt: t)
            calls += 1
        }
    }
}
