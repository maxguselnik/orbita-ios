import OrbitPhysics
import SwiftUI

/// Рисунок поверх 3D: маркеры ЦМ/ЦТ/ЦД, точки крепления выбранной детали и цели при перетаскивании.
/// Точки проецируются сценой каждый кадр (камера вращается), поэтому слой обновляется по таймеру.
struct HangarMarkerOverlay: View {
    let model: HangarModel

    private static let com = Color(red: 1.0, green: 0.85, blue: 0.2)
    private static let cot = Color(red: 1.0, green: 0.5, blue: 0.2)
    private static let cop = Color(red: 0.35, green: 0.75, blue: 1.0)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { context, size in
                draw(&context, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let scene = model.scene
        func screen(_ v: Vec3) -> CGPoint? { scene.project(v, viewSize: size) }

        if model.isDragging {
            for position in model.dragCandidatePositions {
                if let p = screen(position) { dot(&context, p, radius: 3.5, color: .white.opacity(0.7)) }
            }
            if let snap = model.dragSnapPosition, let p = screen(snap) {
                let valid = model.dragInfo?.verdict != .invalid
                ring(&context, p, radius: 12, color: valid ? .green : .red)
            }
        } else if model.armed != nil {
            for target in model.armedTargets {
                if let p = screen(target.position) {
                    dot(&context, p, radius: 5, color: Color.green.opacity(0.85))
                    ring(&context, p, radius: 9, color: Color.green.opacity(0.6))
                }
            }
        }

        guard let markers = model.report.markers else { return }
        if model.showCOP, let cop = markers.centerOfPressure, let p = screen(cop) {
            marker(&context, p, "ЦД", color: Self.cop, shape: .diamond)
        }
        if model.showCOT, let cot = markers.centerOfThrust, let p = screen(cot) {
            marker(&context, p, "ЦТ", color: Self.cot, shape: .triangle)
        }
        if model.showCOM, let p = screen(markers.centerOfMass) {
            marker(&context, p, "ЦМ", color: Self.com, shape: .circle)
        }
    }

    private func dot(_ context: inout GraphicsContext, _ p: CGPoint, radius r: CGFloat, color: Color) {
        context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
    }

    private func ring(_ context: inout GraphicsContext, _ p: CGPoint, radius r: CGFloat, color: Color) {
        context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(color), lineWidth: 2)
    }

    private enum MarkerShape { case circle, triangle, diamond }

    private func marker(_ context: inout GraphicsContext, _ p: CGPoint, _ title: String, color: Color, shape: MarkerShape) {
        var path = Path()
        let r: CGFloat = 7
        switch shape {
        case .circle:
            path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        case .triangle:
            path.move(to: CGPoint(x: p.x, y: p.y - r))
            path.addLine(to: CGPoint(x: p.x + r, y: p.y + r))
            path.addLine(to: CGPoint(x: p.x - r, y: p.y + r))
            path.closeSubpath()
        case .diamond:
            path.move(to: CGPoint(x: p.x, y: p.y - r))
            path.addLine(to: CGPoint(x: p.x + r, y: p.y))
            path.addLine(to: CGPoint(x: p.x, y: p.y + r))
            path.addLine(to: CGPoint(x: p.x - r, y: p.y))
            path.closeSubpath()
        }
        context.fill(path, with: .color(Color.black.opacity(0.55)))
        context.stroke(path, with: .color(color), lineWidth: 2)
        let label = Text(title).font(.system(size: HUDFont.caption, weight: .heavy)).foregroundStyle(color)
        context.draw(label, at: CGPoint(x: p.x + r + 12, y: p.y), anchor: .center)
    }
}

/// Плашка отчёта инженера над нижней полосой: самое важное замечание, по тапу — весь список.
struct EngineerReportView: View {
    let issues: [DesignIssue]
    @State private var expanded = false

    private static let warning = Color(red: 1.0, green: 0.82, blue: 0.25)
    private static let danger = Color(red: 1.0, green: 0.4, blue: 0.35)

    var body: some View {
        if issues.isEmpty {
            Label("Инженер: замечаний нет", systemImage: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HUDPalette.green)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .hudBackground(Color.black.opacity(0.65), corner: 13)
                .allowsHitTesting(false)
        } else {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, issue in
                        row(issue, extra: index == 0 && !expanded ? issues.count - 1 : 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .hudBackground(Color.black.opacity(0.78), corner: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Отчёт инженера: \(issues.count)")
        }
    }

    private var sorted: [DesignIssue] { issues.filter(\.isBlocking) + issues.filter { !$0.isBlocking } }
    private var shown: [DesignIssue] { expanded ? Array(sorted.prefix(5)) : Array(sorted.prefix(1)) }

    private func row(_ issue: DesignIssue, extra: Int) -> some View {
        let color = issue.isBlocking ? Self.danger : Self.warning
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold))
            Text(issue.text + (extra > 0 ? " (+\(extra))" : ""))
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(color)
    }
}

/// Панель гизмо справа сверху: тангаж/рыскание/крен или сдвиг по осям, ± и «Сбросить».
struct GizmoPanel: View {
    let model: HangarModel

    var body: some View {
        if let node = model.selectedNode, model.tool == .rotate || model.tool == .offset {
            let rotate = model.tool == .rotate
            VStack(spacing: 2) {
                ForEach(rows(rotate: rotate), id: \.axis) { item in
                    HStack(spacing: 2) {
                        Text(item.title)
                            .font(.system(size: HUDFont.caption, weight: .bold))
                            .frame(width: 58, alignment: .leading)
                        nudgeButton("minus", axis: item.axis, direction: -1)
                        Text(valueText(node, axis: item.axis, rotate: rotate))
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .frame(width: 48)
                        nudgeButton("plus", axis: item.axis, direction: 1)
                    }
                }
                Button { model.resetGizmo() } label: {
                    Text("Сбросить").font(.system(size: 11.5, weight: .bold)).frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .foregroundStyle(.white)
            .padding(6)
            .frame(width: 196)
            .hudBackground(Color.black.opacity(0.78), corner: 10)
        }
    }

    private struct Item { var axis: Int; var title: String }

    private func rows(rotate: Bool) -> [Item] {
        rotate
            ? [Item(axis: 0, title: "Тангаж"), Item(axis: 2, title: "Рыскание"), Item(axis: 1, title: "Крен")]
            : [Item(axis: 0, title: "Вбок X"), Item(axis: 1, title: "Вверх Y"), Item(axis: 2, title: "Спина Z")]
    }

    private func valueText(_ node: DesignPart, axis: Int, rotate: Bool) -> String {
        rotate
            ? HangarGizmoMath.degreesText(HangarGizmoMath.component(node.rotation, axis))
            : HangarGizmoMath.metersText(HangarGizmoMath.component(node.offset, axis))
    }

    private func nudgeButton(_ icon: String, axis: Int, direction: Double) -> some View {
        Button { model.nudge(axis: axis, by: direction) } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).frame(width: 36, height: 30)
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityLabel(direction > 0 ? "Больше" : "Меньше")
    }
}

/// Сводка над видом: Δv, TWR, масса, число деталей и условия расчёта.
struct HangarStatStrip: View {
    let model: HangarModel

    var body: some View {
        let r = model.report
        HStack(spacing: 8) {
            metric("Δv", HUDFormat.speed(r.totalDV))
            metric("TWR", r.twr.map(HUDFormat.twr) ?? HUDFormat.dash, warn: (r.twr ?? 1) < 1)
            metric("", HangarFormat.mass(r.mass))
            metric("", "\(r.count)/\(VesselDesign.maxParts)", warn: r.count >= VesselDesign.maxParts)
            Menu {
                ForEach(HangarEnvironment.allCases) { env in
                    Button(env.title) { model.setEnvironment(env) }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(model.environment.title).font(.system(size: 11.5, weight: .bold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: HUDFont.caption, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("Условия расчёта Δv и TWR")
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .hudBackground(Color.black.opacity(0.7), corner: 10)
    }

    private func metric(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if !label.isEmpty {
                Text(label).font(.system(size: HUDFont.caption, weight: .bold)).foregroundStyle(HUDStyle.secondaryText)
            }
            Text(value)
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(warn ? HUDStyle.accent : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
