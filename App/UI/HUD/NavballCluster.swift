import OrbitPhysics
import SwiftUI

/// Сторона дугового прибора на кольце навбола.
enum GaugeSide {
    case left, right
}

/// Геометрия дуг-приборов на кольце. Углы — в экранных координатах (y вниз): 0° — право, 90° — низ,
/// 180° — лево, 270° — верх. Кольцо опущено так, что его низ уходит за край экрана, поэтому дуги — в верхней
/// половине: левая от 180° (лево, «9 часов») до 250° (верх-лево), правая — зеркально: от 0° до −70°.
/// Значение 0…1 откладывается снизу вверх.
enum GaugeMath {
    static let startDegrees = 180.0
    static let spanDegrees = 70.0

    static func degrees(side: GaugeSide, fraction: Double) -> Double {
        let f = min(max(fraction, 0), 1)
        let left = startDegrees + spanDegrees * f
        switch side {
        case .left: return left
        case .right: return 180 - left
        }
    }

    static func point(center: CGPoint, radius: CGFloat, side: GaugeSide, fraction: Double) -> CGPoint {
        let radians = degrees(side: side, fraction: fraction) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(radians)),
                       y: center.y + radius * CGFloat(sin(radians)))
    }

    /// Значение левой дуги по точке касания: угол вокруг центра кольца, вне дуги прижимается к краю.
    static func fraction(forTouch point: CGPoint, center: CGPoint) -> Double {
        var degrees = atan2(Double(point.y - center.y), Double(point.x - center.x)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return min(max((degrees - startDegrees) / spanDegrees, 0), 1)
    }
}

/// Дуга от `from` до `to` (доли 0…1) радиусом `radius` вокруг центра рамки.
struct GaugeArcShape: Shape {
    var side: GaugeSide
    var from: Double = 0
    var to: Double
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard to > from else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let steps = max(2, Int(((to - from) * 32).rounded(.up)))
        for step in 0...steps {
            let f: Double = from + (to - from) * Double(step) / Double(steps)
            let p = GaugeMath.point(center: center, radius: radius, side: side, fraction: f)
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// Деления вдоль дуги: короткие радиальные штрихи.
struct GaugeTicksShape: Shape {
    var side: GaugeSide
    var count: Int
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for k in 0...count {
            let f: Double = Double(k) / Double(count)
            path.move(to: GaugeMath.point(center: center, radius: inner, side: side, fraction: f))
            path.addLine(to: GaugeMath.point(center: center, radius: outer, side: side, fraction: f))
        }
        return path
    }
}

/// Кольцо навбола (макет Б4): круг 156 pt, нижние 26 pt уходят за край экрана. Внутри — навбол, сверху — табло
/// скорости, в верхних углах — RCS (слева) и SAS со стрелкой выбора режима (справа); на кольце слева дуга тяги
/// (тянется пальцем), справа дуга перегрузки.
struct NavballCluster: View {
    let model: FlightHUDModel
    /// Помощник подъёма включён: на сфере рисуется маркер цели.
    var ascentEnabled = true
    /// Действие, которое советует помощник (подсвечивает метки MAX и 0 на дуге тяги).
    var guide: HUDAction?

    /// Диаметр кольца (−15 % от прежних 184 pt: шар, дуги и кольцо уменьшены пропорционально).
    static let size: CGFloat = 156
    /// Строка «RCS · скорость · SAS» над кольцом (зоны касания 36 pt) и полная ширина кластера.
    static let rowHeight: CGFloat = 36
    static let width: CGFloat = 196
    static let height: CGFloat = rowHeight + size
    /// Подъём кластера над нижним краем; отрицательный — низ кольца уходит за край (шар виден целиком).
    /// Интерактивное (дуга тяги, метки MAX и 0) всё равно не ближе 40 pt к низу: там системный жест «домой».
    static let lift: CGFloat = -26
    static let ballDiameter: CGFloat = 98
    /// Левый верхний угол кольца и его центр в координатах кластера.
    static let ringOrigin = CGPoint(x: (width - size) / 2, y: rowHeight)
    static let center = CGPoint(x: width / 2, y: rowHeight + size / 2)
    static let arcRadius: CGFloat = 69.5

    var body: some View {
        let t = model.telemetry
        let frame = model.speedFrame(for: t)
        ZStack(alignment: .topLeading) {
            ClusterRing()
                .frame(width: Self.size, height: Self.size)
                .position(Self.center)
            ThrottleGauge(model: model, guide: guide)
            GForceGauge(gForce: t.gForce)
            NavballSphere(telemetry: t, frame: frame,
                          targetPitch: ascentEnabled ? AscentGuide.advice(t)?.targetPitch : nil)
                .frame(width: Self.ballDiameter, height: Self.ballDiameter)
                .tutorialAnchor(.navball)
                .position(Self.center)
            ClusterRCSButton(model: model)
                .tutorialAnchor(.rcs)
                .position(x: 24, y: Self.rowHeight / 2)
            SpeedLCD(telemetry: t, frame: frame) { model.toggleSpeedFrame() }
                .tutorialAnchor(.speed)
                .position(x: Self.width / 2, y: Self.rowHeight / 2)
            ClusterSASButton(model: model)
                .tutorialAnchor(.sas)
                .position(x: Self.width - 31, y: Self.rowHeight / 2)
        }
        .frame(width: Self.width, height: Self.height)
    }
}

/// Подложка кольца: градиент, рамка и тень вверх.
struct ClusterRing: View {
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [HUDPalette.consoleTop, HUDPalette.consoleBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(HUDPalette.strokeBright, lineWidth: 1))
            .overlay(Circle().inset(by: 5).strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 8, y: -2)
    }
}

/// Табло скорости в стиле зелёного ЖК: «пов 678 м/с» / «орб 7 543 м/с». Тап — переключение системы отсчёта.
struct SpeedLCD: View {
    let telemetry: FlightTelemetry
    let frame: SpeedFrame
    let onTap: () -> Void

    var body: some View {
        let speed = frame == .orbit ? telemetry.speed : telemetry.surfaceSpeed
        let name = frame == .orbit ? "орб" : "пов"
        Button(action: onTap) {
            Text(name + " " + HUDFormat.speed(speed))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(HUDPalette.lcd)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 5)
                .frame(width: 70, height: 18)
                .background(Color(red: 0.04, green: 0.1, blue: 0.063), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(HUDPalette.strokeBright, lineWidth: 1))
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(frame == .orbit ? "Орбитальная скорость \(HUDFormat.speed(speed))"
                                            : "Скорость относительно поверхности \(HUDFormat.speed(speed))")
        .accessibilityHint("Переключить орбита или поверхность")
        .longPressHint("Скорость: орб — от центра Терры, пов — от земли. Тап переключает")
    }
}

/// RCS в левом верхнем углу кольца: зелёная, когда включено; серая и с тостом «Нет блоков РСУ», если блоков нет.
/// Под надписью — мини-шкала монотоплива (красная ниже 15 %).
struct ClusterRCSButton: View {
    let model: FlightHUDModel

    var body: some View {
        let rcs = model.rcs
        let on = rcs.enabled
        Button {
            model.toggleRCS()
        } label: {
            Text("RCS")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(on ? Color.white : HUDPalette.muted)
                .offset(y: rcs.available ? -2 : 0)
                .frame(width: 44, height: 22)
                .background(on ? HUDPalette.greenDark : HUDPalette.stroke,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(rcs.firing ? HUDPalette.lcd : Color.clear, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    if rcs.available {
                        MonoStrip(fraction: rcs.monoFraction)
                            .padding(.bottom, 3)
                    }
                }
                .opacity(rcs.available || on ? 1 : 0.55)
                .frame(width: 48, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(on ? "Выключить РСУ" : "Включить РСУ")
        .accessibilityValue(rcs.available ? "монотоплива \(HUDFormat.percent(rcs.monoFraction))" : "нет блоков")
        .longPressHint("РСУ — малые двигатели для точных сдвигов и стыковки")
    }
}

/// Шкала монотоплива 28 × 3 pt.
struct MonoStrip: View {
    let fraction: Double

    var body: some View {
        let level = CGFloat(min(max(fraction.isFinite ? fraction : 0, 0), 1))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.18))
            Capsule()
                .fill(fraction < 0.15 ? Color.red : HUDPalette.green)
                .frame(width: 28 * level)
        }
        .frame(width: 28, height: 3)
    }
}

/// SAS в правом верхнем углу кольца: тап по «SAS» — вкл/выкл (зелёная, когда включён; при режиме не «держать»
/// вместо надписи — его краткое имя), стрелка ▾ открывает сетку режимов.
struct ClusterSASButton: View {
    let model: FlightHUDModel

    @State private var picking = false

    var body: some View {
        let current = model.sas
        let on = current != .off
        let title = on && current != .hold ? SASGrid.shortName(current) : "SAS"
        HStack(spacing: 0) {
            Button {
                model.toggleSAS()
            } label: {
                Text(title)
                    .font(.system(size: 9, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(on ? Color.white : HUDPalette.muted)
                    .frame(width: 38, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityLabel(on ? "Выключить SAS, сейчас: " + SASGrid.fullName(current) : "Включить SAS")
            .longPressHint("SAS — автопилот: сам держит нос, куда вы указали")

            Button {
                picking = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(on ? Color.white : HUDPalette.muted)
                    .frame(width: 24, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityLabel("Режим SAS: " + (on ? SASGrid.fullName(current) : "выключен"))
            .longPressHint("▾ — режим SAS: держать, прогрейд, ретро, узел…")
            .accessibilityHint("Выбрать режим")
            .popover(isPresented: $picking, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("РЕЖИМ SAS")
                        .font(.system(size: 8, weight: .regular))
                        .tracking(1)
                        .foregroundStyle(HUDPalette.muted)
                    SASGrid(model: model) { picking = false }
                }
                .padding(10)
                .presentationCompactAdaptation(.popover)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(on ? HUDPalette.greenDark : HUDPalette.stroke)
                .frame(height: 22)
        }
        .overlay {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: 1, height: 22)
                .offset(x: 7)
                .allowsHitTesting(false)
        }
    }
}

/// Дуга тяги слева на кольце: оранжевое заполнение и кружок-ручка. Тяга задаётся перетаскиванием по дуге
/// (вверх — больше). РДТТ горит на 100 % и не регулируется.
struct ThrottleGauge: View {
    let model: FlightHUDModel
    var guide: HUDAction?

    /// Центры меток MAX и 0 в координатах кластера: слева от дуги, зона касания 44 pt. Метка 0 — чуть выше начала
    /// дуги, чтобы её зона не опускалась ближе 40 pt к низу экрана; MAX — под кнопкой RCS, без пересечения с ней.
    static var maxLabelCenter: CGPoint { CGPoint(x: NavballCluster.ringOrigin.x - 8, y: NavballCluster.ringOrigin.y + 22) }
    static var zeroLabelCenter: CGPoint { CGPoint(x: NavballCluster.ringOrigin.x - 8, y: NavballCluster.ringOrigin.y + 68) }
    static let labelTouch = CGSize(width: 44, height: 44)
    /// Центр подписи «ТЯГА N %».
    static var captionCenter: CGPoint { CGPoint(x: NavballCluster.ringOrigin.x - 12, y: NavballCluster.ringOrigin.y + 45) }
    /// Радиус ручки.
    static let knobRadius: CGFloat = 7

    /// Рамка для обучения: дуга тяги вместе с метками MAX и 0 (координаты кластера).
    static var lessonRect: CGRect {
        CGRect(x: NavballCluster.ringOrigin.x - 30, y: NavballCluster.ringOrigin.y, width: 94, height: 92)
    }

    /// Зона касания дуги в координатах кластера: от верхнего до нижнего конца дуги (и 12 pt ниже «9 часов»), ниже — ничего.
    static var touchRect: CGRect {
        CGRect(x: NavballCluster.ringOrigin.x - 4, y: NavballCluster.ringOrigin.y + 3, width: 64, height: 87)
    }

    var body: some View {
        let locked = model.solidLocked
        let value: Double = locked ? 1 : min(max(model.throttle, 0), 1)
        let center = NavballCluster.center
        let radius = NavballCluster.arcRadius
        let size = NavballCluster.size
        let knob = GaugeMath.point(center: center, radius: radius, side: .left, fraction: value)
        let touch = Self.touchRect
        let touchCenter = CGPoint(x: center.x - touch.minX, y: center.y - touch.minY)
        ZStack {
            GaugeTicksShape(side: .left, count: 7, inner: radius + 4, outer: radius + 8)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: size, height: size)
                .position(center)
            GaugeArcShape(side: .left, to: 1, radius: radius)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: size, height: size)
                .position(center)
            GaugeArcShape(side: .left, to: value, radius: radius)
                .stroke(HUDPalette.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: size, height: size)
                .position(center)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(HUDPalette.accent, lineWidth: 2))
                .frame(width: 14, height: 14)
                .position(knob)
            VStack(spacing: 0) {
                Text(locked ? "РДТТ" : "ТЯГА")
                    .foregroundStyle(HUDPalette.text)
                Text(HUDFormat.percent(value))
                    .foregroundStyle(HUDPalette.accent)
            }
            .font(.system(size: 9, weight: .heavy).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
            .position(Self.captionCenter)
            .allowsHitTesting(false)
            Color.clear
                .frame(width: touch.width, height: touch.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard !locked else { return }
                            model.throttle = GaugeMath.fraction(forTouch: drag.location, center: touchCenter)
                        }
                )
                .position(x: touch.midX, y: touch.midY)
                .accessibilityElement()
                .accessibilityLabel("Тяга")
                .accessibilityValue(locked ? "РДТТ работает на полной тяге, регулировка невозможна" : HUDFormat.percent(value))
                .accessibilityAdjustableAction { direction in
                    guard !locked else { return }
                    if direction == .increment {
                        model.throttle = min(1, model.throttle + 0.1)
                    } else if direction == .decrement {
                        model.throttle = max(0, model.throttle - 0.1)
                    }
                }
            Color.clear
                .frame(width: Self.lessonRect.width, height: Self.lessonRect.height)
                .tutorialAnchor(.throttle)
                .position(x: Self.lessonRect.midX, y: Self.lessonRect.midY)
                .allowsHitTesting(false)
            ThrottleEndLabel(title: "MAX", label: "Полная тяга", pulse: guide == .fullThrottle, enabled: !locked) {
                model.throttle = 1
            }
            .position(Self.maxLabelCenter)
            ThrottleEndLabel(title: "0", label: "Тяга ноль", pulse: guide == .zeroThrottle, enabled: !locked) {
                model.throttle = 0
            }
            .position(Self.zeroLabelCenter)
        }
    }
}

/// Метка-кнопка у конца дуги тяги: компактная капсула, зона касания 44 × 44 pt.
struct ThrottleEndLabel: View {
    let title: String
    let label: String
    var pulse = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(HUDPalette.accent)
                .frame(width: 30, height: 16)
                .background(Color.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(HUDPalette.accent.opacity(0.7), lineWidth: 1))
                .hudPulse(pulse, corner: 8)
                .frame(width: ThrottleGauge.labelTouch.width, height: ThrottleGauge.labelTouch.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
        .longPressHint(title == "MAX" ? "MAX — полная тяга" : "0 — выключить тягу")
    }
}

/// Дуга перегрузки справа на кольце: заполнение до 6 g, цвет растёт от зелёного к красному.
struct GForceGauge: View {
    let gForce: Double

    static let fullScale = 6.0

    static func fraction(_ g: Double) -> Double {
        g.isFinite ? min(max(g / fullScale, 0), 1) : 0
    }

    var body: some View {
        let center = NavballCluster.center
        let radius = NavballCluster.arcRadius
        let size = NavballCluster.size
        let value = Self.fraction(gForce)
        let color: Color = gForce >= 5 ? .red : (gForce >= 3 ? HUDPalette.advice : HUDPalette.green)
        ZStack {
            GaugeTicksShape(side: .right, count: 7, inner: radius + 4, outer: radius + 8)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: size, height: size)
                .position(center)
            GaugeArcShape(side: .right, to: 1, radius: radius)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: size, height: size)
                .position(center)
            GaugeArcShape(side: .right, to: value, radius: radius)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: size, height: size)
                .position(center)
            Text("G " + HUDFormat.fixed(gForce.isFinite ? gForce : 0, digits: 1))
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .position(x: NavballCluster.ringOrigin.x + size + 12, y: NavballCluster.ringOrigin.y + 68)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Перегрузка \(HUDFormat.fixed(gForce.isFinite ? gForce : 0, digits: 1)) g")
    }
}
