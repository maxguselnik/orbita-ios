import SwiftUI

/// Заглушка до реализации потока B: ряд ячеек 40:46 по `states`. Поток B заменяет на 3D-портреты (RealityKit).
struct CrewPortraitView: View {
    let states: [CrewModel.State]

    init(states: [CrewModel.State]) {
        self.states = states
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(states) { state in
                Color.gray.opacity(0.3)
                    .aspectRatio(40.0 / 46.0, contentMode: .fit)
                    .overlay(Text(state.member.name).font(.system(size: 6)))
            }
        }
    }
}
