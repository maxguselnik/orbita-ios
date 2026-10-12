import OrbitPhysics
import SwiftUI

/// Заглушка экипажа: три карточки со схематичным шлемом. Логики экипажа нет ни в физике, ни в сохранениях —
/// только картинка в духе жанра; показывается, если в корабле есть кабина.
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
        HStack(spacing: 4) {
            ForEach(Self.members) { member in
                CrewCard(member: member)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Карточка 46 × 60 pt: шлем, имя, роль. Активный член экипажа — в зелёной рамке.
struct CrewCard: View {
    let member: CrewPlaceholder.Member

    var body: some View {
        VStack(spacing: 2) {
            CrewHelmet(visor: member.visor)
                .frame(width: 38, height: 36)
            Text(member.name)
                .font(.system(size: 7))
                .foregroundStyle(HUDPalette.text)
            Text(member.role)
                .font(.system(size: 6))
                .foregroundStyle(HUDPalette.muted)
        }
        .lineLimit(1)
        .padding(3)
        .frame(width: 46, height: 60)
        .classicPanel(corner: 7, stroke: member.isActive ? HUDPalette.greenRing : HUDPalette.stroke)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(member.role) \(member.name)")
    }
}

/// Шлем из простых фигур: плечи, круг шлема и цветной визор на тёмном фоне.
struct CrewHelmet: View {
    let visor: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.14, green: 0.2, blue: 0.29),
                                              Color(red: 0.063, green: 0.09, blue: 0.141)],
                                     startPoint: .top, endPoint: .bottom))
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 6, style: .continuous)
                .fill(Color(red: 0.788, green: 0.82, blue: 0.859))
                .frame(width: 30, height: 12)
                .offset(x: 4, y: 28)
            Circle()
                .fill(Color(red: 0.867, green: 0.89, blue: 0.918))
                .overlay(Circle().strokeBorder(Color(red: 0.604, green: 0.643, blue: 0.698), lineWidth: 2))
                .frame(width: 24, height: 24)
                .offset(x: 7, y: 4)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(visor)
                .frame(width: 16, height: 12)
                .offset(x: 11, y: 9)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
