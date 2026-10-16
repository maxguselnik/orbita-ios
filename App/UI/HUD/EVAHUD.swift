import OrbitPhysics
import SwiftUI

// HUD космонавта (EVA, этап 6; макет согласован 2026-10-16). Данные берёт из `CosmonautState`, сам ничего не считает:
// только форматирует. Корабельный HUD в этом режиме скрыт целиком.

/// Что показывает HUD EVA. Строки готовы заранее: вьюхи перерисовываются, только когда текст реально сменился
/// (скорость — с шагом 0.1 м/с, топливо — 1 %).
struct EVAHUDState: Equatable {
    var name: String
    /// Первая строка статуса: «Лера · Луна» / «Лера · орбита Луны».
    var title: String
    /// Вторая строка: скорость или Ап·Пе и расстояние до люка.
    var detail: String
    var fuelPercent: Int
    var fuelLow: Bool
    var jetpackOn: Bool
    var onGround: Bool
    var canBoard: Bool
    /// Красная плашка под статусом (nil — нет).
    var warning: String?
    var flagBlocker: ScienceBlocker?
    var sampleBlocker: ScienceBlocker?
    var reportBlocker: ScienceBlocker?

    /// Запас ранца ниже этой доли — предупреждение.
    static let lowFuel = 0.2
    /// Опасное падение: вертикальная скорость ниже −7 м/с ниже 100 м над рельефом.
    static let dangerFall = -7.0
    static let dangerHeight = 100.0

    init(_ c: CosmonautState) {
        name = c.name
        let bodyName = Bodies.body(c.body).name
        let hatch = c.hatchDistance.map { "до люка " + Self.near($0) }
        if c.onGround || c.orbit == nil {
            title = "\(c.name) · \(bodyName)"
            detail = (["скорость " + HUDFormat.speed(c.surfaceSpeed)] + [hatch].compactMap { $0 }).joined(separator: " · ")
        } else {
            title = "\(c.name) · орбита \(MapText.genitive(c.body))"
            let orbit = c.orbit
            detail = (["Ап " + HUDFormat.distance(orbit?.apoapsisAltitude), "Пе " + HUDFormat.distance(orbit?.periapsisAltitude)]
                      + [hatch].compactMap { $0 }).joined(separator: " · ")
        }
        let fraction = min(max(c.fuelFraction, 0), 1)
        fuelPercent = Int((fraction * 100).rounded())
        fuelLow = fraction < Self.lowFuel
        jetpackOn = c.jetpackOn
        onGround = c.onGround
        canBoard = c.canBoard
        if !c.onGround, c.verticalSpeed < Self.dangerFall, c.heightAboveTerrain < Self.dangerHeight {
            warning = "Скорость падения \(Int(abs(c.verticalSpeed).rounded())) м/с — опасно"
        } else if c.jetpackOn, fraction < Self.lowFuel {
            warning = "Мало топлива ранца — вернитесь к люку"
        } else {
            warning = nil
        }
        flagBlocker = c.flagBlocker
        sampleBlocker = c.sampleBlocker
        reportBlocker = c.reportBlocker
    }

    /// Малые расстояния с десятыми («1.6 м»), большие — как везде.
    static func near(_ meters: Double) -> String {
        meters.isFinite && meters < 100 ? HUDFormat.fixed(max(meters, 0), digits: 1) + " м" : HUDFormat.distance(meters)
    }

    /// Подпись под джойстиком.
    var stickLabel: String {
        onGround ? "идти" : (jetpackOn ? "лететь" : "дрейф")
    }
}

extension FlightHUDModel {
    /// Ввод космонавта кадра: джойстик в осях камеры, «Вверх/Вниз». Карта и пауза — нейтральный.
    func evaInput() -> EVAInput {
        guard !map.isOpen, !isPaused else { return .neutral }
        var move = Vec3.zero
        if let basis = feedback?.renderer?.evaCameraBasis {
            move = basis.right * evaStick.x + basis.forward * evaStick.y
        }
        return EVAInput(move: move, vertical: min(max(evaVertical, -1), 1))
    }

    /// Кнопка с блокером: тап по недоступной показывает причину.
    func evaAction(_ command: FlightCommand, blocker: ScienceBlocker? = nil) {
        if let blocker {
            notify(String(blocker.text.prefix(1)).uppercased() + String(blocker.text.dropFirst()))
        } else {
            send(command)
        }
    }

    /// Переключатель «Корабль | Космонавт».
    func evaSelectCosmonaut() {
        if snapshot.cosmonauts.isEmpty {
            if let blocker = snapshot.evaExitBlocker {
                notify("Выход: " + blocker.text)
            } else {
                send(.evaExit)
            }
        } else {
            send(.evaSwitch)
        }
    }

    func evaSelectShip() {
        send(.evaSwitch)
    }

    /// Переключатель в режиме корабля: есть экипаж или кто-то снаружи; не в уроках и не на карте.
    var showsEVASwitch: Bool {
        tutorial == nil && !map.isOpen && (!crew.isEmpty || telemetry.science.crewAboard || evaOutside > 0)
    }

    nonisolated static func evaName(_ id: String) -> String {
        CrewRoster.member(id)?.name ?? "Космонавт"
    }

    /// Рода из отряда: Лера и Мира — женский.
    nonisolated static func evaVerb(_ id: String, _ male: String, _ female: String) -> String {
        ["lera", "mira"].contains(id) ? female : male
    }
}

// MARK: - Рамки для проверки раскладки

/// Рамки элементов HUD EVA в глобальных координатах (проверка раскладки в тестах).
struct EVAFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    fileprivate func evaFrame(_ name: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: EVAFrameKey.self, value: [name: geo.frame(in: .global)])
        })
    }
}

// MARK: - Раскладка

/// HUD космонавта: время и ранец слева сверху, статус по центру, «Корабль | Космонавт» и «Карта» справа,
/// джойстик слева снизу, кнопки действий справа, «В капсулу» правее центра.
struct EVALayer: View {
    let model: FlightHUDModel

    var body: some View {
        if let state = model.eva {
            ZStack {
                topLeft(state)
                topCenter(state)
                topRight
                bottomRow(state)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .foregroundStyle(HUDPalette.text)
            .onDisappear {
                model.evaStick = .zero
                model.evaVertical = 0
            }
        }
    }

    private func topLeft(_ s: EVAHUDState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MissionTimeBar(model: model).evaFrame("time")
            EVAFuelPanel(state: s).evaFrame("fuel")
            EVAJetpackButton(state: s) { model.send(.evaToggleJetpack) }.evaFrame("jetpack")
        }
        .padding(.top, 6)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func topCenter(_ s: EVAHUDState) -> some View {
        VStack(spacing: 4) {
            EVAStatusPanel(state: s).evaFrame("status")
            if let warning = s.warning {
                EVAWarning(text: warning).evaFrame("warning")
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var topRight: some View {
        HStack(spacing: 2) {
            EVAModeSwitch(model: model, cosmonautSelected: true).evaFrame("switch")
            HUDIconButton(systemImage: "map", label: "Открыть карту",
                          hint: "Карта: орбиты, Луна и манёвры") { model.toggleMap() }
                .evaFrame("map")
        }
        .padding(.trailing, 2)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func bottomRow(_ s: EVAHUDState) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(spacing: 2) {
                Joystick(size: 112, label: "Джойстик космонавта", tint: HUDPalette.green) { v in
                    model.evaStick = SIMD2(Double(v.dx), Double(-v.dy))
                }
                Text(s.stickLabel)
                    .font(.system(size: HUDFont.caption, weight: .semibold))
                    .foregroundStyle(HUDPalette.muted)
            }
            .evaFrame("stick")
            Spacer(minLength: 8)
            EVABoardButton(canBoard: s.canBoard) {
                if s.canBoard {
                    model.send(.evaBoard)
                } else {
                    model.notify("Подойдите к люку ближе \(Int(EVABalance.boardRadius)) м")
                }
            }
            .evaFrame("board")
            Spacer(minLength: 8).frame(maxWidth: 60)
            actions(s)
        }
        .padding(.leading, FlightLayer.stageLeading)
        .padding(.trailing, 50)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    private func actions(_ s: EVAHUDState) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if s.onGround {
                EVAButton(title: "Флаг", muted: s.flagBlocker != nil) {
                    model.evaAction(.evaPlantFlag, blocker: s.flagBlocker)
                }
                .evaFrame("flag")
                EVAButton(title: "Образец", muted: s.sampleBlocker != nil) {
                    model.evaAction(.evaCollectSample, blocker: s.sampleBlocker)
                }
                .evaFrame("sample")
            }
            EVAButton(title: "Отчёт", muted: s.reportBlocker != nil) {
                model.evaAction(.evaReport, blocker: s.reportBlocker)
            }
            .evaFrame("report")
            HStack(spacing: 6) {
                EVAHoldButton(title: "Вниз", muted: !s.jetpackOn) { model.evaVertical = $0 ? -1 : 0 }
                    .evaFrame("down")
                if s.jetpackOn {
                    EVAHoldButton(title: "Вверх", muted: false) { model.evaVertical = $0 ? 1 : 0 }
                        .evaFrame("up")
                } else {
                    EVAButton(title: "Прыжок", muted: !s.onGround) {
                        if s.onGround { model.send(.evaJump) }
                    }
                    .evaFrame("jump")
                }
            }
        }
    }
}

// MARK: - Элементы

/// Переключатель «Корабль | Космонавт» (148 × 32, касание 44 pt по высоте).
struct EVAModeSwitch: View {
    let model: FlightHUDModel
    let cosmonautSelected: Bool

    static let width: CGFloat = 148
    static let height: CGFloat = 32

    private static let selectedText = Color(red: 0x06 / 255, green: 0x20 / 255, blue: 0x2A / 255)

    var body: some View {
        HStack(spacing: 0) {
            segment("Корабль", selected: !cosmonautSelected) { if cosmonautSelected { model.evaSelectShip() } }
            segment("Космонавт", selected: cosmonautSelected) { if !cosmonautSelected { model.evaSelectCosmonaut() } }
        }
        .frame(width: Self.width, height: Self.height)
        .background(HUDPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(HUDPalette.sas, lineWidth: 1))
        .frame(height: HUDStyle.minTouch)
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: HUDFont.small, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? Self.selectedText : HUDPalette.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selected ? HUDPalette.sas : Color.clear)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Режим корабля: переключатель под кнопками «Карта/Камера», не перекрывает полосу экипажа.
struct EVAShipSwitch: View {
    let model: FlightHUDModel

    var body: some View {
        if model.showsEVASwitch {
            EVAModeSwitch(model: model, cosmonautSelected: false)
                .padding(.top, 52)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}

struct EVAStatusPanel: View {
    let state: EVAHUDState

    static let width: CGFloat = 260

    var body: some View {
        VStack(spacing: 2) {
            Text(state.title)
                .font(.system(size: HUDFont.body, weight: .bold))
                .foregroundStyle(HUDPalette.text)
            Text(state.detail)
                .font(.system(size: HUDFont.caption, weight: .medium).monospacedDigit())
                .foregroundStyle(HUDPalette.muted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 8)
        .frame(width: Self.width, height: 46)
        .classicPanel(corner: 8)
        .accessibilityElement(children: .combine)
    }
}

struct EVAWarning: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: HUDFont.small, weight: .semibold))
            .foregroundStyle(Color(red: 0xF7 / 255, green: 0xC1 / 255, blue: 0xC1 / 255))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: EVAStatusPanel.width)
            .fixedSize(horizontal: true, vertical: false)
            .classicPanel(corner: 7, fill: Color(red: 0x3A / 255, green: 0x12 / 255, blue: 0x12 / 255).opacity(0.92),
                          stroke: Color(red: 0xE2 / 255, green: 0x4B / 255, blue: 0x4A / 255))
    }
}

struct EVAFuelPanel: View {
    let state: EVAHUDState

    var body: some View {
        let tint = state.fuelLow ? HUDPalette.accent : HUDPalette.green
        VStack(alignment: .leading, spacing: 5) {
            Text("Ранец · " + HUDFormat.percent(Double(state.fuelPercent) / 100))
                .font(.system(size: HUDFont.small, weight: .bold).monospacedDigit())
                .foregroundStyle(state.fuelLow ? HUDPalette.accent : HUDPalette.text)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                GeometryReader { geo in
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(state.fuelPercent) / 100)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 10)
        .frame(width: 150, height: 40)
        .classicPanel(corner: 8, stroke: state.fuelLow ? HUDPalette.accent : HUDPalette.stroke)
        .accessibilityElement(children: .combine)
    }
}

/// «Ранец»: включён — зелёная рамка и текст; выключен — обычная и рядом приглушённое «выкл».
struct EVAJetpackButton: View {
    let state: EVAHUDState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                Text("Ранец")
                    .font(.system(size: HUDFont.small, weight: .bold))
                    .foregroundStyle(state.jetpackOn ? HUDPalette.green : HUDPalette.text)
                    .frame(width: 70, height: 30)
                    .classicPanel(corner: 7, stroke: state.jetpackOn ? HUDPalette.green : HUDPalette.stroke)
                    .frame(height: HUDStyle.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityLabel("Ранец")
            .accessibilityValue(state.jetpackOn ? "включён" : "выключен")
            if !state.jetpackOn {
                Text("выкл")
                    .font(.system(size: HUDFont.caption))
                    .foregroundStyle(HUDPalette.muted)
            }
        }
        .frame(height: HUDStyle.minTouch)
    }
}

/// Кнопка действия 86 × 44.
struct EVAButton: View {
    let title: String
    var muted = false
    let action: () -> Void

    static let width: CGFloat = 86
    static let height: CGFloat = HUDStyle.minTouch

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: HUDFont.body, weight: .bold))
                .foregroundStyle(muted ? HUDPalette.muted : HUDPalette.text)
                .frame(width: Self.width, height: Self.height)
                .classicPanel(corner: 8)
                .opacity(muted ? 0.7 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(title)
    }
}

/// «Вниз» / «Вверх»: тяга ранца, пока палец на кнопке.
struct EVAHoldButton: View {
    let title: String
    var muted = false
    let onPress: (Bool) -> Void

    @GestureState private var pressed = false

    var body: some View {
        Text(title)
            .font(.system(size: HUDFont.body, weight: .bold))
            .foregroundStyle(pressed ? Color.black : (muted ? HUDPalette.muted : HUDPalette.text))
            .frame(width: EVAButton.width, height: EVAButton.height)
            .classicPanel(corner: 8, fill: pressed ? HUDPalette.green : HUDPalette.panel)
            .opacity(muted ? 0.7 : 1)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
            .onChange(of: pressed) { _, value in onPress(value && !muted) }
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
    }
}

/// «В капсулу» 120 × 44: оранжевая, когда можно войти; иначе тёмная с подписью «ближе 2 м».
struct EVABoardButton: View {
    let canBoard: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if canBoard {
                    Text("В капсулу")
                        .font(.system(size: HUDFont.body, weight: .heavy))
                        .foregroundStyle(HUDPalette.accentText)
                } else {
                    VStack(spacing: 0) {
                        Text("В капсулу")
                            .font(.system(size: HUDFont.body, weight: .bold))
                        Text("ближе \(Int(EVABalance.boardRadius)) м")
                            .font(.system(size: HUDFont.caption))
                    }
                    .foregroundStyle(HUDPalette.muted)
                }
            }
            .frame(width: 120, height: HUDStyle.minTouch)
            .background(canBoard ? HUDPalette.accent : HUDPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(canBoard ? HUDPalette.accent : HUDPalette.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel("В капсулу")
        .accessibilityValue(canBoard ? "доступно" : "подойдите ближе")
    }
}
