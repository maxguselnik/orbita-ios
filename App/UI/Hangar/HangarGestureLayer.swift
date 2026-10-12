import SwiftUI

/// Жесты камеры превью корабля — те же, что в полёте (`CameraGestureLayer`):
/// палец — вращение, щипок — зум, двойной тап — сброс. Каждое приращение сразу уходит в `apply`.
struct HangarGestureLayer: View {
    let apply: (CameraInput) -> Void

    /// Радиан на точку смещения пальца.
    private static let radiansPerPoint: Float = 0.007

    @State private var tracker = Tracker()

    final class Tracker {
        var lastTranslation: CGSize?
        var lastMagnification: CGFloat?
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(rotate.simultaneously(with: zoom))
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { apply(CameraInput(reset: true)) }
            )
            .accessibilityHidden(true)
    }

    private var rotate: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let t = value.translation
                defer { tracker.lastTranslation = t }
                guard tracker.lastMagnification == nil, let last = tracker.lastTranslation else { return }
                let dx = Float(t.width - last.width)
                let dy = Float(t.height - last.height)
                apply(CameraInput(orbitDelta: SIMD2(-dx, dy) * Self.radiansPerPoint))
            }
            .onEnded { _ in tracker.lastTranslation = nil }
    }

    private var zoom: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let m = value.magnification
                if let last = tracker.lastMagnification, m > 0 {
                    let factor = Float(last / m)
                    if factor.isFinite, factor > 0 { apply(CameraInput(zoomFactor: factor)) }
                }
                tracker.lastMagnification = m
            }
            .onEnded { _ in
                tracker.lastMagnification = nil
                tracker.lastTranslation = nil
            }
    }
}
