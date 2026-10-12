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

/// Верхняя центральная панель: высотомер-одометр, шкала атмосферы (Терра) и строка «Ап · Пе · до Ап».
struct AltimeterPanel: View {
    let model: FlightHUDModel

    static let width: CGFloat = 236

    var body: some View {
        let t = model.telemetry
        VStack(spacing: 0) {
            OdometerRow(reading: AltimeterReading(altitude: t.altitude))
            if t.body == .terra {
                AtmosphereScale(altitude: t.altitude)
                    .padding(.top, 5)
            }
            ApsisRow(telemetry: t)
                .padding(.top, 4)
        }
        .padding(.top, 5)
        .padding(.bottom, 6)
        .padding(.horizontal, 8)
        .frame(width: Self.width)
        .background(shape.fill(LinearGradient(colors: [Color(red: 0.208, green: 0.243, blue: 0.322),
                                                       Color(red: 0.09, green: 0.11, blue: 0.153)],
                                              startPoint: .top, endPoint: .bottom)))
        .overlay(shape.strokeBorder(HUDPalette.strokeBright, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 7, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Высота \(HUDFormat.distance(t.altitude))")
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14,
                               bottomTrailingRadius: 14, topTrailingRadius: 0, style: .continuous)
    }
}

/// «ВЫСОТА 0 1 1 7 0 4 [м]»: цифры в светлых плашках, единица в красной.
struct OdometerRow: View {
    let reading: AltimeterReading

    var body: some View {
        HStack(spacing: 3) {
            Text("ВЫСОТА")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(HUDPalette.muted)
                .padding(.trailing, 4)
            ForEach(Array(reading.digits.enumerated()), id: \.offset) { _, digit in
                Text(digit)
                    .font(.system(size: 15, weight: .heavy).monospacedDigit())
                    .foregroundStyle(Color(red: 0.07, green: 0.07, blue: 0.07))
                    .frame(width: 15, height: 22)
                    .background(Color(red: 0.95, green: 0.95, blue: 0.925),
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            Text(reading.unit)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 18, height: 22)
                .background(Color(red: 0.85, green: 0.28, blue: 0.23),
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .lineLimit(1)
    }
}

/// Шкала атмосферы Терры: справа поверхность, слева космос (70 км); жёлтый маркер — текущая высота.
struct AtmosphereScale: View {
    let altitude: Double

    /// Положение маркера 0…1 слева направо: 0 — граница атмосферы и выше, 1 — уровень моря.
    static func markerPosition(altitude: Double) -> Double {
        guard altitude.isFinite else { return 1 }
        return 1 - min(max(altitude / AscentGuide.spaceAltitude, 0), 1)
    }

    var body: some View {
        let position = CGFloat(Self.markerPosition(altitude: altitude))
        HStack(spacing: 6) {
            Text("АТМ")
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(HUDPalette.muted)
            LinearGradient(stops: [
                .init(color: Color(red: 0.016, green: 0.024, blue: 0.043), location: 0),
                .init(color: Color(red: 0.07, green: 0.133, blue: 0.247), location: 0.4),
                .init(color: Color(red: 0.31, green: 0.525, blue: 0.776), location: 0.75),
                .init(color: Color(red: 0.663, green: 0.796, blue: 0.937), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
                .frame(height: 6)
                .clipShape(Capsule())
                .overlay {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(HUDPalette.advice)
                            .frame(width: 2, height: 12)
                            .offset(x: geo.size.width * position - 1, y: -3)
                    }
                }
        }
        .accessibilityHidden(true)
    }
}

/// «Ап 17.8 км · Пе падение · до Ап 38 с».
struct ApsisRow: View {
    let telemetry: FlightTelemetry

    var body: some View {
        let orbit = telemetry.orbit
        let toApo = Self.showsTimeToApoapsis(telemetry) ? HUDFormat.countdown(orbit?.timeToApoapsis) : HUDFormat.dash
        HStack(spacing: 4) {
            item("Ап", HUDFormat.distance(orbit?.apoapsisAltitude))
            Spacer(minLength: 0)
            item("Пе", HUDFormat.periapsis(orbit?.periapsisAltitude))
            Spacer(minLength: 0)
            item("до Ап", toApo)
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func item(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(HUDPalette.muted)
            Text(value).fontWeight(.bold).foregroundStyle(HUDPalette.text)
        }
    }

    /// «До Ап» нужно в полёте и на орбите, пока апоцентр впереди; на площадке и на земле — нет.
    static func showsTimeToApoapsis(_ t: FlightTelemetry) -> Bool {
        let inFlight = t.situation == .flying || t.situation == .suborbital || t.situation == .orbiting
        guard inFlight, let toApo = t.orbit?.timeToApoapsis, toApo.isFinite else { return false }
        return toApo > 0
    }
}
