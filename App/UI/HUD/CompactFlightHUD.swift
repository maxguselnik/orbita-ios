import OrbitPhysics
import SwiftUI

/// Макет compact-flight-hud.html, согласован 2026-10-16. Координаты от физических краёв.
enum CompactFlightLayout {
    static let side: CGFloat = 59
    static let bottom: CGFloat = 25
    static let headerHeight: CGFloat = 44
    static let instrumentsWidth: CGFloat = 218
    static let controlsWidth: CGFloat = 220
    static let panelWidth: CGFloat = 244
}

enum CompactFlightPage { case summary, stages, science, crew }

struct CompactFlightLayer: View {
    let model: FlightHUDModel
    var guide: HUDAction?
    var hintsEnabled: Bool
    @State private var page: CompactFlightPage

    init(model: FlightHUDModel, guide: HUDAction? = nil, hintsEnabled: Bool = true, initialPage: CompactFlightPage = .summary) {
        self.model = model
        self.guide = guide
        self.hintsEnabled = hintsEnabled
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if model.isFlightOverview {
                    Button("Вернуть приборы") { model.setFlightOverview(false) }
                        .buttonStyle(CompactFlightButtonStyle())
                        .padding(.top, 8)
                        .padding(.trailing, CompactFlightLayout.side)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    CompactFlightHeader(model: model, wide: geo.size.width >= 800, showCrew: {
                        page = .crew
                        model.isPanelOpen = true
                    }, showMore: {
                        page = .summary
                        model.isPanelOpen.toggle()
                    })
                        .padding(.horizontal, CompactFlightLayout.side)
                        .padding(.top, 8)
                    ThermalGauge(model: model)
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                    CompactFlightReadings(model: model)
                        .padding(.leading, CompactFlightLayout.side + 6)
                        .padding(.top, 66)
                    HStack(alignment: .bottom) {
                        CompactFlightInstruments(model: model, guide: guide, ascentEnabled: hintsEnabled)
                        Spacer(minLength: 24)
                        if !model.isPanelOpen {
                            CompactFlightControls(model: model, guide: guide)
                        }
                    }
                    .padding(.horizontal, CompactFlightLayout.side)
                    .padding(.bottom, CompactFlightLayout.bottom)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    if model.rcs.enabled, model.rcs.available, !model.isPanelOpen {
                        RCSControls(model: model)
                            .padding(.trailing, CompactFlightLayout.side)
                            .padding(.bottom, 169)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    if model.isPanelOpen {
                        CompactFlightPanel(model: model, page: $page)
                            .frame(width: CompactFlightLayout.panelWidth)
                            .frame(maxHeight: max(120, geo.size.height - 90))
                            .padding(.top, 62)
                            .padding(.trailing, CompactFlightLayout.side)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea(.container)
        .onChange(of: model.isPanelOpen) { _, open in
            if open { model.releaseFlightControls() }
        }
    }
}

struct CompactFlightButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? HUDPalette.sas : HUDPalette.text)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background(HUDPalette.panel.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct CompactFlightHeader: View {
    let model: FlightHUDModel
    var wide = true
    var showCrew: () -> Void = {}
    var showMore: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            Button { model.pause() } label: { Image(systemName: "pause.fill").frame(width: 44, height: 44) }
                .accessibilityLabel("Пауза")
            MissionClock(model: model)
            Menu {
                if let reason = model.warp.blocked { Text(FlightHUDModel.warpReasonText(reason)) }
                if model.hasManeuver { Button("До узла манёвра") { model.warpToManeuver() }.disabled(!model.canWarpToManeuver) }
                ForEach(Array(TimeWarp.levels.enumerated()), id: \.offset) { index, factor in
                    Button(HUDFormat.warp(factor)) { model.send(.setWarp(index: index)) }
                        .disabled(model.warp.blocked != nil && index >= TimeWarp.physicalCount)
                }
            } label: {
                Text(HUDFormat.warp(model.warp.factor) + " ▾").frame(minWidth: 48, minHeight: 44)
            }
            .accessibilityLabel("Ускорение времени")
            if wide {
                Text(Bodies.body(model.telemetry.body).name + " · полёт")
                    .foregroundStyle(HUDPalette.muted).padding(.leading, 10).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(Array(model.crew.states.prefix(3))) { state in
                    Button(action: showCrew) {
                        CompactCrewPortrait(state: state, outside: model.evaOutsideIDs.contains(state.id), dead: model.evaDeadIDs.contains(state.id))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(CrewStrip.label(state, outside: model.evaOutsideIDs, dead: model.evaDeadIDs) + ". Открыть экипаж")
                }
                if model.crew.states.count > 3 {
                    Button("+\(model.crew.states.count - 3)", action: showCrew).frame(width: 44, height: 44)
                }
            }
            Button("Карта") { model.toggleMap() }.frame(width: 52, height: 44)
            Button("Обзор") { model.setFlightOverview(true) }.frame(width: 56, height: 44)
            Button("Ещё ⋯", action: showMore).frame(width: 60, height: 44)
                .accessibilityLabel(model.isPanelOpen ? "Закрыть панель корабля" : "Открыть панель корабля")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(HUDPalette.text)
        .buttonStyle(.plain)
        .frame(height: CompactFlightLayout.headerHeight)
        .classicPanel(corner: 10)
    }
}

/// Только нужные для движения величины; подробные данные находятся в панели корабля.
struct CompactFlightReadings: View {
    let model: FlightHUDModel

    var body: some View {
        let t = model.telemetry
        let landing = t.verticalSpeed < -5 && t.heightAboveTerrain < 10_000
        VStack(alignment: .leading, spacing: 4) {
            reading(HUDFormat.distance(model.altimeterOverTerrain ? t.heightAboveTerrain : t.altitude), label: "высота")
            Button { model.toggleSpeedFrame() } label: {
                reading(landing ? HUDFormat.signedSpeed(t.verticalSpeed) : HUDFormat.speed(model.speedFrame(for: t) == .orbit ? t.speed : t.surfaceSpeed),
                        label: landing ? "вертикально" : (model.speedFrame(for: t) == .orbit ? "орбитальная" : "поверхность"))
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityHint("Переключить орбитальную скорость и скорость относительно поверхности")
            if let stage = t.stages.first, stage.fuelCapacity > 0 {
                Text("Топливо · " + HUDFormat.percent(stage.fuelFraction))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(HUDPalette.green)
            }
            if let apo = AltimeterPanel.apoapsisToShow(t) {
                ApoapsisRow(altitude: apo)
            }
            if t.maneuver != nil {
                ManeuverBadgeHost(model: model)
                if model.isAutoBurning { ManeuverExecuteButton(model: model) }
            }
        }
        .foregroundStyle(HUDPalette.text)
        .shadow(color: .black, radius: 3, y: 1)
        .frame(width: 210, alignment: .leading)
    }

    private func reading(_ value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value).font(.system(size: 22, weight: .medium).monospacedDigit())
            Text(label).font(.system(size: 11)).foregroundStyle(HUDPalette.muted)
        }
    }
}

struct CompactFlightInstruments: View {
    let model: FlightHUDModel
    var guide: HUDAction?
    var ascentEnabled = true

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            CompactThrottle(model: model, guide: guide)
            NavballSphere(telemetry: model.telemetry, frame: model.speedFrame(for: model.telemetry),
                          targetPitch: ascentEnabled ? AscentGuide.advice(model.telemetry)?.targetPitch : nil)
                .frame(width: 90, height: 90)
                .background(Circle().fill(HUDPalette.panel))
                .overlay(Circle().strokeBorder(HUDPalette.strokeBright, lineWidth: 3))
            VStack(spacing: 0) {
                Menu {
                    Button(model.sas == .off ? "Включить SAS" : "Выключить SAS") { model.toggleSAS() }
                    ForEach([SASMode.hold, .prograde, .retrograde, .maneuver, .normal, .antiNormal, .radialOut, .radialIn], id: \.self) { mode in
                        Button(SASGrid.fullName(mode)) { model.send(.setSAS(mode)) }
                            .disabled(mode == .maneuver && !model.hasManeuver)
                    }
                } label: {
                    Text("SAS ▾").foregroundStyle(model.sas == .off ? HUDPalette.muted : HUDPalette.sas)
                        .frame(width: 48, height: 44)
                }
                .accessibilityLabel("SAS: " + SASGrid.fullName(model.sas))
                Button { model.toggleRCS() } label: {
                    VStack(spacing: 3) {
                        Text("РСУ")
                        if model.rcs.available { MonoStrip(fraction: model.rcs.monoFraction) }
                    }.frame(width: 48, height: 44)
                }
                .foregroundStyle(model.rcs.enabled ? HUDPalette.sas : HUDPalette.muted)
                .accessibilityLabel(model.rcs.enabled ? "Выключить РСУ" : "Включить РСУ")
            }
            .font(.system(size: 11, weight: .bold)).buttonStyle(.plain)
        }
        .frame(width: CompactFlightLayout.instrumentsWidth, alignment: .leading)
    }
}

/// Вертикальная тяга с относительным жестом: первое касание не меняет значение скачком.
struct CompactThrottle: View {
    let model: FlightHUDModel
    var guide: HUDAction?
    @State private var dragBase: Double?
    @GestureState private var dragging = false

    var body: some View {
        let value = model.solidLocked ? 1 : min(max(model.throttle, 0), 1)
        let locked = model.solidLocked
        VStack(spacing: 0) {
            ThrottleEndLabel(title: "MAX", label: "Полная тяга", pulse: guide == .fullThrottle, enabled: !locked) {
                model.throttle = 1
            }
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule().fill(HUDPalette.stroke).frame(width: 4)
                    Capsule().fill(HUDPalette.accent).frame(width: 4, height: geo.size.height * value)
                    Circle().fill(HUDPalette.accent).frame(width: 16, height: 16)
                        .position(x: geo.size.width / 2, y: 8 + (geo.size.height - 16) * (1 - value))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { drag in
                        guard !locked else { return }
                        if dragBase == nil { dragBase = model.throttle }
                        model.throttle = min(max((dragBase ?? value) - Double(drag.translation.height / max(geo.size.height - 16, 1)), 0), 1)
                    }
                    .onEnded { _ in dragBase = nil })
            }
            .frame(height: 72)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(locked ? "Тяга РДТТ не регулируется" : "Тяга")
            .accessibilityValue(HUDFormat.percent(value))
            .accessibilityAdjustableAction { direction in
                guard !locked else { return }
                switch direction {
                case .increment: model.throttle = min(1, model.throttle + 0.1)
                case .decrement: model.throttle = max(0, model.throttle - 0.1)
                @unknown default: break
                }
            }
            Text(locked ? "РДТТ" : HUDFormat.percent(value))
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .padding(.top, 2)
            ThrottleEndLabel(title: "0", label: "Тяга ноль", pulse: guide == .zeroThrottle, enabled: !locked) {
                model.throttle = 0
            }
        }
        .foregroundStyle(HUDPalette.accent)
        .padding(.vertical, 4)
        .frame(width: 52)
        .classicPanel(corner: 10)
        .onChange(of: dragging) { _, active in if !active { dragBase = nil } }
    }
}

struct CompactFlightControls: View {
    let model: FlightHUDModel
    var guide: HUDAction?

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            StageButton(model: model, compact: true, narrow: true, highlighted: guide == .stage)
                .frame(width: 120)
            VStack(spacing: 0) {
                DPadCircle(model: model, radius: 44).frame(width: 88, height: 88)
                HStack(spacing: 0) {
                    roll("arrow.counterclockwise", "Крен влево", .rollLeft)
                    roll("arrow.clockwise", "Крен вправо", .rollRight)
                }
            }
        }
        .frame(width: CompactFlightLayout.controlsWidth)
    }

    private func roll(_ symbol: String, _ label: String, _ button: AttitudeButton) -> some View {
        AttitudeHoldButton(systemImage: symbol, label: label, diameter: 44) { pressed in
            model.setAttitude(button, pressed: pressed)
        }
        .onDisappear { model.setAttitude(button, pressed: false) }
    }

}

struct CompactFlightPanel: View {
    let model: FlightHUDModel
    @Binding var page: CompactFlightPage

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                if page != .summary { Button("‹ Назад") { page = .summary }.frame(minHeight: 44) }
                Text(page == .crew ? "Экипаж" : (page == .science ? "Наука" : (page == .stages ? "Ступени" : "Корабль")))
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Button { model.isPanelOpen = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Закрыть панель корабля")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch page {
                    case .summary: summary
                    case .stages:
                        ForEach(Array(model.telemetry.stages.enumerated()), id: \.offset) { index, stage in
                            StageRow(number: index + 1, stage: stage, isCurrent: index == 0)
                        }
                    case .science: SciencePanel(model: model, singleColumn: true)
                    case .crew:
                        CompactCrewDetails(model: model)

                    }
                }
            }
        }
        .font(.system(size: 12)).foregroundStyle(HUDPalette.text).buttonStyle(.plain)
        .padding(12).classicPanel(corner: 10)
    }

    private var summary: some View {
        VStack(spacing: 5) {
            row("Текущая ступень", model.totalStages == 0 ? "—" : "\(min(model.totalStages, max(1, model.totalStages - model.stageStatus.remaining + 1))) из \(model.totalStages)")
            row("Запас Δv", HUDFormat.speed(model.telemetry.stages.reduce(0) { $0 + $1.deltaV }))
            row("Перегрузка", HUDFormat.fixed(model.telemetry.gForce, digits: 1) + " g")
            FlightStatusView(model: model, ascentEnabled: false, stacked: true)
            ThermalGauge(model: model)
            HStack {
                Button("Наука") { page = .science }.buttonStyle(CompactFlightButtonStyle())
                Button("Экипаж · \(model.crew.states.count)") { page = .crew }.buttonStyle(CompactFlightButtonStyle())
            }
            HStack {
                Button("Ступени") { page = .stages }.buttonStyle(CompactFlightButtonStyle())
                Button("Камера") { model.cycleCameraMode() }.buttonStyle(CompactFlightButtonStyle())
            }
            HStack {
                Button("Тяга MAX") { model.throttle = 1 }.disabled(model.solidLocked)
                Spacer()
                Button("Тяга 0") { model.throttle = 0 }.disabled(model.solidLocked)
            }.frame(minHeight: 44)
            Toggle("Точное управление", isOn: Binding(get: { model.fineControl }, set: { model.fineControl = $0 }))
                .frame(minHeight: 44)
            if model.showsEVASwitch { EVAModeSwitch(model: model, cosmonautSelected: false) }
            if model.showsDeployRover {
                Button("Отделить ровер") {
                    model.roverJustDeployed = true
                    model.send(.deployRover)
                    model.isPanelOpen = false
                    model.notify("Ровер отделён")
                }.buttonStyle(CompactFlightButtonStyle())
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack { Text(name).foregroundStyle(HUDPalette.muted); Spacer(); Text(value).monospacedDigit() }
            .padding(.vertical, 6)
    }
}

/// Существующие живые портреты, обрезанные кругом; состояние доступно также через VoiceOver.
struct CompactCrewPortrait: View {
    let state: CrewModel.State
    var outside = false
    var dead = false

    var body: some View {
        CrewPortraitView(states: [state])
            .frame(width: 32, height: 37)
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(dead ? Color.red : (outside ? HUDPalette.sas : HUDPalette.green), lineWidth: 1.5))
            .overlay {
                if dead {
                    Circle().fill(.black.opacity(0.6))
                    Image(systemName: "xmark").foregroundStyle(.red)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct CompactCrewDetails: View {
    let model: FlightHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.crew.states) { state in
                let outside = model.evaOutsideIDs.contains(state.id)
                let dead = model.evaDeadIDs.contains(state.id)
                HStack(spacing: 10) {
                    CompactCrewPortrait(state: state, outside: outside, dead: dead)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.member.name).fontWeight(.semibold)
                        Text(state.member.role.title).foregroundStyle(HUDPalette.muted)
                        Text(dead ? "Погиб" : (outside ? "Снаружи" : "В кабине"))
                            .foregroundStyle(dead ? Color.red : (outside ? HUDPalette.sas : HUDPalette.green))
                    }
                    Spacer(minLength: 0)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                if outside, !dead {
                    Button("Управлять · " + state.member.name) {
                        model.isPanelOpen = false
                        model.send(.evaSelect(memberID: state.id))
                    }.buttonStyle(CompactFlightButtonStyle())
                }
            }
            if model.telemetry.science.crewAboard {
                Button("Выйти") {
                    model.isPanelOpen = false
                    model.send(.evaExit)
                }
                .buttonStyle(CompactFlightButtonStyle())
                .disabled(model.evaExitBlocker != nil)
                if let reason = model.evaExitBlocker {
                    Text("Выход: " + reason.text)
                        .foregroundStyle(HUDPalette.muted).font(.system(size: 11))
                }
            }
            if model.crew.isEmpty { Text("Экипажа нет").foregroundStyle(HUDPalette.muted) }
            if model.showsEVASwitch { EVAModeSwitch(model: model, cosmonautSelected: false) }
        }
    }
}
