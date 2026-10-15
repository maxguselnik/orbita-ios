import OrbitPhysics
import SwiftUI

/// Космоцентр: 3D-сцена с зданиями на весь экран, подписи-кнопки у зданий, сверху режим и наука.
struct SpaceCenterView: View {
    let flow: GameFlow
    let scene: SpaceCenterScene
    let settings: GameSettings

    @State private var projectCount = 0
    @State private var toast: String?
    @State private var toastID = 0
    @State private var showMenu = false
    @State private var showLessons = false
    @State private var showNewGame = false
    @State private var showTutorialOffer = false

    var body: some View {
        ZStack {
            world
            topBar
            if let toast {
                Text(toast)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .hudBackground(Color.black.opacity(0.85), corner: 10)
                    .frame(maxWidth: 420)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            overlays
        }
        .background(.black)
        .animation(.easeOut(duration: 0.2), value: toast)
        .onAppear {
            projectCount = ShipStore.list().count
            if !TutorialProgress.wasOffered, DemoScenario.fromArguments == nil { showTutorialOffer = true }
            updateHighlight()
        }
        .onChange(of: flow.progress) { updateHighlight() }
    }

    // MARK: - Мир

    private var world: some View {
        GeometryReader { geo in
            ZStack {
                SpaceCenterSceneView(scene: scene)
                SpaceCenterGestureLayer(scene: scene, size: geo.size) { building in activate(building) }
                labels(size: geo.size)
            }
        }
        .ignoresSafeArea()
    }

    private func labels(size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            ZStack {
                ForEach(Building.allCases, id: \.self) { building in
                    if let point = scene.labelPoint(of: building, viewSize: size) {
                        BuildingLabel(building: building,
                                      status: SpaceCenterLogic.status(of: building, progress: flow.progress,
                                                                      projectCount: projectCount),
                                      action: { activate(building) })
                            .position(point)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func updateHighlight() {
        let available = flow.progress.map { $0.mode != .sandbox && SpaceCenterLogic.researchableCount($0) > 0 } ?? false
        scene.highlight(available ? .research : nil)
    }

    // MARK: - Действия

    private func activate(_ building: Building) {
        guard flow.progress != nil else { return }
        let status = SpaceCenterLogic.status(of: building, progress: flow.progress, projectCount: projectCount)
        guard status.isActive else {
            show(SpaceCenterLogic.comingText(building))
            return
        }
        switch building {
        case .hangar: flow.open(.hangar)
        case .research: flow.open(.research)
        case .launchPad:
            if let message = SpaceCenterLogic.launchBlock(design: flow.design, locked: flow.lockedParts) {
                show(message)
            } else {
                flow.launch()
            }
        case .missionControl, .astronauts, .tracking:
            show(SpaceCenterLogic.comingText(building))
        }
    }

    private func show(_ text: String) {
        toast = text
        toastID += 1
        let id = toastID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if toastID == id { toast = nil }
        }
    }

    // MARK: - Верхняя полоса

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("КОСМОЦЕНТР")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
            if let progress = flow.progress {
                chip(progress.mode.title)
                if progress.mode != .sandbox {
                    chip("⚛ \(progress.science)", accent: true)
                }
            }
            Spacer(minLength: 0)
            Button { showMenu = true } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .bold))
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Меню: настройки и обучение")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .hudBackground()
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func chip(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundStyle(accent ? HUDStyle.accent : Color.white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.white.opacity(0.12), in: Capsule())
            .accessibilityLabel(text)
    }

    // MARK: - Окна

    @ViewBuilder private var overlays: some View {
        if flow.progress == nil || showNewGame {
            NewGamePanel(canCancel: flow.progress != nil,
                         onStart: { mode in
                             flow.startNewGame(mode)
                             showNewGame = false
                         },
                         onCancel: { showNewGame = false })
        } else if showLessons {
            dimmed(onTap: { showLessons = false }) {
                TutorialListPanel(context: .hangar,
                                  onStart: { id in
                                      showLessons = false
                                      flow.startTutorial(id)
                                  },
                                  onClose: { showLessons = false })
            }
        } else if showMenu {
            dimmed(onTap: { showMenu = false }) {
                GameMenuPanel(settings: settings,
                              onLessons: { showMenu = false; showLessons = true },
                              onNewGame: { showMenu = false; showNewGame = true },
                              onClose: { showMenu = false })
            }
        } else if showTutorialOffer {
            dimmed(onTap: {}) { tutorialOffer }
        }
    }

    private func dimmed<Content: View>(onTap: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onTap)
            content()
        }
    }

    /// Карточка-предложение урока при первом запуске.
    private var tutorialOffer: some View {
        VStack(spacing: 10) {
            Text(TutorialID.firstFlight.title)
                .font(.system(size: 20, weight: .heavy))
            Text("Научим выходить на орбиту за 5 минут")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(HUDStyle.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Позже") {
                    TutorialProgress.markOffered()
                    showTutorialOffer = false
                }
                .buttonStyle(HUDButtonStyle())
                Button("Начать") {
                    TutorialProgress.markOffered()
                    showTutorialOffer = false
                    flow.startTutorial(.firstFlight)
                }
                .buttonStyle(HUDButtonStyle(isActive: true))
            }
            .font(.system(size: 16, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(width: 340)
        .hudBackground(Color.black.opacity(0.85), corner: 18)
    }
}

/// Подпись-кнопка здания: название и строка состояния; неактивные серые.
struct BuildingLabel: View {
    let building: Building
    let status: SpaceCenterLogic.Status
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(building.title)
                    .font(.system(size: 12, weight: .heavy))
                    .lineLimit(1)
                if !status.subtitle.isEmpty {
                    Text(status.subtitle)
                        .font(.system(size: HUDFont.caption, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 40)
            .background(Color.black.opacity(status.isActive ? 0.72 : 0.55),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(status.isAccent ? HUDStyle.active : HUDStyle.stroke, lineWidth: status.isAccent ? 2 : 1))
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(building.title + (status.subtitle.isEmpty ? "" : ", " + status.subtitle))
    }

    private var foreground: Color {
        if !status.isActive { return Color.white.opacity(0.45) }
        return status.isAccent ? HUDStyle.active : Color.white
    }
}

/// Жесты облёта: палец вращает, щипок приближает; тап — здание под пальцем.
struct SpaceCenterGestureLayer: View {
    let scene: SpaceCenterScene
    let size: CGSize
    let onBuilding: (Building) -> Void

    private static let radiansPerPoint: Float = 0.006

    @State private var tracker = Tracker()

    final class Tracker {
        var last: CGSize = .zero
        var magnification: CGFloat?
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = tracker
                        let dx = Float(value.translation.width - t.last.width)
                        let dy = Float(value.translation.height - t.last.height)
                        t.last = value.translation
                        if t.magnification == nil {
                            scene.apply(CameraInput(orbitDelta: SIMD2(-dx, dy) * Self.radiansPerPoint))
                        }
                    }
                    .onEnded { value in
                        tracker.last = .zero
                        let moved = hypot(value.translation.width, value.translation.height)
                        if moved < 8, let building = scene.pickBuilding(at: value.location, viewSize: size) {
                            onBuilding(building)
                        }
                    }
            )
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.01)
                    .onChanged { value in
                        let m = value.magnification
                        if let last = tracker.magnification, m > 0 {
                            let factor = Float(last / m)
                            if factor.isFinite, factor > 0 { scene.apply(CameraInput(zoomFactor: factor)) }
                        }
                        tracker.magnification = m
                    }
                    .onEnded { _ in tracker.magnification = nil }
            )
            .accessibilityHidden(true)
    }
}
