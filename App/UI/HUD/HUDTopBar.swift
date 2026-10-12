import OrbitPhysics
import SwiftUI

/// Плашка сверху слева: «Т+ мм:сс», три ближайших уровня ускорения времени и пауза.
/// Каждый кадр перерисовывается только часы (`MissionClock`), кнопки — при смене своих полей.
struct MissionTimeBar: View {
    let model: FlightHUDModel

    var body: some View {
        HStack(spacing: 0) {
            MissionClock(model: model)
            WarpButtons(model: model)
            Button {
                model.pause()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(HUDPalette.text)
                    .frame(width: 32, height: 26)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .frame(width: 40, height: HUDStyle.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityLabel("Пауза")
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .classicPanel()
    }
}

/// Время миссии: «Т+ 00:01:09»; до старта — «Т− 00:00:00».
struct MissionClock: View {
    let model: FlightHUDModel

    var body: some View {
        Text(Self.text(model.telemetry))
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(HUDPalette.green)
            .lineLimit(1)
            .padding(.horizontal, 6)
    }

    static func text(_ t: FlightTelemetry) -> String {
        t.mission.launched ? HUDFormat.missionTime(t.missionTime) : "Т" + HUDFormat.minus + " " + HUDFormat.clock(0)
    }
}

/// Ускорение времени: три соседних уровня ▶ / ▶▶ / ▶▶▶ вокруг текущего. Текущий — зелёный, тап по нему
/// раскрывает полный список уровней и «До узла манёвра»; тап по соседнему переключает сразу.
struct WarpButtons: View {
    let model: FlightHUDModel

    var body: some View {
        let status = model.warp
        HStack(spacing: 0) {
            ForEach(Array(Self.window(current: status.index).enumerated()), id: \.offset) { position, index in
                if index == status.index {
                    currentButton(position: position, status: status)
                } else {
                    neighbourButton(position: position, index: index, status: status)
                }
            }
        }
    }

    /// Индексы трёх уровней `TimeWarp.levels` вокруг текущего (текущий — в середине, у краёв списка — сбоку).
    static func window(current: Int, count: Int = TimeWarp.levels.count) -> [Int] {
        guard count >= 3 else { return Array(0..<max(count, 0)) }
        let start = min(max(current - 1, 0), count - 3)
        return [start, start + 1, start + 2]
    }

    private func glyph(position: Int, active: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0...position, id: \.self) { _ in
                Image(systemName: "play.fill").font(.system(size: 7, weight: .bold))
            }
        }
        .foregroundStyle(active ? Color(red: 0.73, green: 0.96, blue: 0.76) : HUDPalette.muted)
        .frame(width: 32, height: 26)
        .background(active ? HUDPalette.greenDark : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .frame(width: 40, height: HUDStyle.minTouch)
        .contentShape(Rectangle())
    }

    private func neighbourButton(position: Int, index: Int, status: WarpStatus) -> some View {
        let factor = TimeWarp.levels[index]
        let locked = status.blocked != nil && index >= TimeWarp.physicalCount
        return Button {
            model.send(.setWarp(index: index))
        } label: {
            glyph(position: position, active: false)
        }
        .buttonStyle(HUDPressStyle())
        .disabled(locked)
        .opacity(locked ? 0.4 : 1)
        .accessibilityLabel("Ускорение \(HUDFormat.warp(factor))")
    }

    private func currentButton(position: Int, status: WarpStatus) -> some View {
        Menu {
            if let reason = status.blocked {
                Text(verbatim: "Выше \(HUDFormat.warp(TimeWarp.levels[TimeWarp.physicalCount - 1])) нельзя: \(FlightHUDModel.warpReasonText(reason))")
            }
            if model.hasManeuver {
                Button {
                    model.warpToManeuver()
                } label: {
                    Label("До узла манёвра", systemImage: "forward.end.fill")
                }
                .disabled(!model.canWarpToManeuver)
            }
            ForEach(Array(TimeWarp.levels.enumerated()), id: \.offset) { index, factor in
                Button {
                    model.send(.setWarp(index: index))
                } label: {
                    if index == status.index {
                        Label(HUDFormat.warp(factor), systemImage: "checkmark")
                    } else {
                        Text(HUDFormat.warp(factor))
                    }
                }
                .disabled(status.blocked != nil && index >= TimeWarp.physicalCount)
            }
        } label: {
            glyph(position: position, active: true)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Ускорение времени \(HUDFormat.warp(status.factor)), выбрать уровень")
    }
}

/// Квадратная иконка 36 pt в зоне касания 44 pt: правая колонка (карта, камера, ступени).
struct HUDIconButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : HUDPalette.text)
                .frame(width: 36, height: 36)
                .classicPanel(corner: 8, fill: isActive ? HUDStyle.active : HUDPalette.panel)
                .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(label)
    }
}

/// Вертикальные иконки справа сверху: карта (в полёте), камера (в полёте), ступени. Все — существующие действия.
struct HUDSideButtons: View {
    let model: FlightHUDModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.map.isOpen {
                HUDIconButton(systemImage: "map", label: "Открыть карту") { model.toggleMap() }
                HUDIconButton(systemImage: CameraModeInfo.symbol(model.cameraMode),
                              label: "Камера: \(CameraModeInfo.fullName(model.cameraMode))") {
                    model.cycleCameraMode()
                }
            }
            HUDIconButton(systemImage: "list.bullet.rectangle", label: "Ступени, топливо, Δv",
                          isActive: model.isPanelOpen) {
                withAnimation(.snappy(duration: 0.25)) { model.isPanelOpen.toggle() }
            }
        }
    }
}
