import OrbitPhysics
import SwiftUI

/// Полоса экипажа в HUD (5.4): 3D-портреты 40 × 46 pt по `CrewModel.states`. Без экипажа не показывается.
struct CrewStrip: View {
    let crew: CrewModel
    /// Члены экипажа снаружи (тап по ячейке — управление ими) и погибшие (6.2).
    var outside: [String] = []
    var dead: [String] = []
    var onSelect: (String) -> Void = { _ in }

    static let cellWidth: CGFloat = 40
    static let cellHeight: CGFloat = 46

    private static let outsideTint = HUDPalette.sas
    private static let deadRed = Color(red: 0xE2 / 255, green: 0x4B / 255, blue: 0x4A / 255)

    var body: some View {
        let states = crew.states
        if !states.isEmpty {
            CrewPortraitView(states: states)
                .frame(width: Self.cellWidth * CGFloat(states.count), height: Self.cellHeight)
                .overlay(alignment: .leading) { cells(states) }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(HUDPalette.stroke, lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(states.map { Self.label($0, outside: outside, dead: dead) }.joined(separator: ". "))
        }
    }

    /// Накладка поверх портретов: «снаружи» / ✕ и тап по ячейке снаружи.
    private func cells(_ states: [CrewModel.State]) -> some View {
        HStack(spacing: 0) {
            ForEach(states) { state in
                let id = state.member.id
                if dead.contains(id) {
                    ZStack {
                        Color.black.opacity(0.7)
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(Self.deadRed)
                    }
                    .frame(width: Self.cellWidth, height: Self.cellHeight)
                } else if outside.contains(id) {
                    Button { onSelect(id) } label: {
                        ZStack(alignment: .bottom) {
                            Color(red: 12 / 255, green: 16 / 255, blue: 24 / 255).opacity(0.55)
                            Text("снаружи")
                                .font(.system(size: 8, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .foregroundStyle(Color(red: 0x06 / 255, green: 0x20 / 255, blue: 0x2A / 255))
                                .frame(width: Self.cellWidth - 4, height: 12)
                                .background(Self.outsideTint, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                                .padding(.bottom, 2)
                        }
                        .frame(width: Self.cellWidth, height: Self.cellHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: Self.cellWidth, height: Self.cellHeight)
                }
            }
        }
    }

    /// «Лера, пилот: паника».
    static func label(_ state: CrewModel.State, outside: [String] = [], dead: [String] = []) -> String {
        let status = dead.contains(state.member.id) ? "погиб"
            : (outside.contains(state.member.id) ? "снаружи" : moodTitle(state.mood))
        return "\(state.member.name), \(state.member.role.title): \(status)"
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
