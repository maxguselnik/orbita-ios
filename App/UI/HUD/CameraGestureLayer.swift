import SwiftUI

/// Жесты камеры на свободной области экрана. Слой лежит под контролами HUD, поэтому
/// получает только касания мимо них; ползунок тяги и джойстик работают одновременно.
/// Один палец — вращение, щипок — зум, двойной тап — сброс. Жесты копятся в модели
/// и уходят в `feedback.camera` раз в кадр. На карте одиночный тап по орбите ставит узел манёвра.
struct CameraGestureLayer: View {
    let model: FlightHUDModel

    /// Радиан на точку смещения пальца (полный оборот ≈ ширина экрана).
    private static let radiansPerPoint: Float = 0.007

    /// Предыдущие значения жестов — для приращений; не наблюдаемые, перерисовки не вызывают.
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
                TapGesture(count: 2).onEnded { model.cameraReset() }
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in model.mapTap(at: value.location) }
            )
            .accessibilityHidden(true)
    }

    private var rotate: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let t = value.translation
                defer { tracker.lastTranslation = t }
                // Во время щипка не вращаем: два пальца двигаются вместе.
                guard tracker.lastMagnification == nil, let last = tracker.lastTranslation else { return }
                let dx = Float(t.width - last.width)
                let dy = Float(t.height - last.height)
                // Палец вправо — сцена поворачивается вслед за ним (азимут камеры уменьшается),
                // палец вниз — камера поднимается.
                model.cameraOrbit(SIMD2(-dx, dy) * Self.radiansPerPoint)
            }
            .onEnded { _ in tracker.lastTranslation = nil }
    }

    private var zoom: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let m = value.magnification
                if let last = tracker.lastMagnification, m > 0 {
                    // Пальцы врозь (m растёт) — камера ближе.
                    model.cameraZoom(Float(last / m))
                }
                tracker.lastMagnification = m
            }
            .onEnded { _ in
                tracker.lastMagnification = nil
                tracker.lastTranslation = nil
            }
    }
}
