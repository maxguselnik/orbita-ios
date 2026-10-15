import OrbitPhysics
import SwiftUI

/// Слой карты над 3D-сценой: подписи отметок и ручки Δv узла. Экранные точки зависят от камеры
/// карты (жесты, фокус), поэтому слой пересчитывает проекцию каждый кадр — `TimelineView(.animation)`
/// существует только пока карта открыта. Сам прогноз (`map.snapshot`) меняется не чаще 4–30 Гц.
/// Координаты — весь экран, как у 3D-вьюхи (`map.setViewSize`).
struct MapOverlay: View {
    let model: FlightHUDModel

    var body: some View {
        TimelineView(.animation) { context in
            MapOverlayFrame(model: model, date: context.date)
        }
        .ignoresSafeArea()
    }
}

/// Один кадр слоя карты.
struct MapOverlayFrame: View {
    let model: FlightHUDModel
    /// Время кадра: новая дата — новая проекция.
    let date: Date

    /// Подписи не должны ложиться на значок корабля, точку узла и ручки Δv.
    private static func obstacles(_ model: FlightHUDModel, node: NodeHandleLayout?) -> [CGRect] {
        var obstacles: [CGRect] = []
        if let vessel = vesselPoint(model) {
            obstacles.append(CGRect(x: vessel.x - 24, y: vessel.y - 24, width: 48, height: 48))
        }
        if let node {
            obstacles.append(CGRect(x: node.center.x - 12, y: node.center.y - 12, width: 24, height: 24))
            for item in model.mapExpert ? node.items : [] {
                obstacles.append(CGRect(x: item.point.x - 22, y: item.point.y - 22, width: 44, height: 44))
            }
        }
        return obstacles
    }

    var body: some View {
        let map = model.map
        let snapshot = map.snapshot
        let node = NodeHandleLayout(snapshot: snapshot, map: map)
        let nodeCenter = node?.center
        let labels = MapLabel.layout(snapshot.markers, map: map, obstacles: Self.obstacles(model, node: node))
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                var bodyPoints: [CGPoint] = []
                for id in [BodyID.sol, .vella, .terra, .arda, .taros, .luna] {
                    guard let p = map.project(.zero, body: id), p.x.isFinite, p.y.isFinite,
                          !bodyPoints.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 32 }) else { continue }
                    bodyPoints.append(p)
                    let dot = Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
                    context.fill(dot, with: .color(.white.opacity(0.8)))
                    let text = Text(Bodies.body(id).name).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                    context.draw(text, at: CGPoint(x: p.x + 8, y: p.y + 8), anchor: .topLeading)
                }
                for label in labels {
                    label.draw(in: &context)
                }
                if let c = nodeCenter {
                    let ring = Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16))
                    context.fill(ring, with: .color(NavballPalette.maneuver))
                    context.stroke(ring, with: .color(.white), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)

            if let node {
                // Рамка точки узла для урока.
                Color.clear
                    .frame(width: 28, height: 28)
                    .tutorialAnchor(.mapNode)
                    .position(node.center)
                    .allowsHitTesting(false)
                // Ручки Δv — только в «Эксперт».
                ForEach(model.mapExpert ? node.items : []) { item in
                    ManeuverHandleKnob(handle: item.handle, direction: item.direction, model: model)
                        .tutorialAnchor(optional: item.handle == .prograde ? .mapHandle : nil)
                        .position(item.point)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Значок активного корабля на экране.
    @MainActor
    private static func vesselPoint(_ model: FlightHUDModel) -> CGPoint? {
        let world = model.snapshot
        guard let vessel = world.vessels.first(where: { $0.id == world.activeVessel }),
              let p = model.map.project(vessel.position, body: vessel.body),
              p.x.isFinite, p.y.isFinite else { return nil }
        return p
    }
}

// MARK: - Подписи отметок

/// Подпись отметки на экране. Точка рисуется всегда; плашка — только если нашлось свободное место.
struct MapLabel {
    /// Сторона точки, с которой стоит плашка.
    enum Side: CaseIterable {
        case above, below, right, left
    }

    let point: CGPoint
    let text: String
    let textColor: Color
    let dotColor: Color
    /// Плашка подписи; nil — подпись скрыта (мешает более важной).
    let plate: CGRect?

    private struct Pending {
        let point: CGPoint
        let text: String
        let textColor: Color
        let dotColor: Color
        let below: Bool
        /// 0 — Пе/Ап текущей орбиты, 1 — после узла, SOI, падение, 2 — ВУ/НУ.
        let rank: Int
    }

    private static let gap: CGFloat = 8
    private static let plateHeight: CGFloat = 19

    /// Оценка ширины плашки: шрифт 11 pt bold, цифры моноширинные.
    static func plateSize(_ text: String) -> CGSize {
        CGSize(width: CGFloat(text.count) * 6.9 + 12, height: plateHeight)
    }

    static func plateRect(size: CGSize, at p: CGPoint, side: Side) -> CGRect {
        switch side {
        case .above: CGRect(x: p.x - size.width / 2, y: p.y - gap - size.height, width: size.width, height: size.height)
        case .below: CGRect(x: p.x - size.width / 2, y: p.y + gap, width: size.width, height: size.height)
        case .right: CGRect(x: p.x + gap, y: p.y - size.height / 2, width: size.width, height: size.height)
        case .left: CGRect(x: p.x - gap - size.width, y: p.y - size.height / 2, width: size.width, height: size.height)
        }
    }

    /// Жадная расстановка: сначала важные; плашка уходит на другую сторону, если пересекает препятствие
    /// или уже поставленную плашку; если места нет — менее важная прячется (Пе/Ап текущей орбиты — никогда).
    @MainActor
    static func layout(_ markers: [MapMarker], map: MapModel, obstacles: [CGRect] = []) -> [MapLabel] {
        var pending: [Pending] = []
        for marker in markers {
            guard let caption = Self.caption(marker), let point = map.project(marker.position, body: marker.body),
                  point.x.isFinite, point.y.isFinite else { continue }
            let tint = Self.kindColor(marker.kind)
            let rank: Int
            switch marker.kind {
            case .apoapsis, .periapsis: rank = marker.afterManeuver ? 1 : 0
            case .ascendingNode, .descendingNode: rank = 2
            default: rank = 1
            }
            if marker.afterManeuver {
                pending.append(Pending(point: point, text: caption, textColor: MapPalette.afterManeuver,
                                       dotColor: tint.opacity(0.7), below: true, rank: rank))
            } else {
                pending.append(Pending(point: point, text: caption, textColor: Self.captionColor(marker.kind),
                                       dotColor: tint, below: false, rank: rank))
            }
        }
        return place(pending, obstacles: obstacles)
    }

    private static func place(_ pending: [Pending], obstacles: [CGRect]) -> [MapLabel] {
        var taken = obstacles
        var plates = [CGRect?](repeating: nil, count: pending.count)
        let order = pending.indices.sorted { pending[$0].rank != pending[$1].rank ? pending[$0].rank < pending[$1].rank : $0 < $1 }
        for index in order {
            let item = pending[index]
            let size = plateSize(item.text)
            let sides: [Side] = item.below ? [.below, .above, .right, .left] : [.above, .below, .right, .left]
            let candidates = sides.map { plateRect(size: size, at: item.point, side: $0) }
            if let free = candidates.first(where: { rect in !taken.contains(where: { $0.intersects(rect) }) }) {
                plates[index] = free
                taken.append(free)
            } else if item.rank == 0 {
                plates[index] = candidates[0]
                taken.append(candidates[0])
            }
        }
        return pending.indices.map { i in
            let item = pending[i]
            return MapLabel(point: item.point, text: item.text, textColor: item.textColor,
                            dotColor: item.dotColor, plate: plates[i])
        }
    }

    static func caption(_ marker: MapMarker) -> String? {
        switch marker.kind {
        case .apoapsis:
            return "Ап " + HUDFormat.distance(marker.altitude)
        case .periapsis:
            // Ниже поверхности — короткое «падение» вместо длинного отрицательного числа.
            return marker.altitude < 0 ? "Пе: падение" : "Пе " + HUDFormat.distance(marker.altitude)
        case .ascendingNode:
            return "ВУ"
        case .descendingNode:
            return "НУ"
        case .soiEnter(let body):
            return "Вход в SOI " + MapText.genitive(body)
        case .soiExit:
            return "Выход из SOI"
        case .impact:
            return "Падение"
        case .maneuver:
            // Узел рисуется отдельно, с ручками.
            return nil
        }
    }

    static func kindColor(_ kind: MapMarker.Kind) -> Color {
        switch kind {
        case .apoapsis, .periapsis: HUDStyle.active
        case .ascendingNode, .descendingNode: .white
        case .soiEnter: MapPalette.encounter
        case .soiExit: MapPalette.returnTrip
        case .impact: MapPalette.impact
        case .maneuver: NavballPalette.maneuver
        }
    }

    static func captionColor(_ kind: MapMarker.Kind) -> Color {
        switch kind {
        case .apoapsis, .periapsis: .white
        case .ascendingNode, .descendingNode: HUDStyle.secondaryText
        case .soiEnter, .soiExit, .impact, .maneuver: kindColor(kind)
        }
    }

    func draw(in context: inout GraphicsContext) {
        let dot = Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
        context.fill(dot, with: .color(dotColor))
        context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1)
        guard let plate else { return }

        let resolved = context.resolve(
            Text(text)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(textColor)
        )
        context.fill(Path(roundedRect: plate, cornerRadius: 5), with: .color(.black.opacity(0.55)))
        context.draw(resolved, at: CGPoint(x: plate.midX, y: plate.midY))
    }
}

// MARK: - Ручки узла

/// Экранная раскладка узла: центр и шесть ручек вдоль проекций осей манёвра.
/// Длина ручки — 44…64 pt в зависимости от ракурса (ось «на камеру» — ближе к узлу).
struct NodeHandleLayout {
    struct Item: Identifiable {
        let handle: ManeuverHandle
        let point: CGPoint
        /// Единичное направление ручки на экране (от узла).
        let direction: CGVector
        var id: ManeuverHandle { handle }
    }

    let center: CGPoint
    let items: [Item]

    private static let baseRadius: CGFloat = 44
    private static let extraRadius: CGFloat = 20

    @MainActor
    init?(snapshot: MapSnapshot, map: MapModel) {
        guard let prediction = snapshot.maneuver, let first = prediction.trajectory.patches.first else { return nil }
        let body = prediction.body
        let r = first.start.position
        // Первый участок после узла начинается со скоростью после импульса.
        let v = first.start.velocity - prediction.deltaVVector
        guard let c = map.project(r, body: body), c.x.isFinite, c.y.isFinite else { return nil }
        let basis = TrajectoryPredictor.maneuverBasis(position: r, velocity: v)
        let scale = max(r.length * 0.05, 1)

        func screen(_ d: Vec3) -> CGVector? {
            guard let p = map.project(r + d * scale, body: body), p.x.isFinite, p.y.isFinite else { return nil }
            return CGVector(dx: p.x - c.x, dy: p.y - c.y)
        }
        func length(_ v: CGVector) -> CGFloat { (v.dx * v.dx + v.dy * v.dy).squareRoot() }

        let s = CGFloat(0.5.squareRoot())
        let axes: [(axis: ManeuverAxis, vector: CGVector?, fallback: CGVector)] = [
            (.prograde, screen(basis.prograde), CGVector(dx: 1, dy: 0)),
            (.normal, screen(basis.normal), CGVector(dx: 0, dy: -1)),
            (.radial, screen(basis.radial), CGVector(dx: s, dy: s)),
        ]
        let reference = axes.compactMap { $0.vector.map(length) }.max() ?? 0

        var items: [Item] = []
        for entry in axes {
            var unit = entry.fallback
            var visible: CGFloat = 0
            if let vector = entry.vector, reference > 0 {
                let len = length(vector)
                if len > reference * 0.08 {
                    unit = CGVector(dx: vector.dx / len, dy: vector.dy / len)
                    visible = len / reference
                }
            }
            let radius = Self.baseRadius + Self.extraRadius * visible
            for handle in ManeuverHandle.allCases where handle.axis == entry.axis {
                let sign = CGFloat(handle.sign)
                let direction = CGVector(dx: unit.dx * sign, dy: unit.dy * sign)
                items.append(Item(handle: handle,
                                  point: CGPoint(x: c.x + direction.dx * radius, y: c.y + direction.dy * radius),
                                  direction: direction))
            }
        }
        center = c
        self.items = items
    }
}

/// Ручка Δv: тянуть от узла — импульс в сторону ручки, к узлу — обратно. Скорость изменения
/// растёт с отводом пальца и временем удержания; изменение применяет модель в каждом кадре.
struct ManeuverHandleKnob: View {
    let handle: ManeuverHandle
    let direction: CGVector
    let model: FlightHUDModel

    @GestureState private var pull: CGFloat = 0
    @GestureState private var active = false

    var body: some View {
        let color = Self.color(handle)
        let shown = min(max(pull, -24), 48)
        SASIcon(mode: handle.sasMode)
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
            .background(Circle().fill(Color.black.opacity(active ? 0.7 : 0.45)))
            .overlay(Circle().strokeBorder(color.opacity(active ? 1 : 0.6), lineWidth: active ? 2 : 1))
            .contentShape(Circle())
            .overlay(alignment: .bottom) {
                Text(Self.caption(handle))
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    .offset(y: 12)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if active {
                    HandleValueBubble(model: model, handle: handle)
                        .offset(y: -28)
                        .allowsHitTesting(false)
                }
            }
            .offset(x: direction.dx * shown, y: direction.dy * shown)
            .gesture(drag)
            .onChange(of: active) { _, value in
                // Касание отменено системой — onEnded может не прийти.
                if !value, model.maneuverDrag?.handle == handle { model.maneuverDrag = nil }
            }
            .accessibilityLabel("Ручка узла: \(handle.label)")
            .accessibilityHint("Тяните от узла — добавить импульс, к узлу — убавить")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($pull) { value, state, _ in
                state = value.translation.width * direction.dx + value.translation.height * direction.dy
            }
            .updating($active) { _, state, _ in
                state = true
            }
            .onChanged { value in
                let offset = Double(value.translation.width * direction.dx + value.translation.height * direction.dy)
                if var drag = model.maneuverDrag, drag.handle == handle {
                    drag.offset = offset
                    model.maneuverDrag = drag
                } else {
                    model.maneuverDrag = ManeuverDrag(handle: handle, offset: offset)
                }
            }
            .onEnded { _ in
                if model.maneuverDrag?.handle == handle { model.maneuverDrag = nil }
            }
    }

    static func color(_ handle: ManeuverHandle) -> Color {
        switch handle.axis {
        case .prograde: NavballPalette.prograde
        case .normal: NavballPalette.normal
        case .radial: NavballPalette.radial
        }
    }
}

extension ManeuverHandleKnob {
    /// Короткая подпись под ручкой.
    static func caption(_ handle: ManeuverHandle) -> String {
        switch handle {
        case .prograde: "разгон"
        case .retrograde: "тормоз"
        case .normal: "норм."
        case .antiNormal: "анти"
        case .radialOut: "наруж."
        case .radialIn: "внутр."
        }
    }
}

/// Над пальцем при перетаскивании: «Разгон +120 м/с». Единственная часть ручки, читающая кадр, и только пока ручка в руке.
struct HandleValueBubble: View {
    let model: FlightHUDModel
    let handle: ManeuverHandle

    var body: some View {
        let value = model.maneuver.map { handle.axis.value($0.node) } ?? 0
        Text(Self.title(handle.axis, value: value) + " " + ManeuverPanel.signed(value) + " м/с")
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .hudBackground(Color.black.opacity(0.75), corner: 8)
    }

    static func title(_ axis: ManeuverAxis, value: Double) -> String {
        switch axis {
        case .prograde: value < 0 ? "Торможение" : "Разгон"
        case .normal: value < 0 ? "Антинормаль" : "Нормаль"
        case .radial: value < 0 ? "Внутрь" : "Наружу"
        }
    }
}
