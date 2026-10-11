import OrbitPhysics
import SwiftUI

/// 2D-заглушка навбола (3D — этап 2): горизонт по тангажу и крену, маркеры из `telemetry.navball`.
/// Вид вдоль носа (+Y корабля): вправо — +X, вверх — +Z. Показываем переднюю полусферу.
struct NavballStub: View {
    let telemetry: FlightTelemetry

    static let diameter: CGFloat = 108

    var body: some View {
        let d = Self.diameter
        let r = d / 2
        VStack(spacing: 3) {
            Text("КУРС \(HUDFormat.heading(telemetry.heading))")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .hudBackground(corner: 6)

            ZStack {
                horizon(d: d)
                    .offset(y: r * CGFloat(sin(telemetry.pitch)))
                    .rotationEffect(.radians(telemetry.roll))

                ForEach(markers, id: \.mode) { marker in
                    SASIcon(mode: marker.mode)
                        .foregroundStyle(marker.color)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black, radius: 1)
                        .offset(x: r * 0.92 * CGFloat(marker.vector.x), y: -r * 0.92 * CGFloat(marker.vector.z))
                }

                // Неподвижный значок носа корабля.
                Path { p in
                    p.move(to: CGPoint(x: r - 16, y: r))
                    p.addLine(to: CGPoint(x: r - 7, y: r))
                    p.addLine(to: CGPoint(x: r - 3, y: r + 5))
                    p.addLine(to: CGPoint(x: r, y: r))
                    p.addLine(to: CGPoint(x: r + 3, y: r + 5))
                    p.addLine(to: CGPoint(x: r + 7, y: r))
                    p.addLine(to: CGPoint(x: r + 16, y: r))
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: d, height: d)
            }
            .frame(width: d, height: d)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
            .background(Circle().fill(.black).padding(-4).opacity(0.5))
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Навбол: тангаж \(Int((telemetry.pitch * 180 / .pi).rounded()))°, курс \(HUDFormat.heading(telemetry.heading))")
    }

    private func horizon(d: CGFloat) -> some View {
        let sky = Color(red: 0.22, green: 0.45, blue: 0.78)
        let ground = Color(red: 0.55, green: 0.36, blue: 0.2)
        return VStack(spacing: 0) {
            sky.frame(height: d * 2)
            ground.frame(height: d * 2)
        }
        .frame(width: d * 3, height: d * 4)
        .overlay {
            // Горизонт и линии ±30°, ±60° тангажа.
            ZStack {
                Rectangle().fill(.white).frame(width: d * 3, height: 2)
                ForEach([-60.0, -30.0, 30.0, 60.0], id: \.self) { degrees in
                    Rectangle()
                        .fill(.white.opacity(0.5))
                        .frame(width: d * 0.3, height: 1)
                        .offset(y: -d / 2 * CGFloat(sin(degrees * .pi / 180)))
                }
            }
        }
    }

    private struct Marker {
        let mode: SASMode
        let vector: Vec3
        let color: Color
    }

    private var markers: [Marker] {
        let n = telemetry.navball
        let progradeColor = Color(red: 0.85, green: 0.95, blue: 0.2)
        let normalColor = Color(red: 0.85, green: 0.45, blue: 1.0)
        let radialColor = Color(red: 0.35, green: 0.85, blue: 1.0)
        let speedVector = telemetry.orbit == nil || telemetry.altitude < 36_000 ? (n.surfacePrograde ?? n.prograde) : n.prograde
        let candidates: [(SASMode, Vec3?, Color)] = [
            (.prograde, speedVector, progradeColor),
            (.retrograde, speedVector.map { -$0 }, progradeColor),
            (.normal, n.normal, normalColor),
            (.antiNormal, n.normal.map { -$0 }, normalColor),
            (.radialOut, n.radialOut, radialColor),
            (.radialIn, n.radialOut.map { -$0 }, radialColor),
        ]
        return candidates.compactMap { mode, vector, color in
            guard let vector, vector.y > 0 else { return nil }
            return Marker(mode: mode, vector: vector, color: color)
        }
    }
}
