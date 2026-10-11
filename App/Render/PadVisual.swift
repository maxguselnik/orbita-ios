import OrbitPhysics
import RealityKit
import simd

/// Стартовая площадка: бетонная плита и оригинальная ферменная башня обслуживания.
/// Локальные оси: +Y — вверх, +X — восток, +Z — юг (как оси корабля на площадке); y = 0 — `Terrain.padHeight`.
@MainActor
final class PadVisual {
    let root = Entity()
    /// Положение и поворот площадки в системе, связанной с Террой.
    let positionBF: D3
    let rotationBF: simd_quatd

    init() {
        let up = World.padDirection.d3
        let east = simd_normalize(simd_cross(D3(0, 0, 1), up))
        let north = simd_cross(up, east)
        rotationBF = simd_quatd(simd_double3x3(columns: (east, up, -north)))
        positionBF = up * (Bodies.terra.radius + Terrain.padHeight)

        let mats = RenderMaterials.shared
        var slab = MeshBuilder()
        slab.box(center: F3(0, -1.45, 0), x: F3(16, 0, 0), y: F3(0, 1.5, 0), z: F3(0, 0, 16))
        var plate = MeshBuilder()
        plate.box(center: F3(0, 0.06, 0), x: F3(3.4, 0, 0), y: F3(0, 0.03, 0), z: F3(0, 0, 3.4))
        // Кольцо-опора под ракетой.
        plate.lathe([SIMD2(0.9, 0.08), SIMD2(1.45, 0.08), SIMD2(1.45, 0.2), SIMD2(0.9, 0.2), SIMD2(0.9, 0.08)], segments: 24)

        var tower = MeshBuilder()
        let towerH: Float = 34
        let cz: Float = -7.6, half: Float = 1.6
        let corners = [F3(-half, 0, cz - half), F3(half, 0, cz - half), F3(half, 0, cz + half), F3(-half, 0, cz + half)]
        for c in corners {
            tower.beam(c, c + F3(0, towerH, 0), thickness: 0.26)
        }
        let bay: Float = 3.4
        var y: Float = 0
        var flip = false
        while y < towerH - 0.1 {
            let y1 = min(towerH, y + bay)
            for k in 0..<4 {
                let a = corners[k], b = corners[(k + 1) % 4]
                tower.beam(a + F3(0, y1, 0), b + F3(0, y1, 0), thickness: 0.14)
                if flip {
                    tower.beam(a + F3(0, y, 0), b + F3(0, y1, 0), thickness: 0.1)
                } else {
                    tower.beam(b + F3(0, y, 0), a + F3(0, y1, 0), thickness: 0.1)
                }
            }
            flip.toggle()
            y = y1
        }
        // Мачта молниеотвода и площадка наверху.
        tower.beam(F3(0, towerH, cz), F3(0, towerH + 7, cz), thickness: 0.12)
        tower.box(center: F3(0, towerH + 0.1, cz), x: F3(half + 0.3, 0, 0), y: F3(0, 0.1, 0), z: F3(0, 0, half + 0.3))

        var arms = MeshBuilder()
        for (h, reach) in [(Float(8.6), Float(1.0)), (Float(12.8), Float(0.75))] {
            let z0 = cz + half, z1 = -reach
            for dx: Float in [-0.45, 0.45] {
                arms.beam(F3(dx, h, z0), F3(dx, h, z1), thickness: 0.14)
                arms.beam(F3(dx, h + 0.9, z0), F3(dx, h + 0.9, z1 - 0.2), thickness: 0.1)
            }
            var z = z0
            while z > z1 {
                arms.beam(F3(-0.45, h, z), F3(0.45, h + 0.9, z), thickness: 0.07)
                arms.beam(F3(-0.45, h, z), F3(-0.45, h + 0.9, z), thickness: 0.07)
                arms.beam(F3(0.45, h, z), F3(0.45, h + 0.9, z), thickness: 0.07)
                z -= 1.2
            }
            // Захват у ракеты.
            arms.box(center: F3(0, h + 0.45, z1), x: F3(0.7, 0, 0), y: F3(0, 0.5, 0), z: F3(0, 0, 0.08))
        }
        // Невысокие кабель-мачты и ограждение по краям.
        var details = MeshBuilder()
        for (x, z) in [(Float(-11), Float(9)), (Float(11), Float(9)), (Float(11), Float(-11)), (Float(-11), Float(-11))] {
            details.beam(F3(x, 0, z), F3(x, 9, z), thickness: 0.18)
            details.box(center: F3(x, 9.2, z), x: F3(0.35, 0, 0), y: F3(0, 0.2, 0), z: F3(0, 0, 0.35))
        }
        details.box(center: F3(9, 1.2, -9), x: F3(2.5, 0, 0), y: F3(0, 1.2, 0), z: F3(0, 0, 1.6))

        let list: [(MeshBuilder, any Material)] = [(slab, mats.concrete), (plate, mats.concreteDark),
                                                   (tower, mats.towerSteel), (arms, mats.lightGray),
                                                   (details, mats.lightGray)]
        for (b, m) in list {
            if let mesh = b.makeMesh(name: "pad") {
                root.addChild(ModelEntity(mesh: mesh, materials: [m]))
            }
        }
    }
}
