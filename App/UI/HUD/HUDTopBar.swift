import OrbitPhysics
import SwiftUI

/// Узкая строка сверху слева (Б4): «Т+ мм:сс», три ближайших уровня ускорения времени и пауза.
/// Каждый кадр перерисовывается только часы (`MissionClock`), кнопки — при смене своих полей.
struct MissionTimeBar: View {
    let model: FlightHUDModel

    /// Высота строки: все кнопки в ней — зона касания 44 pt.
    static let height: CGFloat = HUDStyle.minTouch

    var body: some View {
        HStack(spacing: 0) {
            MissionClock(model: model)
            WarpButtons(model: model)
                .tutorialAnchor(.warp)
            Button {
                model.pause()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(HUDPalette.text)
                    .frame(width: 38, height: 32)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityLabel("Пауза")
            .longPressHint("Пауза: меню, ангар, обучение")
        }
        .padding(.horizontal, 3)
        .frame(height: MissionTimeBar.height)
        .classicPanel(corner: 8)
    }
}

/// Время миссии: «Т+ 00:01:09»; до старта — «Т− 00:00:00».
struct MissionClock: View {
    let model: FlightHUDModel

    var body: some View {
        Text(Self.text(model.telemetry))
            .font(.system(size: HUDFont.body, weight: .bold).monospacedDigit())
            .foregroundStyle(HUDPalette.green)
            .lineLimit(1)
            .padding(.horizontal, 5)
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
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(active ? Color(red: 0.73, green: 0.96, blue: 0.76) : HUDPalette.muted)
        .frame(width: 38, height: 32)
        .background(active ? HUDPalette.greenDark : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
        .contentShape(Rectangle())
    }

    private func neighbourButton(position: Int, index: Int, status: WarpStatus) -> some View {
        let factor = TimeWarp.levels[index]
        let locked = status.blocked != nil && index >= TimeWarp.physicalCount
        return Button {
            if locked, let reason = status.blocked {
                // Недоступный уровень не молчит: тост с причиной (как в меню текущего уровня).
                model.notify("Выше \(HUDFormat.warp(TimeWarp.levels[TimeWarp.physicalCount - 1])) нельзя: \(FlightHUDModel.warpReasonText(reason))")
            } else {
                model.send(.setWarp(index: index))
            }
        } label: {
            glyph(position: position, active: false)
        }
        .buttonStyle(HUDPressStyle())
        .opacity(locked ? 0.4 : 1)
        .accessibilityLabel("Ускорение \(HUDFormat.warp(factor))")
        .longPressHint("Ускорить время до \(HUDFormat.warp(factor)): долгие перелёты проходят быстрее")
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
            // Меню открыто — шаг урока «Время и ускорение» засчитывается.
            .onAppear { model.noteWarpMenu() }
        } label: {
            glyph(position: position, active: true)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Ускорение времени \(HUDFormat.warp(status.factor)), выбрать уровень")
        .longPressHint("Ускорение времени: ×1 — обычное, дальше быстрее (у атмосферы и при тяге нельзя)")
    }
}

/// Квадратная иконка в зоне касания: обычная 36 pt (зона 44), компактная 30 pt (зона 34).
struct HUDIconButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    var compact = false
    /// Подсказка по долгому нажатию (nil — без подсказки).
    var hint: String?
    let action: () -> Void

    var body: some View {
        let side: CGFloat = compact ? 30 : 36
        let touch: CGFloat = compact ? 34 : HUDStyle.minTouch
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : HUDPalette.text)
                .frame(width: side, height: side)
                .classicPanel(corner: compact ? 7 : 8, fill: isActive ? HUDStyle.active : HUDPalette.panel)
                .frame(width: touch, height: touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(label)
        .longPressHint(hint ?? label)
    }
}

/// Карта и камера справа сверху в полёте: две кнопки 44 × 44 в ряд.
struct FlightCornerButtons: View {
    let model: FlightHUDModel

    var body: some View {
        HStack(spacing: 0) {
            HUDIconButton(systemImage: "map", label: "Открыть карту",
                          hint: "Карта: орбиты, Луна и манёвры") { model.toggleMap() }
                .tutorialAnchor(.mapButton)
            HUDIconButton(systemImage: CameraModeInfo.symbol(model.cameraMode),
                          label: "Камера: \(CameraModeInfo.fullName(model.cameraMode))",
                          hint: "Камера: свободная, следом за кораблём, по курсу — тап меняет") {
                model.cycleCameraMode()
            }
        }
    }
}

/// Кнопка панели ступеней на карте (в полёте панель открывает тап по стопке ступеней).
struct StagePanelButton: View {
    let model: FlightHUDModel

    var body: some View {
        HUDIconButton(systemImage: "list.bullet.rectangle", label: "Ступени, топливо, Δv",
                      isActive: model.isPanelOpen, hint: "Ступени: топливо, Δv и тяга каждой ступени") {
            withAnimation(.snappy(duration: 0.25)) { model.isPanelOpen.toggle() }
        }
    }
}
