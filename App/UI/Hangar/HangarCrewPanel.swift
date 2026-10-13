import OrbitPhysics
import SwiftUI

/// Панель «Экипаж» цеха (5.4): кабины проекта и их места. Место — портрет `calm` и имя; пустое — «+».
/// Тап открывает меню выбора из отряда или «Пусто»; правка идёт через `HangarModel.setSeat` (отмена/повтор, автосохранение).
struct HangarCrewPanel: View {
    let model: HangarModel
    let onClose: () -> Void

    private struct Cabin: Identifiable {
        let id: Int
        let title: String
        let seats: [CrewSeat]
    }

    private var cabins: [Cabin] {
        let design = model.design
        var order: [Int] = []
        var grouped: [Int: [CrewSeat]] = [:]
        for seat in design.seating() {
            if grouped[seat.partID] == nil { order.append(seat.partID) }
            grouped[seat.partID, default: []].append(seat)
        }
        return order.map { id in
            Cabin(id: id, title: design.node(id)?.part.spec.name ?? "Кабина", seats: grouped[id] ?? [])
        }
    }

    var body: some View {
        let cabins = cabins
        VStack(spacing: 4) {
            HStack {
                Text("Экипаж").font(.system(size: 13, weight: .heavy))
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 36, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть экипаж")
            }
            .foregroundStyle(.white)

            if cabins.isEmpty {
                Text("Нет кабин")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(cabins) { cabin in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cabin.title)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(HUDStyle.secondaryText)
                                HStack(alignment: .top, spacing: 6) {
                                    ForEach(cabin.seats, id: \.index) { seat in
                                        seatMenu(seat)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 110)
            }
        }
        .padding(6)
        .hudBackground(Color.black.opacity(0.75))
    }

    private func member(_ id: String?) -> CrewMember? {
        id.flatMap { CrewRoster.member($0, in: CrewRoster.standard) }
    }

    private func seatMenu(_ seat: CrewSeat) -> some View {
        let seated = member(seat.memberID)
        return Menu {
            ForEach(CrewRoster.standard) { candidate in
                Button("\(candidate.name), \(candidate.role.title)") {
                    model.setSeat(partID: seat.partID, index: seat.index, memberID: candidate.id)
                }
            }
            Button("Пусто", systemImage: "person.slash") {
                model.setSeat(partID: seat.partID, index: seat.index, memberID: nil)
            }
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    if let seated {
                        CrewPortraitView(states: [CrewModel.State(member: seated, mood: .calm, intensity: 0)])
                            .allowsHitTesting(false)
                    } else {
                        Image(systemName: "plus").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(HUDStyle.secondaryText)
                    }
                }
                .frame(width: 44, height: 51)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(HUDPalette.stroke, lineWidth: 1))
                Text(seated?.name ?? "Пусто")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(seated == nil ? HUDStyle.secondaryText : .white)
                    .lineLimit(1)
            }
            .frame(width: 56)
        }
        .accessibilityLabel(seated.map { "Место \(seat.index + 1): \($0.name), \($0.role.title)" } ?? "Место \(seat.index + 1): пусто")
        .accessibilityHint("Выбрать члена экипажа")
    }
}
