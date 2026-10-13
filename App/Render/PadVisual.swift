import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Стартовая площадка: бетонная плита с разметкой, оригинальная ферменная башня обслуживания,
/// здания, баки, мачты освещения и луг вокруг (процедурные текстуры, один раз и в кэш).
/// Локальные оси: +Y — вверх, +X — восток, +Z — юг (как оси корабля на площадке); y = 0 — `Terrain.padHeight`.
@MainActor
final class PadVisual {
    let root = Entity()
    /// Положение и поворот площадки в системе, связанной с Террой.
    let positionBF: D3
    let rotationBF: simd_quatd

    private let slabTop = ModelEntity()
    private let walls = ModelEntity()
    private let ground = ModelEntity()

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

        // Мачты освещения по углам плиты: тонкая опора, рейка с фонарями наверху.
        var details = MeshBuilder()
        var lamps = MeshBuilder()
        for (x, z) in [(Float(-13), Float(11)), (Float(13), Float(11)), (Float(13), Float(-13)), (Float(-13), Float(-13))] {
            details.beam(F3(x, 0, z), F3(x, 14, z), thickness: 0.24)
            details.box(center: F3(x, 14.2, z), x: F3(1.0, 0, 0), y: F3(0, 0.1, 0), z: F3(0, 0, 0.4))
            lamps.box(center: F3(x, 14.02, z), x: F3(0.9, 0, 0), y: F3(0, 0.05, 0), z: F3(0, 0, 0.3))
        }
        // Низкий бункер у края плиты.
        details.box(center: F3(11, 0.9, -9.5), x: F3(1.8, 0, 0), y: F3(0, 0.9, 0), z: F3(0, 0, 1.2))

        // Здание управления: окна по длинным стенам, плоская крыша другого цвета, антенна.
        let bx: Float = 21, bz: Float = -14, bw: Float = 7.5, bh: Float = 3.2, bd: Float = 3.2
        var building = MeshBuilder()
        building.box(center: F3(bx, bh / 2, bz), x: F3(bw, 0, 0), y: F3(0, bh / 2, 0), z: F3(0, 0, bd))
        var roof = MeshBuilder()
        roof.box(center: F3(bx, bh + 0.15, bz), x: F3(bw + 0.3, 0, 0), y: F3(0, 0.15, 0), z: F3(0, 0, bd + 0.3))
        roof.box(center: F3(bx + 2.5, bh + 0.75, bz), x: F3(0.9, 0, 0), y: F3(0, 0.45, 0), z: F3(0, 0, 0.9))
        roof.beam(F3(bx - 3, bh + 0.3, bz), F3(bx - 3, bh + 4.5, bz), thickness: 0.08)
        var facade = MeshBuilder()
        for s: Float in [1, -1] {
            let z = bz + s * (bd + 0.02)
            let i0 = facade.vertex(F3(bx - bw, 0, z), F3(0, 0, s), SIMD2(s > 0 ? 0 : 1, 1))
            let i1 = facade.vertex(F3(bx + bw, 0, z), F3(0, 0, s), SIMD2(s > 0 ? 1 : 0, 1))
            let i2 = facade.vertex(F3(bx + bw, bh, z), F3(0, 0, s), SIMD2(s > 0 ? 1 : 0, 0))
            let i3 = facade.vertex(F3(bx - bw, bh, z), F3(0, 0, s), SIMD2(s > 0 ? 0 : 1, 0))
            facade.quad(i0, i1, i2, i3, facing: F3(0, 0, s))
        }

        // Склад: низкий корпус, плоская тёмная крыша, ворота.
        let hx: Float = -24, hz: Float = -12
        var warehouse = MeshBuilder()
        warehouse.box(center: F3(hx, 2.1, hz), x: F3(6, 0, 0), y: F3(0, 2.1, 0), z: F3(0, 0, 4.2))
        var warehouseRoof = MeshBuilder()
        warehouseRoof.box(center: F3(hx, 4.3, hz), x: F3(6.3, 0, 0), y: F3(0, 0.15, 0), z: F3(0, 0, 4.5))
        warehouseRoof.box(center: F3(hx, 1.7, hz + 4.22), x: F3(2.4, 0, 0), y: F3(0, 1.7, 0), z: F3(0, 0, 0.06))

        // Баки: белый цилиндр с куполом и красным поясом.
        var tanks = MeshBuilder()
        var bands = MeshBuilder()
        for p in [F3(-17, 0, -27), F3(-10.5, 0, -28)] {
            var t = MeshBuilder()
            t.lathe([SIMD2(0, 0), SIMD2(2.6, 0), SIMD2(2.6, 7.2), SIMD2(2.2, 8.0), SIMD2(1.2, 8.6), SIMD2(0, 8.8)], segments: 32)
            t.positions = t.positions.map { $0 + p }
            tanks.append(t)
            var d = MeshBuilder()
            d.lathe([SIMD2(2.66, 3.2), SIMD2(2.66, 4.2)], segments: 32, twoSided: true)
            d.positions = d.positions.map { $0 + p }
            bands.append(d)
        }

        // Верх плиты: квадрат с текстурой (UV 0…1).
        var top = MeshBuilder()
        let hs = Float(BackdropTextures.slabSize / 2)
        let t0 = top.vertex(F3(-hs, 0.052, -hs), F3(0, 1, 0), SIMD2(0, 0))
        let t1 = top.vertex(F3(hs, 0.052, -hs), F3(0, 1, 0), SIMD2(1, 0))
        let t2 = top.vertex(F3(hs, 0.052, hs), F3(0, 1, 0), SIMD2(1, 1))
        let t3 = top.vertex(F3(-hs, 0.052, hs), F3(0, 1, 0), SIMD2(0, 1))
        top.quad(t0, t1, t2, t3, facing: F3(0, 1, 0))

        let lampMat = UnlitMaterial(color: UIColor(red: 1, green: 0.95, blue: 0.75, alpha: 1))
        let roofMat = SimpleMaterial(color: UIColor(red: 0.36, green: 0.22, blue: 0.20, alpha: 1), roughness: 0.8, isMetallic: false)
        let wallMat = SimpleMaterial(color: UIColor(white: 0.78, alpha: 1), roughness: 0.9, isMetallic: false)
        let shedMat = SimpleMaterial(color: UIColor(red: 0.62, green: 0.66, blue: 0.70, alpha: 1), roughness: 0.7, isMetallic: false)
        let list: [(MeshBuilder, any Material)] = [
            (slab, mats.concrete), (plate, mats.concreteDark), (tower, mats.towerSteel), (arms, mats.lightGray),
            (details, mats.lightGray), (lamps, lampMat), (building, wallMat), (roof, roofMat),
            (warehouse, shedMat), (warehouseRoof, mats.darkGray), (tanks, mats.white), (bands, mats.red),
        ]
        for (b, m) in list {
            if let mesh = b.makeMesh(name: "pad") {
                root.addChild(ModelEntity(mesh: mesh, materials: [m]))
            }
        }

        // Текстурированные части: пока текстуры считаются, стоят однотонные запасные материалы.
        if let mesh = top.makeMesh(name: "padSlabTop") {
            slabTop.model = ModelComponent(mesh: mesh, materials: [mats.concrete])
            root.addChild(slabTop)
        }
        if let mesh = facade.makeMesh(name: "padFacade") {
            walls.model = ModelComponent(mesh: mesh, materials: [wallMat])
            root.addChild(walls)
        }
        if let mesh = Self.groundMesh() {
            let grass = SimpleMaterial(color: UIColor(red: 0.30, green: 0.45, blue: 0.18, alpha: 1), roughness: 0.95, isMetallic: false)
            ground.model = ModelComponent(mesh: mesh, materials: [grass])
            root.addChild(ground)
        }

        // Расчёт текстур — вне главного потока, один раз.
        let edge = Palette.terraColor(zone: 4, u: 0.45)
        Task { [weak self] in
            let g = await Task.detached(priority: .utility) { BackdropTextures.groundBytes(size: 1024, edge: edge) }.value
            let c = await Task.detached(priority: .utility) { BackdropTextures.slabBytes(size: 512) }.value
            let f = await Task.detached(priority: .utility) { BackdropTextures.facadeBytes(width: 512, height: 128) }.value
            let gt = await BackdropTextures.texture(width: 1024, height: 1024, mipmaps: true, bytes: g)
            let ct = await BackdropTextures.texture(width: 512, height: 512, mipmaps: true, bytes: c)
            let ft = await BackdropTextures.texture(width: 512, height: 128, mipmaps: true, bytes: f)
            guard let self else { return }
            if let gt { self.ground.model?.materials = [Self.litMaterial(gt, roughness: 0.95)] }
            if let ct { self.slabTop.model?.materials = [Self.litMaterial(ct, roughness: 0.92)] }
            if let ft { self.walls.model?.materials = [Self.litMaterial(ft, roughness: 0.8)] }
        }
    }

    /// Освещаемый материал с текстурой цвета (без бликов, как у рельефа).
    private static func litMaterial(_ tex: TextureResource, roughness: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .white, texture: .init(tex))
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: 0)
        m.specular = .init(floatLiteral: 0)
        return m
    }

    /// Луг: кольцо по сфере вокруг площадки (вырез под плиту), чуть выше рельефа; UV — квадрат 0…1.
    /// У рельефа в зоне площадки высота постоянна, поэтому зазор над ним — десятки сантиметров,
    /// растущие с расстоянием (глубина), а край текстуры совпадает по цвету с рельефом.
    private static func groundMesh() -> MeshResource? {
        let rp = Bodies.terra.radius + Terrain.padHeight
        let r0 = BackdropTextures.groundHole, r1 = BackdropTextures.groundRadius
        let rings = 36, segs = 72
        var b = MeshBuilder()
        var idx: [[UInt32]] = []
        for i in 0...rings {
            let t = Double(i) / Double(rings)
            let r = r0 * pow(r1 / r0, t)
            let lift = 0.14 + 0.0007 * r
            var row: [UInt32] = []
            for j in 0...segs {
                let a = 2 * Double.pi * Double(j) / Double(segs)
                let x = r * cos(a), z = r * sin(a)
                let y = (rp * rp - r * r).squareRoot() - rp + lift
                let uv = SIMD2<Float>(Float((x / r1 + 1) / 2), Float((z / r1 + 1) / 2))
                row.append(b.vertex(F3(Float(x), Float(y), Float(z)), F3(0, 1, 0), uv))
            }
            idx.append(row)
        }
        for i in 0..<rings {
            for j in 0..<segs {
                b.quad(idx[i][j], idx[i][j + 1], idx[i + 1][j + 1], idx[i + 1][j], facing: F3(0, 1, 0))
            }
        }
        return b.makeMesh(name: "padGround")
    }
}
