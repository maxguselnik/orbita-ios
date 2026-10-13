import SwiftUI

/// Где открыт список уроков: в ангаре (каждый урок — новый полёт) или в полёте (тур — по текущему полёту).
enum TutorialListContext {
    case hangar, flight
}

/// Список уроков: название, что внутри, отметка «пройден», «Начать». Ангар и меню паузы.
struct TutorialListPanel: View {
    let context: TutorialListContext
    let onStart: (TutorialID) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Обучение")
                    .font(.system(size: 20, weight: .heavy))
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть список уроков")
            }
            ForEach(TutorialID.allCases, id: \.self) { id in
                TutorialListRow(id: id, context: context, onStart: { onStart(id) })
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 420)
        .hudBackground(Color.black.opacity(0.88), corner: 18)
    }
}

/// Строка урока: название и подпись слева, «пройден» и «Начать» справа.
private struct TutorialListRow: View {
    let id: TutorialID
    let context: TutorialListContext
    let onStart: () -> Void

    var body: some View {
        let done = TutorialProgress.isDone(id)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(id.title)
                    .font(.system(size: 15, weight: .bold))
                Text(Self.subtitle(id, context: context))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            if done {
                Label("пройден", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(HUDPalette.green)
                    .lineLimit(1)
            }
            Button(action: onStart) {
                Text("Начать")
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 10)
            }
            .buttonStyle(HUDButtonStyle(isActive: !done))
            .accessibilityLabel("Начать урок «\(id.title)»")
        }
        .frame(minHeight: HUDStyle.minTouch)
    }

    static func subtitle(_ id: TutorialID, context: TutorialListContext) -> String {
        switch id {
        case .firstFlight:
            return "С площадки на орбиту 80 км"
        case .toLuna:
            return TutorialProgress.isDone(.firstFlight)
                ? "С орбиты: карта, узел, перелёт, посадка"
                : "С орбиты: карта, узел, посадка · сначала «Первый полёт»"
        case .controls:
            return context == .flight ? "Тур по кнопкам текущего полёта" : "Тур по каждой кнопке HUD и карты"
        }
    }
}
