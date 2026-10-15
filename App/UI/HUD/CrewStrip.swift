import OrbitPhysics
import SwiftUI

/// Полоса экипажа в HUD (5.4): 3D-портреты 40 × 46 pt по `CrewModel.states`. Без экипажа не показывается.
struct CrewStrip: View {
    let crew: CrewModel

    static let cellWidth: CGFloat = 40
    static let cellHeight: CGFloat = 46

    var body: some View {
        let states = crew.states
        if !states.isEmpty {
            CrewPortraitView(states: states)
                .frame(width: Self.cellWidth * CGFloat(states.count), height: Self.cellHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(HUDPalette.stroke, lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(states.map(Self.label).joined(separator: ". "))
        }
    }

    /// «Лера, пилот: паника».
    static func label(_ state: CrewModel.State) -> String {
        "\(state.member.name), \(state.member.role.title): \(moodTitle(state.mood))"
    }

    static func moodTitle(_ mood: CrewMood) -> String {
        switch mood {
        case .calm: "спокойствие"
        case .awe: "восторг"
        case .joy: "радость"
        case .strain: "перегрузка"
        case .panic: "паника"
        case .crash: "авария"
        }
    }
}
