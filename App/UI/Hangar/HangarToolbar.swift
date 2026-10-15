import OrbitPhysics
import SwiftUI

/// Нижняя полоса цеха: инструменты, симметрия и шаг (одно меню), маркеры, экипаж, «⋯».
struct HangarToolbar: View {
    let model: HangarModel
    let crewOpen: Bool
    let onCrew: () -> Void
    let onLessons: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            tools
            divider
            symmetryMenu
            markersMenu
            Spacer(minLength: 0)
            crewButton
            more
        }
        .padding(.horizontal, 6)
        .frame(height: 50)
        .hudBackground()
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 28)
    }

    private var tools: some View {
        HStack(spacing: 3) {
            ForEach(HangarModel.Tool.allCases) { tool in
                Button { model.setTool(tool) } label: {
                    VStack(spacing: 1) {
                        Image(systemName: tool.icon).font(.system(size: 16, weight: .semibold))
                        Text(tool.title).font(.system(size: HUDFont.caption, weight: .bold)).lineLimit(1)
                    }
                    .frame(width: 58, height: HUDStyle.minTouch)
                }
                .buttonStyle(HangarChipStyle(isActive: model.tool == tool))
                .accessibilityLabel(tool.title)
            }
        }
    }

    /// Одна кнопка: вид симметрии, число копий и шаг. Подпись вида «×2 · 15°».
    private var symmetryMenu: some View {
        let kind = Binding(get: { model.symmetryKind }, set: { model.setSymmetry(kind: $0) })
        let count = Binding(get: { shownCount }, set: { model.setSymmetry(count: $0) })
        let fine = Binding(get: { model.fineStep }, set: { if $0 != model.fineStep { model.toggleStep() } })
        return Menu {
            Picker("Симметрия", selection: kind) {
                ForEach(HangarModel.SymmetryKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Копий", selection: count) {
                ForEach(1...4, id: \.self) { Text("×\($0)").tag($0) }
            }
            .disabled(model.symmetryKind == .mirror)
            Picker("Шаг", selection: fine) {
                Text(model.tool == .offset ? "0.1 м" : "15°").tag(true)
                Text("Плавно").tag(false)
            }
        } label: {
            VStack(spacing: 1) {
                Text("Симметрия").font(.system(size: HUDFont.caption, weight: .bold)).foregroundStyle(HUDStyle.secondaryText)
                Text("×\(shownCount) · \(stepTitle)").font(.system(size: HUDFont.caption, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: 96, height: HUDStyle.minTouch)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel("Симметрия и шаг")
        .accessibilityValue("Копий \(shownCount), шаг \(stepTitle)")
    }

    private var shownCount: Int { model.symmetryKind == .mirror ? 2 : model.symmetryCount }

    private var stepTitle: String {
        model.fineStep ? (model.tool == .offset ? "0.1 м" : "15°") : "плавно"
    }

    private var markersMenu: some View {
        Menu {
            Toggle("ЦМ · центр масс", isOn: Bindable(model).showCOM)
            Toggle("ЦТ · центр тяги", isOn: Bindable(model).showCOT)
            Toggle("ЦД · центр давления", isOn: Bindable(model).showCOP)
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "scope").font(.system(size: 16, weight: .semibold))
                Text("Маркеры").font(.system(size: HUDFont.caption, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: 64, height: HUDStyle.minTouch)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel("Маркеры")
    }

    private var crewButton: some View {
        Button(action: onCrew) {
            VStack(spacing: 1) {
                Image(systemName: "person.2.fill").font(.system(size: 16, weight: .semibold))
                Text("Экипаж").font(.system(size: HUDFont.caption, weight: .bold)).lineLimit(1)
            }
            .frame(width: 62, height: HUDStyle.minTouch)
        }
        .buttonStyle(HangarChipStyle(isActive: crewOpen))
        .accessibilityLabel("Экипаж")
    }

    private var more: some View {
        Menu {
            Button("Обучение", systemImage: "graduationcap", action: onLessons)
            Button("Сбросить камеру", systemImage: "camera.metering.center.weighted") {
                model.scene.apply(CameraInput(reset: true))
            }
            Button("Очистить проект", systemImage: "trash", role: .destructive, action: onClear)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 48, height: HUDStyle.minTouch)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel("Ещё")
    }
}

/// Плитка-переключатель нижней полосы: подсветка активной.
struct HangarChipStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? Color.black : Color.white)
            .background(isActive ? HUDStyle.active : Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
