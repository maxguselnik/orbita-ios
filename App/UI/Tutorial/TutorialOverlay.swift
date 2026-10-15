import SwiftUI

// MARK: - Рамки элементов HUD

/// Рамки подсвечиваемых элементов: HUD-вью отдают их через `tutorialAnchor`, оверлей урока читает.
struct TutorialAnchorKey: PreferenceKey {
    static var defaultValue: [LessonElement: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [LessonElement: Anchor<CGRect>], nextValue: () -> [LessonElement: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Отдаёт рамку вью урока под ключом элемента (к раскладке и касаниям отношения не имеет).
    /// Дополняет рамки вложенных вью, а не заменяет их: иначе внешний ключ (`.corner`) стирает внутренний (`.mapButton`).
    func tutorialAnchor(_ element: LessonElement) -> some View {
        transformAnchorPreference(key: TutorialAnchorKey.self, value: .bounds) { $0[element] = $1 }
    }

    /// То же, но элемент может отсутствовать (nil — рамка не отдаётся, рамки вложенных вью остаются).
    func tutorialAnchor(optional element: LessonElement?) -> some View {
        transformAnchorPreference(key: TutorialAnchorKey.self, value: .bounds) { value, anchor in
            if let element { value[element] = anchor }
        }
    }
}

// MARK: - Раскладка

/// Расчёты положения плашки подсказки и стрелки: чистая геометрия, проверяется тестами.
enum TutorialLayout {
    static let margin: CGFloat = 8
    /// Зазор между кончиком стрелки и рамкой цели.
    static let arrowGap: CGFloat = 6
    /// Стрелка короче этой длины не рисуется (цель вплотную к плашке).
    static let minArrow: CGFloat = 14
    /// Ширина плашки.
    static let plaqueWidth: CGFloat = 380

    /// Рамка стопки «плашка + живая строка»: по центру сверху (`top` — отступ от верха) или, если закрывает цель, —
    /// по центру снизу (`bottom` — отступ от низа). Ни там ни там — сверху.
    static func stackFrame(size: CGSize, screen: CGSize, holes: [CGRect], top: CGFloat, bottom: CGFloat) -> CGRect {
        let x = (screen.width - size.width) / 2
        let upper = CGRect(x: x, y: top, width: size.width, height: size.height)
        let lower = CGRect(x: x, y: max(top, screen.height - bottom - size.height), width: size.width,
                           height: size.height)
        if !holes.contains(where: { $0.intersects(upper) }) { return upper }
        if !holes.contains(where: { $0.intersects(lower) }) { return lower }
        return upper
    }

    /// Стрелка от плашки к цели: начало — на краю плашки, конец — у рамки цели с зазором `arrowGap`.
    /// nil — плашка и цель пересекаются или стрелка короче `minArrow`.
    static func arrow(from source: CGRect, to hole: CGRect) -> (start: CGPoint, end: CGPoint)? {
        guard !source.intersects(hole) else { return nil }
        let start = edgePoint(of: source, towards: CGPoint(x: hole.midX, y: hole.midY))
        let edge = edgePoint(of: hole, towards: start)
        let dx = start.x - edge.x
        let dy = start.y - edge.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length - arrowGap >= minArrow else { return nil }
        let end = CGPoint(x: edge.x + dx / length * arrowGap, y: edge.y + dy / length * arrowGap)
        return (start, end)
    }

    /// Точка на границе прямоугольника в сторону точки `p` (луч из центра).
    static func edgePoint(of rect: CGRect, towards p: CGPoint) -> CGPoint {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let dx = p.x - c.x
        let dy = p.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let tx = dx == 0 ? CGFloat.infinity : rect.width / 2 / abs(dx)
        let ty = dy == 0 ? CGFloat.infinity : rect.height / 2 / abs(dy)
        let t = min(tx, ty)
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }
}

// MARK: - Оверлей

/// Оверлей урока поверх HUD и карты: затемнение с вырезами, пульсирующая рамка цели, стрелка, плашка шага
/// и живая строка. Рамки элементов приходят из HUD.
struct TutorialOverlay: View {
    let controller: TutorialController
    let model: FlightHUDModel
    let anchors: [LessonElement: Anchor<CGRect>]
    let onHangar: () -> Void

    var body: some View {
        if controller.isActive {
            GeometryReader { geo in
                TutorialLayers(controller: controller, model: model, holes: holes(geo), size: geo.size,
                               onHangar: onHangar)
            }
            .ignoresSafeArea()
        }
    }

    /// Вырезы вокруг целей шага (главная первой); элемент не нарисован — выреза нет.
    private func holes(_ geo: GeometryProxy) -> [CGRect] {
        controller.display.targets.compactMap { target in
            guard let anchor = anchors[target] else { return nil }
            let rect = geo[anchor]
            guard rect.width > 1, rect.height > 1 else { return nil }
            return rect.insetBy(dx: -6, dy: -6)
        }
    }
}

private struct TutorialLayers: View {
    let controller: TutorialController
    let model: FlightHUDModel
    /// Вырезы целей; первый — главная цель, к ней ведёт стрелка.
    let holes: [CGRect]
    let size: CGSize
    let onHangar: () -> Void

    @State private var stackSize = CGSize(width: TutorialLayout.plaqueWidth, height: 90)

    var body: some View {
        let display = controller.display
        let scene = display.scene
        let mapOpen = model.map.isOpen
        let hasStack = scene.bubble != nil || scene.plateBar
        let frame = TutorialLayout.stackFrame(size: stackSize, screen: size, holes: holes,
                                              top: mapOpen ? 60 : TutorialStackView.flightTop,
                                              bottom: mapOpen ? TutorialStackView.mapBottom : TutorialStackView.flightBottom)
        ZStack(alignment: .topLeading) {
            if scene.dims {
                TutorialDim(holes: holes, passThrough: scene.passThrough)
            }
            if !holes.isEmpty {
                TutorialRing(holes: holes)
                if hasStack, let main = holes.first, let arrow = TutorialLayout.arrow(from: frame, to: main) {
                    TutorialArrow(start: arrow.start, end: arrow.end)
                }
            }
            if scene.pausedTag {
                TutorialPausedTag()
            }
            if hasStack {
                TutorialStackView(controller: controller, model: model, onHangar: onHangar)
                    .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { stackSize = $0 })
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// «⏸ пауза — ждём действие» в правом нижнем углу.
private struct TutorialPausedTag: View {
    var body: some View {
        Text("⏸ пауза — ждём действие")
            .font(.system(size: HUDFont.caption, weight: .semibold))
            .foregroundStyle(HUDPalette.advice)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(8)
            .allowsHitTesting(false)
    }
}

/// Плашка шага и под ней живая строка (числа кадра, ошибка).
private struct TutorialStackView: View {
    let controller: TutorialController
    let model: FlightHUDModel
    let onHangar: () -> Void

    /// Под высотомером, строкой «Ап» и строкой состояния; верхнюю панель и кнопки в углах не перекрывает.
    static let flightTop: CGFloat = 88
    static let flightBottom: CGFloat = 140
    /// На карте: над переключателем фокуса.
    static let mapBottom: CGFloat = HUDStyle.minTouch + 20

    var body: some View {
        let display = controller.display
        VStack(spacing: 4) {
            if let bubble = display.scene.bubble {
                TutorialPlaque(bubble: bubble, progress: display.progress,
                               onButton: { bubbleButton(bubble) }, onExit: { model.exitTutorial() })
                    .id(display.stepIndex)
            }
            if display.scene.plateBar {
                TutorialPlateView(plate: controller.plate, failure: display.failure, canRepeat: display.canRepeat,
                                  progress: display.bubble == nil ? display.progress : nil,
                                  onRepeat: { model.tutorialRepeat() }, onExit: { model.exitTutorial() })
            }
        }
        .frame(width: TutorialLayout.plaqueWidth)
    }

    private func bubbleButton(_ bubble: LessonBubble) {
        switch bubble.role {
        case .hangar: onHangar()
        case .skip: model.tutorialSkip()
        case .next: model.tutorialAcknowledge()
        }
    }
}

// MARK: - Затемнение

/// Весь экран с прямоугольными вырезами (even-odd): через вырез видно и нажимается HUD.
struct CutoutShape: Shape {
    var holes: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        for hole in holes {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: Self.corner(hole), height: Self.corner(hole)),
                                style: .continuous)
        }
        return path
    }

    static func corner(_ hole: CGRect) -> CGFloat { min(24, min(hole.width, hole.height) / 2) }
}

private struct TutorialDim: View {
    let holes: [CGRect]
    /// Касания внутри вырезов проходят к контролу (шаг ждёт действия); иначе блокируется весь экран.
    let passThrough: Bool

    var body: some View {
        CutoutShape(holes: holes)
            .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
            .contentShape(CutoutShape(holes: passThrough ? holes : []), eoFill: true)
            .onTapGesture {}
    }
}

/// Толстая пульсирующая рамка вокруг целей: касания проходят насквозь.
private struct TutorialRing: View {
    let holes: [CGRect]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    static let lineWidth: CGFloat = 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                RoundedRectangle(cornerRadius: CutoutShape.corner(hole), style: .continuous)
                    .strokeBorder(pulse ? Color.white : HUDPalette.advice, lineWidth: Self.lineWidth)
                    .frame(width: hole.width, height: hole.height)
                    .shadow(color: HUDPalette.advice.opacity(pulse ? 0.9 : 0.3), radius: pulse ? 8 : 2)
                    .scaleEffect(pulse ? 1.04 : 1)
                    .offset(x: hole.minX, y: hole.minY)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Пунктирная стрелка с наконечником от плашки к цели.
struct TutorialArrowShape: Shape {
    var start: CGPoint
    var end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    /// Наконечник: треугольник у конца, направленный по линии.
    func head(size: CGFloat = 12) -> Path {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let ux = dx / length
        let uy = dy / length
        let back = CGPoint(x: end.x - ux * size, y: end.y - uy * size)
        var path = Path()
        path.move(to: end)
        path.addLine(to: CGPoint(x: back.x - uy * size * 0.55, y: back.y + ux * size * 0.55))
        path.addLine(to: CGPoint(x: back.x + uy * size * 0.55, y: back.y - ux * size * 0.55))
        path.closeSubpath()
        return path
    }
}

private struct TutorialArrow: View {
    let start: CGPoint
    let end: CGPoint

    var body: some View {
        let shape = TutorialArrowShape(start: start, end: end)
        ZStack {
            shape.stroke(HUDPalette.advice, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 6]))
            shape.head().fill(HUDPalette.advice)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Плашка шага

/// Плашка сверху по центру: «Шаг N из M» · действие · «Зачем?» · кнопка шага · «Выйти из урока».
private struct TutorialPlaque: View {
    let bubble: LessonBubble
    let progress: LessonProgress?
    let onButton: () -> Void
    let onExit: () -> Void

    @State private var showWhy = false

    private static let ink = Color(red: 0x18 / 255, green: 0x13 / 255, blue: 0x0A / 255)
    private static let paper = Color(red: 0xF6 / 255, green: 0xF1 / 255, blue: 0xE4 / 255)
    private static let accent = Color(red: 0x9A / 255, green: 0x5A / 255, blue: 0x00 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let progress {
                    Text(progress.text.uppercased())
                        .font(.system(size: HUDFont.caption, weight: .heavy))
                        .foregroundStyle(Self.accent)
                }
                Text(bubble.title)
                    .font(.system(size: 12, weight: .heavy))
            }
            .lineLimit(1)
            Text(bubble.text)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if showWhy, let why = bubble.why {
                Text(why)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Self.ink.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .foregroundStyle(Self.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(HUDPalette.advice, lineWidth: 2))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    private var isFinish: Bool { bubble.exitTitle != nil }

    private var buttons: some View {
        HStack(spacing: 12) {
            if let title = bubble.button {
                Button(action: onButton) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Self.paper)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(Self.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if bubble.why != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showWhy.toggle() }
                } label: {
                    Text(showWhy ? "Скрыть" : "Зачем?")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Self.accent)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showWhy ? "Скрыть пояснение" : "Зачем этот шаг")
            }
            Spacer(minLength: 0)
            Button(action: onExit) {
                Text(bubble.exitTitle ?? "Выйти из урока")
                    .font(.system(size: isFinish ? 12 : 10, weight: isFinish ? .bold : .medium))
                    .underline(!isFinish)
                    .foregroundStyle(isFinish ? Self.ink : Self.ink.opacity(0.6))
                    .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Живая плашка

private struct TutorialPlateView: View {
    let plate: LivePlate?
    let failure: String?
    let canRepeat: Bool
    /// «Шаг N из M» перед числами, пока плашки шага нет.
    var progress: LessonProgress?
    let onRepeat: () -> Void
    let onExit: () -> Void

    var body: some View {
        let failed = failure != nil
        HStack(spacing: 8) {
            if let progress, failure == nil {
                Text("\(progress.step)/\(progress.total)")
                    .font(.system(size: HUDFont.caption, weight: .heavy))
                    .foregroundStyle(HUDPalette.advice)
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(HUDPalette.text)
                Button(action: onRepeat) {
                    Text(canRepeat ? "Повторить шаг" : "Продолжить")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Self.alert)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
            } else if let plate {
                HStack(spacing: 0) {
                    Text(plate.head).foregroundStyle(HUDPalette.text)
                    Text(plate.value)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(HUDPalette.advice)
                    Text(plate.tail).foregroundStyle(HUDPalette.text)
                }
            }
            Button(action: onExit) {
                Image(systemName: "xmark")
                    .font(.system(size: HUDFont.caption, weight: .bold))
                    .foregroundStyle(HUDPalette.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Выйти из урока")
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .background(Color(red: 10 / 255, green: 14 / 255, blue: 20 / 255).opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(failed ? Self.alert : HUDPalette.advice, lineWidth: 1))
    }

    private static let alert = Color(red: 0xF0 / 255, green: 0x6A / 255, blue: 0x4C / 255)
}
