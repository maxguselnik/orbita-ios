import OrbitPhysics
import RealityKit
import SwiftUI
import UIKit

/// 3D-портреты экипажа (поток B, этап 5.4): ряд ячеек 40:46 слева направо без промежутков, размер задаёт вызывающий.
/// Одна `RealityView` на весь ряд: у каждого места своя «кабина», камера одна, почти ортографическая
/// (далеко и узкая), поэтому ячейки стоят в мире вплотную, как на экране. Пусто — ничего.
struct CrewPortraitView: View {
    let states: [CrewModel.State]
    @State private var stage = CrewStage()

    init(states: [CrewModel.State]) {
        self.states = states
    }

    var body: some View {
        if !states.isEmpty {
            let stage = self.stage
            RealityView { content in
                content.camera = .virtual
                // Вьюха может пересоздаваться, сцена живёт дольше: отцепить корень от прошлого родителя.
                stage.root.removeFromParent()
                content.add(stage.root)
            }
            .aspectRatio(CGFloat(states.count) * 40 / 46, contentMode: .fit)
            .onAppear { stage.start() }
            .onDisappear { stage.stop() }
            .onChange(of: states, initial: true) { _, new in stage.apply(new) }
        }
    }
}

/// Сцена ряда портретов: камера, свет, места (слоты по индексу — один член экипажа может стоять в ряду
/// несколько раз, как в галерее), цикл анимации не чаще 30 Гц.
@MainActor
final class CrewStage {
    let root = Entity()
    private let camera = PerspectiveCamera()
    private var ready = false
    private var slots: [CrewCharacter?] = []
    private var states: [CrewModel.State] = []
    private var generation = 0
    private var loop: Task<Void, Never>?
    private let clock = ContinuousClock()
    private let epoch = ContinuousClock.now

    /// Полувысота кадра в плоскости головы (как у камеры макета: fov 30° с 9 единиц).
    static let halfHeight: Float = 2.45
    /// Камера далеко и с узким углом — проекция почти параллельная, ячейки не перекашиваются.
    static let distance: Float = 400
    static let cellWidth: Float = 2 * halfHeight * 40 / 46

    private var time: Double {
        let d = clock.now - epoch
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    private func setUp() {
        guard !ready else { return }
        ready = true
        camera.camera.fieldOfViewInDegrees = 2 * atan(Self.halfHeight / Self.distance) * 180 / .pi
        camera.camera.near = Self.distance - 12
        camera.camera.far = Self.distance + 12
        root.addChild(camera)
        // Свет макета: тёплый ключевой, холодный заполняющий, контровой, небо (вместо полусферического).
        let lights: [(F3, UInt32, Float)] = [
            (F3(2.2, 3.2, 4.5), 0xfff1e0, 5_500),
            (F3(-3.5, 0.5, 3), 0xbcd2ff, 1_600),
            (F3(-2.5, 2.5, -3), 0x7ce3ff, 3_200),
            (F3(0, 4, 1), 0xdfe8ff, 1_200),
        ]
        for (from, color, lux) in lights {
            let l = DirectionalLight()
            l.light.intensity = lux
            l.light.color = CrewColor(color).ui
            l.look(at: .zero, from: from, relativeTo: nil)
            root.addChild(l)
        }
    }

    func apply(_ next: [CrewModel.State]) {
        setUp()
        states = next
        camera.position = F3(0, CrewCabin.centerY, Self.distance)
        generation += 1
        let gen = generation
        let members = next.map(\.member)
        Task { [weak self] in
            for m in members { await CrewAssets.shared.prepare(id: m.id, name: m.name) }
            guard let self, self.generation == gen else { return }
            self.sync()
        }
    }

    /// Места по индексу: новый член экипажа на месте — новая сущность, иначе только настроение.
    private func sync() {
        let t = time
        let n = states.count
        while slots.count > n {
            slots.removeLast()?.root.removeFromParent()
        }
        for (i, s) in states.enumerated() {
            var slot = i < slots.count ? slots[i] : nil
            if let old = slot, old.member != s.member {
                old.root.removeFromParent()
                slot = nil
            }
            let fresh = slot == nil
            let c = slot ?? CrewCharacter(member: s.member, seed: Double(i), cellWidth: Self.cellWidth)
            if fresh { root.addChild(c.root) }
            c.root.position = F3((Float(i) - Float(n - 1) / 2) * Self.cellWidth, 0, 0)
            c.set(mood: s.mood, intensity: s.intensity, time: t, animated: !fresh)
            if i < slots.count { slots[i] = c } else { slots.append(c) }
            if fresh { c.update(time: t) }
        }
    }

    func start() {
        setUp()
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                let t = self.time
                for case let c? in self.slots { c.update(time: t) }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}
