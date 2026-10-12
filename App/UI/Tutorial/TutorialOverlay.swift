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
    func tutorialAnchor(_ element: LessonElement) -> some View {
        anchorPreference(key: TutorialAnchorKey.self, value: .bounds) { [element: $0] }
    }
}

// MARK: - Раскладка

/// Расчёты положения пузыря подсказки: чистая геометрия, проверяется тестами.
enum TutorialLayout {
    static let margin: CGFloat = 8
    static let gap: CGFloat = 10

    /// Левый верхний угол пузыря рядом с вырезом: справа, слева, снизу, сверху — первое место, где пузырь целиком
    /// на экране и не заходит на вырез. Без выреза — по центру.
    static func bubbleOrigin(hole: CGRect?, bubble: CGSize, screen: CGSize) -> CGPoint {
        let bounds = CGRect(origin: .zero, size: screen).insetBy(dx: margin, dy: margin)
        guard let hole else {
            return CGPoint(x: (screen.width - bubble.width) / 2, y: (screen.height - bubble.height) / 2)
        }
        let candidates = [
            CGPoint(x: hole.maxX + gap, y: hole.midY - bubble.height / 2),
            CGPoint(x: hole.minX - gap - bubble.width, y: hole.midY - bubble.height / 2),
            CGPoint(x: hole.midX - bubble.width / 2, y: hole.maxY + gap),
            CGPoint(x: hole.midX - bubble.width / 2, y: hole.minY - gap - bubble.height),
        ]
        var fallback: CGPoint?
        for candidate in candidates {
            let origin = clamp(candidate, bubble: bubble, bounds: bounds)
            fallback = fallback ?? origin
            let rect = CGRect(origin: origin, size: bubble)
            if !rect.intersects(hole), bounds.contains(rect) { return origin }
        }
        return fallback ?? .zero
    }

    private static func clamp(_ p: CGPoint, bubble: CGSize, bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), max(bounds.minX, bounds.maxX - bubble.width)),
                y: min(max(p.y, bounds.minY), max(bounds.minY, bounds.maxY - bubble.height)))
    }
}

// MARK: - Оверлей

/// Оверлей урока поверх HUD: затемнение с вырезом, пузырь, живая плашка. Рамки элементов приходят из HUD.
struct TutorialOverlay: View {
    let controller: TutorialController
    let model: FlightHUDModel
    let anchors: [LessonElement: Anchor<CGRect>]
    let onHangar: () -> Void

    var body: some View {
        if controller.isActive {
            GeometryReader { geo in
                TutorialLayers(controller: controller, model: model, hole: hole(geo), size: geo.size, onHangar: onHangar)
            }
            .ignoresSafeArea()
        }
    }

    private func hole(_ geo: GeometryProxy) -> CGRect? {
        guard let target = controller.display.target, let anchor = anchors[target] else { return nil }
        return geo[anchor].insetBy(dx: -6, dy: -6)
    }
}

private struct TutorialLayers: View {
    let controller: TutorialController
    let model: FlightHUDModel
    let hole: CGRect?
    let size: CGSize
    let onHangar: () -> Void

    var body: some View {
        let display = controller.display
        let dims = display.phase == .holding || display.phase == .ready
        let waitsForAction = display.phase == .holding && display.bubble?.button == nil
        ZStack(alignment: .topLeading) {
            if dims {
                TutorialDim(hole: hole, passThrough: waitsForAction)
            }
            if let bubble = display.bubble {
                TutorialBubble(bubble: bubble, hole: hole, screen: size,
                               isFinish: display.step == .finish,
                               onButton: { bubbleButton(display) },
                               onExit: { model.exitTutorial() })
            }
            if waitsForAction {
                Text("⏸ пауза — ждём действие")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HUDPalette.advice)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
                    .allowsHitTesting(false)
            }
            if display.phase == .running || display.phase == .waiting || display.phase == .failed {
                TutorialPlateView(plate: controller.plate, failure: display.failure, canRepeat: display.canRepeat,
                                  onRepeat: { model.tutorialRepeat() }, onExit: { model.exitTutorial() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, TutorialPlateView.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bubbleButton(_ display: TutorialDisplay) {
        if display.step == .finish {
            onHangar()
        } else {
            model.tutorialAcknowledge()
        }
    }
}

// MARK: - Затемнение

/// Весь экран с прямоугольным вырезом (even-odd): через вырез видно и нажимается HUD.
struct CutoutShape: Shape {
    var hole: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        if let hole {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: Self.corner(hole), height: Self.corner(hole)),
                                style: .continuous)
        }
        return path
    }

    static func corner(_ hole: CGRect) -> CGFloat { min(24, min(hole.width, hole.height) / 2) }
}

private struct TutorialDim: View {
    let hole: CGRect?
    /// Касания внутри выреза проходят к контролу (шаг ждёт действия); иначе блокируется весь экран.
    let passThrough: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            CutoutShape(hole: hole)
                .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                .contentShape(CutoutShape(hole: passThrough ? hole : nil), eoFill: true)
                .onTapGesture {}
            if let hole {
                RoundedRectangle(cornerRadius: CutoutShape.corner(hole), style: .continuous)
                    .strokeBorder(bright ? Color.white : HUDPalette.advice, lineWidth: 2.5)
                    .frame(width: hole.width, height: hole.height)
                    .offset(x: hole.minX, y: hole.minY)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { bright = true }
        }
    }
}

// MARK: - Пузырь

private struct TutorialBubble: View {
    let bubble: LessonBubble
    let hole: CGRect?
    let screen: CGSize
    let isFinish: Bool
    let onButton: () -> Void
    let onExit: () -> Void

    @State private var measured = CGSize(width: 260, height: 100)

    private static let ink = Color(red: 0x18 / 255, green: 0x13 / 255, blue: 0x0A / 255)
    private static let paper = Color(red: 0xF6 / 255, green: 0xF1 / 255, blue: 0xE4 / 255)

    var body: some View {
        let origin = TutorialLayout.bubbleOrigin(hole: hole, bubble: measured, screen: screen)
        VStack(alignment: .leading, spacing: 3) {
            Text(bubble.title)
                .font(.system(size: 13, weight: .heavy))
            Text(bubble.text)
                .font(.system(size: 12, weight: .regular))
                .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .foregroundStyle(Self.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 260, alignment: .leading)
        .background(Self.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { measured = $0 })
        .offset(x: origin.x, y: origin.y)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
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
            Button(action: onExit) {
                Text(isFinish ? "Остаться на орбите" : "Выйти из урока")
                    .font(.system(size: isFinish ? 12 : 10, weight: isFinish ? .bold : .medium))
                    .underline(!isFinish)
                    .foregroundStyle(isFinish ? Self.ink : Self.ink.opacity(0.6))
                    .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }
}

// MARK: - Живая плашка

private struct TutorialPlateView: View {
    let plate: LivePlate?
    let failure: String?
    let canRepeat: Bool
    let onRepeat: () -> Void
    let onExit: () -> Void

    /// Под высотомером и строкой состояния; верхнюю панель и кнопки в углах не перекрывает.
    static let top: CGFloat = 82

    var body: some View {
        let failed = failure != nil
        HStack(spacing: 8) {
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
                    .font(.system(size: 10, weight: .bold))
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
        .frame(maxWidth: 420)
        .background(Color(red: 10 / 255, green: 14 / 255, blue: 20 / 255).opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(failed ? Self.alert : HUDPalette.advice, lineWidth: 1))
    }

    private static let alert = Color(red: 0xF0 / 255, green: 0x6A / 255, blue: 0x4C / 255)
}
