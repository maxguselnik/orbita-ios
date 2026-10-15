import OrbitPhysics
import SwiftUI

/// Галерея экипажа (`-screen crewGallery`): персонажи отряда (строки) × настроения (столбцы), крупно, на весь экран.
struct CrewGallery: View {
    private static let moods: [CrewMood] = [.calm, .strain, .awe, .panic, .joy, .crash]
    private static let labelWidth: CGFloat = 64
    private static let headerHeight: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let availW = geo.size.width - Self.labelWidth - 8
            let availH = geo.size.height - Self.headerHeight - 6
            let rows = CGFloat(CrewRoster.standard.count)
            let columns = CGFloat(Self.moods.count)
            let cellW = min(availW / columns, (availH / rows) * 40 / 46)
            let cellH = cellW * 46 / 40
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.labelWidth)
                    ForEach(Self.moods, id: \.self) { mood in
                        Text(CrewStrip.moodTitle(mood))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(HUDStyle.secondaryText)
                            .frame(width: cellW)
                    }
                }
                .frame(height: Self.headerHeight)
                ForEach(CrewRoster.standard) { member in
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.name).font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                            Text(member.role.title).font(.system(size: HUDFont.caption, weight: .medium))
                                .foregroundStyle(HUDStyle.secondaryText)
                        }
                        .frame(width: Self.labelWidth, alignment: .leading)
                        .padding(.leading, 6)
                        CrewPortraitView(states: Self.moods.map {
                            CrewModel.State(member: member, mood: $0, intensity: 1)
                        })
                        .frame(width: cellW * columns, height: cellH)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .background(Color(red: 0.05, green: 0.06, blue: 0.09))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Галерея экипажа")
    }
}
