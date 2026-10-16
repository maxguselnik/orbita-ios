import OrbitPhysics
import SwiftUI

/// Шаг пошаговой подсказки карты. Показывается один, по состоянию узла.
enum MapHintStep: String, Hashable, CaseIterable, Sendable {
    case intro, placeNode, dragHandles, warpToNode, burnSoon, lowRemaining, done

    /// Ключ `@AppStorage`: пройденные обучающие шаги через запятую.
    static let seenKey = "mapHintsSeen"
    /// Δv ниже этого порога считается нулём, м/с.
    static let zeroDeltaV = 0.5
    /// Остаток, при котором пора убавлять тягу, м/с.
    static let lowRemainingDeltaV = 10.0
    /// За сколько секунд до прожига показывать подсказку про тягу.
    static let burnLead = 15.0

    /// Обучающие шаги запоминаются и не повторяются; «живые» (про прожиг) зависят от момента.
    var isLearning: Bool {
        switch self {
        case .intro, .placeNode, .dragHandles, .warpToNode: true
        case .burnSoon, .lowRemaining, .done: false
        }
    }

    func text(lunaAvailable: Bool) -> String {
        switch self {
        case .intro:
            "Крутите карту пальцем, щипок — масштаб, двойной тап — сброс. Внизу — центр: корабль, Терра, Луна."
        case .placeNode:
            lunaAvailable
                ? "Тапните по орбите — поставьте узел манёвра. Или нажмите „К Луне“ — узел перелёта рассчитается сам."
                : "Тапните по орбите — поставьте узел манёвра."
        case .dragHandles:
            "Тяните ручки: жёлто-зелёная — разгон, напротив неё — торможение, фиолетовые — наклон орбиты, голубые — радиальные. Жёлтая линия — орбита после манёвра."
        case .warpToNode:
            "Нажмите „К узлу“ — время ускорится и остановится за 15 с до прожига. Включите SAS „УЗЕЛ“ — нос повернётся по манёвру."
        case .burnSoon:
            "Когда „начало через“ дойдёт до 0 — тяга MAX. Глушите, когда остаток почти 0."
        case .lowRemaining:
            "Уменьшите тягу — осталось мало."
        case .done:
            "Готово! Удалите узел."
        }
    }

    /// Шаг по состоянию узла.
    static func current(node: ManeuverStatus?, introSeen: Bool) -> MapHintStep {
        guard let m = node else { return introSeen ? .placeNode : .intro }
        if m.isDone { return .done }
        if m.deltaV < zeroDeltaV { return .dragHandles }
        if m.timeToBurn <= 0, m.remainingDeltaV < lowRemainingDeltaV { return .lowRemaining }
        if m.timeToBurn <= burnLead { return .burnSoon }
        return .warpToNode
    }
}

/// Легенда карты поверх экрана; закрывается тапом в любом месте.
struct MapLegendView: View {
    let onClose: () -> Void

    @AppStorage(MapHintStep.seenKey) private var seenRaw = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            HStack(alignment: .top, spacing: 16) {
                linesColumn
                burnColumn
                phaseColumn
            }
            .padding(12)
            .frame(maxWidth: 680)
            .hudBackground(Color.black.opacity(0.85), corner: 14)
            .padding(.horizontal, 12)
            .onTapGesture(perform: onClose)
        }
        .accessibilityAddTraits(.isModal)
    }

    private var linesColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            heading("Линии")
            swatch(HUDStyle.active, "голубая — текущая орбита")
            swatch(MapPalette.afterManeuver, "жёлтый пунктир — после узла", dashed: true)
            swatch(MapPalette.encounter, "фиолетовая — у Луны, встреча")
            swatch(MapPalette.returnTrip, "оранжевая — возврат к Терре")
            heading("Отметки")
            note("Ап — высшая точка орбиты, Пе — низшая")
            note("ВУ / НУ — где орбита пересекает экватор вверх / вниз")
            note("Вход / выход SOI — граница влияния тела")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var burnColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            heading("Как сделать прожиг")
            note("1. Тапните по орбите — узел.")
            note("2. Тяните ручки Δv, пока жёлтая линия не даст нужную орбиту.")
            note("3. „К узлу“ — время идёт до 15 с перед прожигом. SAS „УЗЕЛ“ — нос по манёвру.")
            note("4. Когда „начало через“ = 0 — тяга MAX; глушите, когда остаток почти 0. Затем удалите узел.")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var phaseColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            heading("Фаза Луны")
            note("Угол от корабля до Луны по ходу движения.")
            note("Когда он равен „нужной“ — пора лететь к Луне: кнопка „К Луне“ ставит узел сама.")
            Button {
                seenRaw = ""
            } label: {
                Text("Показать подсказки снова")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(HUDButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(HUDStyle.accent)
            .padding(.top, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func swatch(_ color: Color, _ text: String, dashed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1.5))
                path.addLine(to: CGPoint(x: 22, y: 1.5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: dashed ? [5, 3] : []))
            .frame(width: 22, height: 3)
            note(text)
        }
    }
}
