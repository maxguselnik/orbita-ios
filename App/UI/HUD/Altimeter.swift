import OrbitPhysics
import SwiftUI

/// Высота «одометром»: шесть цифр и единица. Выше 999 999 м показывается в километрах.
struct AltimeterReading: Equatable {
    let digits: [String]
    let unit: String

    init(altitude: Double) {
        let meters = altitude.isFinite ? max(0, altitude) : 0
        let inKilometers = meters > 999_999
        let value = inKilometers ? meters / 1_000 : meters
        let whole = min(Int(value.rounded(.down)), 999_999)
        digits = String(format: "%06d", whole).map { String($0) }
        unit = inKilometers ? "км" : "м"
    }
}

/// Верхняя центральная панель (Б4): высотомер-одометр и под ним шкала атмосферы (Терра). Ап/Пе — на карте.
struct AltimeterPanel: View {
    let model: FlightHUDModel

    var body: some View {
        let t = model.telemetry
        VStack(spacing: 4) {
            OdometerRow(reading: AltimeterReading(altitude: t.altitude))
            if t.body == .terra {
                AtmosphereScale(altitude: t.altitude)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 5)
        .padding(.horizontal, 8)
        .background(shape.fill(LinearGradient(colors: [Color(red: 0.208, green: 0.243, blue: 0.322),
                                                       Color(red: 0.09, green: 0.11, blue: 0.153)],
                                              startPoint: .top, endPoint: .bottom)))
        .overlay(shape.strokeBorder(HUDPalette.strokeBright, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Высота \(HUDFormat.distance(t.altitude))")
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10,
                               bottomTrailingRadius: 10, topTrailingRadius: 0, style: .continuous)
    }
}

/// Шесть цифр высоты в светлых плашках и единица в красной.
struct OdometerRow: View {
    let reading: AltimeterReading

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(reading.digits.enumerated()), id: \.offset) { _, digit in
                Text(digit)
                    .font(.system(size: 12, weight: .heavy).monospacedDigit())
                    .foregroundStyle(Color(red: 0.07, green: 0.07, blue: 0.07))
                    .frame(width: 11, height: 16)
                    .background(Color(red: 0.95, green: 0.95, blue: 0.925),
                                in: RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
            Text(reading.unit)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 14, height: 16)
                .background(Color(red: 0.85, green: 0.28, blue: 0.23),
                            in: RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .lineLimit(1)
    }
}

/// Шкала атмосферы Терры: справа поверхность, слева космос (70 км); жёлтый маркер — текущая высота.
struct AtmosphereScale: View {
    let altitude: Double

    static let width: CGFloat = 100

    /// Положение маркера 0…1 слева направо: 0 — граница атмосферы и выше, 1 — уровень моря.
    static func markerPosition(altitude: Double) -> Double {
        guard altitude.isFinite else { return 1 }
        return 1 - min(max(altitude / AscentGuide.spaceAltitude, 0), 1)
    }

    var body: some View {
        let position = CGFloat(Self.markerPosition(altitude: altitude))
        LinearGradient(stops: [
            .init(color: Color(red: 0.016, green: 0.024, blue: 0.043), location: 0),
            .init(color: Color(red: 0.07, green: 0.133, blue: 0.247), location: 0.4),
            .init(color: Color(red: 0.31, green: 0.525, blue: 0.776), location: 0.75),
            .init(color: Color(red: 0.663, green: 0.796, blue: 0.937), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
            .frame(width: Self.width, height: 4)
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(HUDPalette.advice)
                    .frame(width: 2, height: 8)
                    .offset(x: Self.width * position - 1)
            }
            .accessibilityHidden(true)
    }
}
