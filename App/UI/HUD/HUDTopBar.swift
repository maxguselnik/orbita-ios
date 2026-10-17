import OrbitPhysics
import SwiftUI

/// Узкая строка сверху слева (Б4): «Т+ мм:сс», ускорение времени «− ×1 +» и пауза.
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

/// Ускорение времени: «−» медленнее, текущий множитель («×1 000») и «+» быстрее. Тап по множителю
/// раскрывает полный список уровней и «До узла манёвра».
struct WarpButtons: View {
    let model: FlightHUDModel

    var body: some View {
        let status = model.warp
        HStack(spacing: 0) {
            stepButton(-1, status: status)
            currentButton(status: status)
            stepButton(1, status: status)
        }
    }

    /// Уровень после «−» (`step` = −1) или «+» (+1); nil — край списка.
    static func target(current: Int, step: Int, count: Int = TimeWarp.levels.count) -> Int? {
        let i = current + step
        return i >= 0 && i < count ? i : nil
    }

    private func stepButton(_ step: Int, status: WarpStatus) -> some View {
        let target = Self.target(current: status.index, step: step)
        let locked = step > 0 && status.blocked != nil && (target ?? 0) >= TimeWarp.physicalCount
        return Button {
            guard let target else { return }
            if locked, let reason = status.blocked {
                // Недоступный уровень не молчит: тост с причиной (как в меню текущего уровня).
                model.notify("Выше \(HUDFormat.warp(TimeWarp.levels[TimeWarp.physicalCount - 1])) нельзя: \(FlightHUDModel.warpReasonText(reason))")
            } else {
                model.send(.setWarp(index: target))
            }
        } label: {
            Image(systemName: step < 0 ? "minus" : "plus")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(HUDPalette.text)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 40, height: HUDStyle.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .disabled(target == nil)
        .opacity(target == nil || locked ? 0.4 : 1)
        .accessibilityLabel(step < 0 ? "Медленнее" : "Быстрее")
        .longPressHint(step < 0 ? "Медленнее: на уровень ниже; ×1 — обычное время"
                                : "Быстрее: долгие перелёты проходят быстрее (у атмосферы и при тяге нельзя выше ×4)")
    }

    private func currentButton(status: WarpStatus) -> some View {
        let fast = status.index > 0
        return Menu {
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
            if let e = model.encounterWarp {
                Button {
                    model.warpToEncounter()
                } label: {
                    Label("До встречи с " + MapText.instrumental(e.body) + " · стоп за 10 мин", systemImage: "forward.fill")
                }
                .disabled(!model.canWarpToEncounter)
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
            Text(HUDFormat.warp(status.factor))
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .foregroundStyle(fast ? Color(red: 0.73, green: 0.96, blue: 0.76) : HUDPalette.text)
                .padding(.horizontal, 7)
                .frame(minWidth: 44, minHeight: 32)
                .background(fast ? HUDPalette.greenDark : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(minHeight: HUDStyle.minTouch)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Ускорение времени \(HUDFormat.warp(status.factor)), выбрать уровень")
        .longPressHint("Ускорение времени: ×1 — обычное время; тап — список уровней и «До узла манёвра»")
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
