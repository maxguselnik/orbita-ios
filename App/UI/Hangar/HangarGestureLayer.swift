import SwiftUI

/// Касания вида корабля: палец на детали — перетаскивание, на кольце/стрелке гизмо — поворот или сдвиг,
/// на пустом месте — камера (как в полёте: палец вращает, щипок — зум, двойной тап — сброс). Тап без движения —
/// выбор детали или точки крепления. Координаты — в системе слоя (она же системa вида 3D).
struct HangarGestureLayer: View {
    let model: HangarModel

    /// Радиан на точку смещения пальца.
    private static let radiansPerPoint: Float = 0.007
    /// Сдвиг, после которого касание считается жестом, а не тапом, pt.
    private static let tapSlop: CGFloat = 8

    @State private var tracker = Tracker()

    final class Tracker {
        var touch: HangarModel.Touch?
        var dragging = false
        var lastTranslation: CGSize?
        var lastMagnification: CGFloat?
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(drag)
            .simultaneousGesture(zoom)
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { model.doubleTap(at: $0.location) }
            )
            .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let t = tracker
                if t.touch == nil {
                    t.touch = model.classify(value.startLocation)
                    t.dragging = false
                    t.lastTranslation = .zero
                }
                let moved = hypot(value.translation.width, value.translation.height)
                switch t.touch ?? .camera {
                case .part(let id):
                    if !t.dragging, moved >= Self.tapSlop {
                        t.dragging = true
                        model.beginDrag(.vessel(id), at: value.location)
                    }
                    if t.dragging { model.moveDrag(to: value.location) }
                case .gizmo(let axis):
                    if !t.dragging, moved >= 3 {
                        t.dragging = true
                        model.beginGizmo(axis: axis, at: value.startLocation)
                    }
                    if t.dragging { model.moveGizmo(to: value.location) }
                case .camera:
                    if moved >= 3 { t.dragging = true }
                    cameraStep(value.translation)
                }
            }
            .onEnded { value in
                let t = tracker
                defer {
                    t.touch = nil
                    t.dragging = false
                    t.lastTranslation = nil
                }
                switch t.touch ?? .camera {
                case .part:
                    if t.dragging { model.endDrag() } else { model.tap(at: value.location) }
                case .gizmo:
                    if t.dragging { model.endGizmo() }
                case .camera:
                    let moved = hypot(value.translation.width, value.translation.height)
                    if moved < Self.tapSlop, t.lastMagnification == nil { model.tap(at: value.location) }
                }
            }
    }

    private func cameraStep(_ translation: CGSize) {
        let t = tracker
        defer { t.lastTranslation = translation }
        guard t.lastMagnification == nil, let last = t.lastTranslation else { return }
        let dx = Float(translation.width - last.width)
        let dy = Float(translation.height - last.height)
        guard t.dragging else { return }
        model.scene.apply(CameraInput(orbitDelta: SIMD2(-dx, dy) * Self.radiansPerPoint))
    }

    private var zoom: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                guard !model.isDragging else { return }
                let m = value.magnification
                if let last = tracker.lastMagnification, m > 0 {
                    let factor = Float(last / m)
                    if factor.isFinite, factor > 0 { model.scene.apply(CameraInput(zoomFactor: factor)) }
                }
                tracker.lastMagnification = m
            }
            .onEnded { _ in
                tracker.lastMagnification = nil
                tracker.lastTranslation = nil
            }
    }
}
