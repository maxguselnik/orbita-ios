import OrbitPhysics
import SwiftUI

/// Заглушка экипажа (Б4): три маленьких портрета 30 × 34 pt со схематичным шлемом. Логики экипажа нет ни в физике,
/// ни в сохранениях — только картинка в духе жанра; показывается, если в корабле есть кабина.
struct CrewPlaceholder: View {
    struct Member: Identifiable {
        let id: String
        let name: String
        let role: String
        let visor: Color
        let isActive: Bool
    }

    static let members: [Member] = [
        Member(id: "lera", name: "Лера", role: "пилот",
               visor: Color(red: 0.243, green: 0.435, blue: 0.69), isActive: true),
        Member(id: "anton", name: "Антон", role: "инженер",
               visor: Color(red: 0.69, green: 0.478, blue: 0.243), isActive: false),
        Member(id: "mira", name: "Мира", role: "учёный",
               visor: Color(red: 0.306, green: 0.604, blue: 0.353), isActive: false),
    ]

    /// Кабина есть, если среди деталей — капсула.
    static func hasCabin(_ parts: [PartID]) -> Bool {
        parts.contains { $0.spec.kind == .pod }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.members) { member in
                CrewCard(member: member)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Портрет 30 × 34 pt: шлем с визором и плечи. Активный член экипажа — в зелёной рамке.
struct CrewCard: View {
    let member: CrewPlaceholder.Member

    var body: some View {
        CrewHelmet(visor: member.visor)
            .frame(width: 30, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(member.isActive ? HUDPalette.greenRing : HUDPalette.stroke, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(member.role) \(member.name)")
    }
}

/// Шлем из простых фигур на тёмном фоне 30 × 34: плечи, круг шлема и цветной визор.
struct CrewHelmet: View {
    let visor: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.102, green: 0.133, blue: 0.196)
            UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 5, style: .continuous)
                .fill(Color(red: 0.788, green: 0.82, blue: 0.859))
                .frame(width: 24, height: 10)
                .offset(x: 3, y: 24)
            Circle()
                .fill(Color(red: 0.867, green: 0.89, blue: 0.918))
                .frame(width: 18, height: 18)
                .offset(x: 6, y: 4)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(visor)
                .frame(width: 12, height: 8)
                .offset(x: 9, y: 8)
        }
    }
}
