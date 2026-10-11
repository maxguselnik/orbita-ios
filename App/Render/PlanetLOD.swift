import OrbitPhysics
import RealityKit
import simd

/// LOD-рельеф тела: квадродерево патчей на кубосфере, выбор по расстоянию до камеры,
/// отсечение за горизонтом, генерация геометрии вне главного потока.
@MainActor
final class PlanetLOD {
    let body: BodyID
    let radius: Double
    let root = Entity()

    private let maxLevel: Int
    /// Делить узел, если расстояние до него < splitFactor × размер.
    private let splitFactor = 1.5
    /// Наибольшая высота рельефа над радиусом и наименьшая видимая (для горизонта), м.
    private let maxHeight: Double
    private let minHeight: Double
    private let slope: Double

    private final class Record {
        var entity: ModelEntity?
        var center: D3 = .zero
        var lastUsed = 0
        var building = true
        var shown = false
    }

    private var records: [PatchKey: Record] = [:]
    private var split: Set<PatchKey> = []
    private var nextSplit: Set<PatchKey> = []
    private var visible: [PatchKey] = []
    private var shown: [PatchKey] = []
    private var ready: [(PatchKey, PatchGeometry)] = []
    private var inFlight = 0
    private var frame = 0
    var material: (any Material)?

    /// Сколько патчей сейчас на экране (для отладки и бюджета).
    var visibleCount: Int { visible.count }

    static let maxInFlight = 6
    static let meshesPerFrame = 4
    static let cacheLimit = 700

    init(body: BodyID) {
        self.body = body
        radius = Bodies.body(body).radius
        maxLevel = 10
        maxHeight = 4_500
        minHeight = body == .terra ? 0 : -4_000
        slope = body == .terra ? 0.08 : 0.5
    }

    /// Обновление за кадр. `eyeBF` — камера в системе, связанной с телом (м);
    /// `center` — центр тела относительно точки отсчёта; `rotation` — тело → мир; `scale` — масштаб-импостор.
    func update(eyeBF: D3, center: D3, rotation: simd_quatd, scale: Double) {
        frame += 1
        guard material != nil else { return }
        integrateReady()

        visible.removeAll(keepingCapacity: true)
        nextSplit.removeAll(keepingCapacity: true)
        let eyeDist = simd_length(eyeBF)
        let eyeDir = eyeDist > 0 ? eyeBF / eyeDist : D3(0, 0, 1)
        let rMin = radius + minHeight
        let horizon = acos(min(1, rMin / max(eyeDist, rMin))) + acos(rMin / (radius + maxHeight))
        for f in 0..<6 {
            select(PatchKey(body: body, face: UInt8(f), level: 0, x: 0, y: 0),
                   eye: eyeBF, eyeDir: eyeDir, horizon: horizon)
        }
        swap(&split, &nextSplit)

        // Скрыть ушедшие, показать и расставить видимые.
        for key in shown {
            if let r = records[key], r.lastUsed != frame, r.shown {
                r.entity?.isEnabled = false
                r.shown = false
            }
        }
        shown.removeAll(keepingCapacity: true)
        let rotf = quatf(rotation)
        let s = Float(scale)
        for key in visible {
            guard let r = records[key], let e = r.entity else { continue }
            let pos = (center + rotation.act(r.center)) * scale
            e.transform = Transform(scale: F3(repeating: s), rotation: rotf, translation: f3(pos))
            if !r.shown {
                e.isEnabled = true
                r.shown = true
            }
            shown.append(key)
        }
        evictIfNeeded()
    }

    private func isReady(_ k: PatchKey) -> Bool { records[k]?.entity != nil }

    private func angleVisible(_ k: PatchKey, eyeDir: D3, horizon: Double) -> Bool {
        let dir = CubeSphere.centerDirection(k)
        let ang = acos(clampd(simd_dot(dir, eyeDir), -1, 1))
        let half = 0.8 * (.pi / 2) / Double(1 << Int(k.level)) + 0.02
        return ang - half < horizon
    }

    private func select(_ k: PatchKey, eye: D3, eyeDir: D3, horizon: Double) {
        guard angleVisible(k, eyeDir: eyeDir, horizon: horizon) else { return }
        let size = CubeSphere.size(k, radius: radius)
        let dir = CubeSphere.centerDirection(k)
        let hc = PatchBuilder.displayHeight(body, Terrain.height(body: body, direction: vec3(dir)))
        let p = dir * (radius + hc)
        let dist = max(0, simd_length(eye - p) - 0.75 * size - min(size * slope, 4_000))
        let factor = split.contains(k) ? splitFactor * 1.25 : splitFactor
        let wantSplit = Int(k.level) < maxLevel && dist < factor * size

        if wantSplit {
            var allReady = true
            for i in 0..<4 {
                let c = k.child(i)
                guard angleVisible(c, eyeDir: eyeDir, horizon: horizon) else { continue }
                if !isReady(c) {
                    allReady = false
                    request(c)
                } else {
                    records[c]?.lastUsed = frame
                }
            }
            if allReady {
                nextSplit.insert(k)
                for i in 0..<4 { select(k.child(i), eye: eye, eyeDir: eyeDir, horizon: horizon) }
                return
            }
        }
        if let r = records[k], r.entity != nil {
            r.lastUsed = frame
            visible.append(k)
        } else {
            request(k)
        }
    }

    private func request(_ k: PatchKey) {
        if let r = records[k] {
            r.lastUsed = frame
            return
        }
        guard inFlight < Self.maxInFlight else { return }
        let r = Record()
        r.lastUsed = frame
        records[k] = r
        inFlight += 1
        Task { [weak self] in
            let geo = await Task.detached(priority: .userInitiated) { PatchBuilder.build(k) }.value
            guard let self else { return }
            self.inFlight -= 1
            self.ready.append((k, geo))
        }
    }

    private func integrateReady() {
        guard !ready.isEmpty, let material else { return }
        var made = 0
        while made < Self.meshesPerFrame, !ready.isEmpty {
            let (k, geo) = ready.removeFirst()
            guard let r = records[k] else { continue }
            r.building = false
            r.center = geo.center
            if let mesh = geo.mesh.makeMesh(name: "patch") {
                let e = ModelEntity(mesh: mesh, materials: [material])
                e.isEnabled = false
                root.addChild(e)
                r.entity = e
            }
            made += 1
        }
    }

    private func evictIfNeeded() {
        guard records.count > Self.cacheLimit else { return }
        let old = records.filter { !$0.value.building && $0.value.lastUsed < frame - 60 && !$0.value.shown }
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (k, r) in old.prefix(records.count - Self.cacheLimit / 2) {
            // Корни не выбрасываем — из них растёт дерево.
            if k.level == 0 { continue }
            r.entity?.removeFromParent()
            records[k] = nil
        }
    }
}
