import OrbitPhysics
import SwiftUI

// HUD ровера (этап 6.3; макет согласован 2026-10-16, вариант B). Данные берёт из `RoverStatus`, сам ничего не считает.
// Показывается вместо HUD корабля, когда активный корабль — ровер и космонавтом не управляем.

/// Что показывает HUD ровера. Строки готовы заранее: вьюхи перерисовываются, только когда текст сменился.
struct RoverHUDState: Equatable {
    /// «4.8 м/с», назад — со знаком «−».
    var speedText: String
    /// «Лера · ровер «Тропа» · до корабля 120 м».
    var detail: String
    var chargePercent: Int
    var chargeLow: Bool
    var charging: Bool
    var handbrake: Bool
    var stabilizer: Bool
    var tipped: Bool
    var driverID: String?
    var canDrive: Bool
    /// Почему нельзя ехать (тост по тапу на приглушённый джойстик).
    var blocker: String?

    /// Заряд ниже этой доли — оранжевая полоса.
    static let lowCharge = 0.15

    init(_ r: RoverStatus, name: String?) {
        // Скорость до десятых: «−0.0» не показываем.
        let rounded = (r.speed * 10).rounded() / 10
        speedText = HUDFormat.speed(rounded == 0 ? 0 : r.speed)
        let who = r.driverID.map(FlightHUDModel.evaName) ?? "без водителя"
        var parts = [who, name.map { "ровер «\($0)»" } ?? "ровер"]
        if let d = r.distanceToShip { parts.append("до корабля " + EVAHUDState.near(d)) }
        detail = parts.joined(separator: " · ")
        let fraction = min(max(r.chargeFraction, 0), 1)
        chargePercent = Int((fraction * 100).rounded())
        chargeLow = fraction < Self.lowCharge
        charging = r.charging
        handbrake = r.handbrake
        stabilizer = r.stabilizer
        tipped = r.tipped
        driverID = r.driverID
        canDrive = r.canDrive
        if r.canDrive {
            blocker = nil
        } else {
            blocker = r.charge <= 0 ? "Батарея разряжена" : "Нет водителя"
        }
    }

    /// Имя активного ровера из списка управляемых.
    static func roverName(_ snapshot: WorldSnapshot) -> String? {
        snapshot.controllable.first { $0.isRover && $0.id == snapshot.activeVessel }?.name
    }
}

extension FlightHUDModel {
    /// Ввод ровера кадра: y → газ, x → руль. Карта, пауза и «нельзя ехать» — нейтральный.
    func roverInput() -> RoverInput {
        guard !map.isOpen, !isPaused, rover?.canDrive == true else { return .neutral }
        return RoverInput(drive: min(max(roverStick.y, -1), 1), steer: min(max(roverStick.x, -1), 1))
    }

    /// «Встать»: водитель выходит из кресла (с причиной, если нельзя).
    func roverStandUp() {
        guard rover?.driverID != nil else {
            notify("Нет водителя")
            return
        }
        if let blocker = evaExitBlocker {
            notify("Выход: " + blocker.text)
        } else {
            send(.evaExit)
        }
    }
}

/// HUD ровера: время и заряд слева сверху, статус по центру, переключатель и «Карта» справа, джойстик слева снизу,
/// «Встать», «Стаб.» и «Ручник» справа снизу.
struct RoverLayer: View {
    let model: FlightHUDModel

    static let statusWidth: CGFloat = 240

    var body: some View {
        if let state = model.rover {
            ZStack {
                topLeft(state)
                topCenter(state)
                topRight
                bottomRow(state)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .foregroundStyle(HUDPalette.text)
            .onDisappear { model.roverStick = .zero }
        }
    }

    private func topLeft(_ s: RoverHUDState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MissionTimeBar(model: model).evaFrame("time")
            RoverChargePanel(state: s).evaFrame("charge")
            if s.charging {
                Label("заряд от солнца", systemImage: "sun.max.fill")
                    .font(.system(size: HUDFont.caption, weight: .medium))
                    .foregroundStyle(HUDPalette.sas)
                    .frame(height: 16)
                    .evaFrame("charging")
            }
        }
        .padding(.top, 6)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func topCenter(_ s: RoverHUDState) -> some View {
        GeometryReader { geo in
            let shift = max(0, EVALayer.statusMinX - (geo.size.width - Self.statusWidth) / 2)
            VStack(spacing: 4) {
                RoverStatusPanel(state: s).evaFrame("status")
                if s.tipped {
                    EVAWarning(text: "Ровер опрокинут").evaFrame("warning")
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.leading, 2 * shift)
        }
    }

    private var topRight: some View {
        HStack(spacing: 2) {
            EVAModeSwitch(model: model, cosmonautSelected: false, roverSelected: true).evaFrame("switch")
            HUDIconButton(systemImage: "map", label: "Открыть карту",
                          hint: "Карта: орбиты, Луна и манёвры") { model.toggleMap() }
                .evaFrame("map")
        }
        .padding(.trailing, 2)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func bottomRow(_ s: RoverHUDState) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(spacing: 2) {
                stick(s)
                Text("ехать")
                    .font(.system(size: HUDFont.caption, weight: .semibold))
                    .foregroundStyle(HUDPalette.muted)
            }
            .evaFrame("stick")
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                EVAButton(title: "Встать", muted: s.driverID == nil) { model.roverStandUp() }
                    .evaFrame("stand")
                HStack(spacing: 6) {
                    RoverToggleButton(title: "Стаб.", on: s.stabilizer, danger: false) {
                        model.send(.setRoverStabilizer(!s.stabilizer))
                    }
                    .evaFrame("stab")
                    RoverToggleButton(title: "Ручник", on: s.handbrake, danger: true) {
                        model.send(.setHandbrake(!s.handbrake))
                    }
                    .evaFrame("brake")
                }
            }
        }
        .padding(.leading, FlightLayer.stageLeading)
        .padding(.trailing, 50)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    /// Джойстик «ехать»; без водителя или заряда приглушён, тап даёт тост причины.
    @ViewBuilder
    private func stick(_ s: RoverHUDState) -> some View {
        if s.canDrive {
            Joystick(size: 112, label: "Джойстик ровера", tint: HUDPalette.sas) { v in
                model.roverStick = SIMD2(Double(v.dx), Double(-v.dy))
            }
        } else {
            Joystick(size: 112, label: "Джойстик ровера", tint: HUDPalette.sas) { _ in }
                .allowsHitTesting(false)
                .opacity(0.35)
                .overlay {
                    Color.clear.contentShape(Circle())
                        .onTapGesture { model.notify(s.blocker ?? "Нет водителя") }
                }
                .accessibilityHint(s.blocker ?? "")
                .onAppear { model.roverStick = .zero }
        }
    }
}

// MARK: - Элементы

struct RoverStatusPanel: View {
    let state: RoverHUDState

    var body: some View {
        VStack(spacing: 1) {
            Text(state.speedText)
                .font(.system(size: HUDFont.title, weight: .bold).monospacedDigit())
                .foregroundStyle(HUDPalette.text)
            Text(state.detail)
                .font(.system(size: HUDFont.caption, weight: .medium).monospacedDigit())
                .foregroundStyle(HUDPalette.muted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 8)
        .frame(width: RoverLayer.statusWidth, height: 46)
        .classicPanel(corner: 8)
        .accessibilityElement(children: .combine)
    }
}

struct RoverChargePanel: View {
    let state: RoverHUDState

    var body: some View {
        let tint = state.chargeLow ? HUDPalette.accent : HUDPalette.sas
        VStack(alignment: .leading, spacing: 5) {
            Text("Заряд · " + HUDFormat.percent(Double(state.chargePercent) / 100))
                .font(.system(size: HUDFont.small, weight: .bold).monospacedDigit())
                .foregroundStyle(state.chargeLow ? HUDPalette.accent : HUDPalette.text)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                GeometryReader { geo in
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(state.chargePercent) / 100)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 10)
        .frame(width: 150, height: 40)
        .classicPanel(corner: 8, stroke: state.chargeLow ? HUDPalette.accent : HUDPalette.stroke)
        .accessibilityElement(children: .combine)
    }
}

/// «Стаб.» (вкл — голубая рамка и текст) и «Ручник» (вкл — тёмно-красная заливка, рамка #E24B4A, текст #F7C1C1), 86 × 44.
struct RoverToggleButton: View {
    let title: String
    let on: Bool
    let danger: Bool
    let action: () -> Void

    private static let red = Color(red: 0xE2 / 255, green: 0x4B / 255, blue: 0x4A / 255)
    private static let redText = Color(red: 0xF7 / 255, green: 0xC1 / 255, blue: 0xC1 / 255)
    private static let redFill = Color(red: 0x3A / 255, green: 0x12 / 255, blue: 0x12 / 255).opacity(0.92)

    var body: some View {
        let text: Color = on ? (danger ? Self.redText : HUDPalette.sas) : HUDPalette.text
        let stroke: Color = on ? (danger ? Self.red : HUDPalette.sas) : HUDPalette.stroke
        let fill: Color = on && danger ? Self.redFill : HUDPalette.panel
        Button(action: action) {
            Text(title)
                .font(.system(size: HUDFont.body, weight: .bold))
                .foregroundStyle(text)
                .frame(width: EVAButton.width, height: EVAButton.height)
                .classicPanel(corner: 8, fill: fill, stroke: stroke)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(title)
        .accessibilityValue(on ? "включён" : "выключен")
    }
}
