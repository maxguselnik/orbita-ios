import Foundation
import OrbitPhysics

/// Компонента импульса узла манёвра.
enum ManeuverAxis: CaseIterable, Hashable, Sendable {
    case prograde, normal, radial

    func value(_ node: ManeuverNode) -> Double {
        switch self {
        case .prograde: node.prograde
        case .normal: node.normal
        case .radial: node.radial
        }
    }

    func add(_ deltaV: Double, to node: inout ManeuverNode) {
        switch self {
        case .prograde: node.prograde += deltaV
        case .normal: node.normal += deltaV
        case .radial: node.radial += deltaV
        }
    }

    var shortName: String {
        switch self {
        case .prograde: "ПРОГР"
        case .normal: "НОРМ"
        case .radial: "РАД"
        }
    }

    var fullName: String {
        switch self {
        case .prograde: "по скорости"
        case .normal: "по нормали"
        case .radial: "радиально"
        }
    }
}

/// Ручка Δv вокруг узла: компонента и направление (+1 — увеличивает компоненту).
enum ManeuverHandle: CaseIterable, Hashable, Sendable {
    case prograde, retrograde, normal, antiNormal, radialOut, radialIn

    var axis: ManeuverAxis {
        switch self {
        case .prograde, .retrograde: .prograde
        case .normal, .antiNormal: .normal
        case .radialOut, .radialIn: .radial
        }
    }

    var sign: Double {
        switch self {
        case .prograde, .normal, .radialOut: 1
        case .retrograde, .antiNormal, .radialIn: -1
        }
    }

    /// Значок навбола для ручки.
    var sasMode: SASMode {
        switch self {
        case .prograde: .prograde
        case .retrograde: .retrograde
        case .normal: .normal
        case .antiNormal: .antiNormal
        case .radialOut: .radialOut
        case .radialIn: .radialIn
        }
    }

    var label: String {
        switch self {
        case .prograde: "Прогрейд"
        case .retrograde: "Ретрогрейд"
        case .normal: "Нормаль"
        case .antiNormal: "Антинормаль"
        case .radialOut: "Радиально наружу"
        case .radialIn: "Радиально внутрь"
        }
    }
}

/// Палец на ручке Δv: модель применяет изменение каждый кадр (`FlightHUDModel.tick`).
struct ManeuverDrag: Sendable {
    var handle: ManeuverHandle
    /// Отвод пальца вдоль ручки, pt: + — от узла (импульс в сторону ручки), − — к узлу (обратно).
    var offset: Double
    /// Время кадра начала удержания (ставит модель).
    var start: TimeInterval?

    init(handle: ManeuverHandle, offset: Double = 0) {
        self.handle = handle
        self.offset = offset
    }

    /// Мёртвая зона у ручки, pt.
    static let deadZone = 4.0

    /// Скорость изменения компоненты, м/с за секунду: квадратично растёт с отводом пальца
    /// (≈ 4 м/с² при 30 pt, ≈ 70 м/с² при 120 pt) и до ×4 за несколько секунд удержания.
    static func rate(offset: Double, held: TimeInterval) -> Double {
        let d = min(abs(offset), 140) - deadZone
        guard d > 0 else { return 0 }
        let base = 0.4 + 4.4 * (d / 30) * (d / 30)
        let boost = 1 + min(max(held, 0), 6) * 0.5
        return (offset < 0 ? -1 : 1) * base * boost
    }
}
