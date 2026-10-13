import OrbitPhysics
import SwiftUI

/// Нижняя полоса цеха: инструменты, симметрия, шаг, маркеры, «⋯».
struct HangarToolbar: View {
    let model: HangarModel
    let onLessons: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            tools
            divider
            symmetry
            divider
            stepButton
            divider
            markers
            Spacer(minLength: 0)
            more
        }
        .padding(.horizontal, 6)
        .frame(height: 46)
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
                        Image(systemName: tool.icon).font(.system(size: 15, weight: .semibold))
                        Text(tool.title).font(.system(size: 9, weight: .bold)).lineLimit(1)
                    }
                    .frame(width: 54, height: 40)
                }
                .buttonStyle(HangarChipStyle(isActive: model.tool == tool))
                .accessibilityLabel(tool.title)
            }
        }
    }

    private var symmetry: some View {
        HStack(spacing: 3) {
            Menu {
                ForEach(HangarModel.SymmetryKind.allCases, id: \.self) { kind in
                    Button(kind.title) { model.setSymmetry(kind: kind) }
                }
            } label: {
                VStack(spacing: 1) {
                    Text("Симметрия").font(.system(size: 8, weight: .bold)).foregroundStyle(HUDStyle.secondaryText)
                    Text(model.symmetryKind.title).font(.system(size: 10.5, weight: .bold)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .frame(width: 74, height: 40)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("Вид симметрии")
            ForEach(1...4, id: \.self) { n in
                Button { model.setSymmetry(count: n) } label: {
                    Text("×\(n)").font(.system(size: 12, weight: .heavy)).frame(width: 30, height: 40)
                }
                .buttonStyle(HangarChipStyle(isActive: shownCount == n))
                .disabled(model.symmetryKind == .mirror)
                .opacity(model.symmetryKind == .mirror ? 0.4 : 1)
                .accessibilityLabel("Копий: \(n)")
            }
        }
    }

    private var shownCount: Int { model.symmetryKind == .mirror ? 2 : model.symmetryCount }

    private var stepButton: some View {
        Button { model.toggleStep() } label: {
            VStack(spacing: 1) {
                Text("Шаг").font(.system(size: 8, weight: .bold))
                Text(model.fineStep ? (model.tool == .offset ? "0.1 м" : "15°") : "плавно")
                    .font(.system(size: 10.5, weight: .bold)).lineLimit(1)
            }
            .frame(width: 52, height: 40)
        }
        .buttonStyle(HangarChipStyle(isActive: model.fineStep))
        .accessibilityLabel("Шаг поворота и сдвига")
    }

    private var markers: some View {
        HStack(spacing: 3) {
            markerButton("ЦМ", isOn: Bindable(model).showCOM)
            markerButton("ЦТ", isOn: Bindable(model).showCOT)
            markerButton("ЦД", isOn: Bindable(model).showCOP)
        }
    }

    private func markerButton(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title).font(.system(size: 11, weight: .heavy)).frame(width: 32, height: 40)
        }
        .buttonStyle(HangarChipStyle(isActive: isOn.wrappedValue))
        .accessibilityLabel("Маркер \(title)")
    }

    private var more: some View {
        Menu {
            Button("Обучение", systemImage: "graduationcap", action: onLessons)
            Button("Сбросить камеру", systemImage: "camera.metering.center.weighted") {
                model.scene.apply(CameraInput(reset: true))
            }
            Button("Очистить проект", systemImage: "trash", role: .destructive, action: onClear)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
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
