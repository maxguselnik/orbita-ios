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

    var body: some View {
        let map = model.map
        let snapshot = map.snapshot
        let labels = MapLabel.layout(snapshot.markers, map: map)
        let node = NodeHandleLayout(snapshot: snapshot, map: map)
        let nodeCenter = node?.center
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
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
                ForEach(node.items) { item in
                    ManeuverHandleKnob(handle: item.handle, direction: item.direction, model: model)
                        .position(item.point)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Подписи отметок

/// Подпись отметки на экране: точка и текст над ней (после узла — под ней, жёлтым).
struct MapLabel {
    let point: CGPoint
    let text: String
    let textColor: Color
    let dotColor: Color
    let below: Bool

    @MainActor
    static func layout(_ markers: [MapMarker], map: MapModel) -> [MapLabel] {
        markers.compactMap { (marker: MapMarker) -> MapLabel? in
            guard let caption = Self.caption(marker), let point = map.project(marker.position, body: marker.body),
                  point.x.isFinite, point.y.isFinite else { return nil }
            let tint = Self.kindColor(marker.kind)
            if marker.afterManeuver {
                return MapLabel(point: point, text: caption, textColor: MapPalette.afterManeuver,
                                dotColor: tint.opacity(0.7), below: true)
            }
            return MapLabel(point: point, text: caption, textColor: Self.captionColor(marker.kind),
                            dotColor: tint, below: false)
        }
    }

    static func caption(_ marker: MapMarker) -> String? {
        switch marker.kind {
        case .apoapsis:
            return "Ап " + HUDFormat.distance(marker.altitude)
        case .periapsis:
            return "Пе " + HUDFormat.distance(marker.altitude)
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

        let resolved = context.resolve(
            Text(text)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(textColor)
        )
        let size = resolved.measure(in: CGSize(width: 240, height: 40))
        let gap: CGFloat = 8
        let center = CGPoint(x: point.x,
                             y: below ? point.y + gap + size.height / 2 : point.y - gap - size.height / 2)
        let plate = CGRect(x: center.x - size.width / 2 - 5, y: center.y - size.height / 2 - 2,
                           width: size.width + 10, height: size.height + 4)
        context.fill(Path(roundedRect: plate, cornerRadius: 5), with: .color(.black.opacity(0.55)))
        context.draw(resolved, at: center)
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
