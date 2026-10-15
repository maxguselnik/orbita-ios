import Foundation
import OrbitPhysics
import simd
import UIKit

// Внешность и мимика экипажа по макету (`docs/mockups/crew-portraits.html`): `CREW`, `shapeOf`, `bumps`,
// `faceZ`, `surface`, `BASE`, `expr`. Внешность — только по `id`; неизвестный id — нейтральный персонаж.

/// Цвет из 0xRRGGBB (sRGB).
struct CrewColor: Hashable, Sendable {
    let hex: UInt32

    init(_ hex: UInt32) { self.hex = hex }

    var srgb: F3 { F3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255 }
    var ui: UIColor { Self.ui(srgb) }
    /// Линейные компоненты (как `col()` макета).
    var linear: F3 { Self.toLinear(srgb) }

    static func ui(_ c: F3, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat(min(1, max(0, c.x))), green: CGFloat(min(1, max(0, c.y))),
                blue: CGFloat(min(1, max(0, c.z))), alpha: alpha)
    }
    static func toLinear(_ c: F3) -> F3 {
        F3(lin(c.x), lin(c.y), lin(c.z))
    }
    static func toSRGB(_ c: F3) -> F3 {
        F3(enc(c.x), enc(c.y), enc(c.z))
    }
    private static func lin(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    private static func enc(_ x: Float) -> Float {
        let v = max(0, min(1, x))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    /// Цвет, умноженный на k (как Color.multiplyScalar в sRGB-пространстве three.js по hex).
    func scaled(_ k: Float) -> CrewColor { CrewColor.from(srgb * k) }
    /// Смесь в sRGB (как Color.lerp по hex).
    func mixed(_ o: CrewColor, _ t: Float) -> CrewColor { CrewColor.from(srgb + (o.srgb - srgb) * t) }

    static func from(_ c: F3) -> CrewColor {
        let r = UInt32((min(1, max(0, c.x)) * 255).rounded())
        let g = UInt32((min(1, max(0, c.y)) * 255).rounded())
        let b = UInt32((min(1, max(0, c.z)) * 255).rounded())
        return CrewColor(r << 16 | g << 8 | b)
    }
}

/// Персонаж макета: lera, anton, mira, gosha; остальное — нейтральный.
enum CrewKind: String, Sendable {
    case lera, anton, mira, gosha, neutral

    init(id: String) { self = CrewKind(rawValue: id) ?? .neutral }
}

/// Форма головы: эллипсоид (hx, hy, hz), «груша» и бугры спереди. Высота лица z(x, y) — `faceZ`.
struct CrewShape: Sendable {
    var hx: Float, hy: Float, hz: Float, pear: Float, chin: Float, cheek: Float, muzzle: Float

    static func of(_ k: CrewKind) -> CrewShape {
        switch k {
        case .lera: CrewShape(hx: 1.0, hy: 1.1, hz: 0.96, pear: -0.06, chin: 0.07, cheek: 0.07, muzzle: 0.05)
        case .anton: CrewShape(hx: 1.1, hy: 1.0, hz: 0.95, pear: 0.2, chin: 0.12, cheek: 0.05, muzzle: 0.1)
        case .mira: CrewShape(hx: 0.95, hy: 1.15, hz: 0.95, pear: -0.14, chin: 0.04, cheek: 0.05, muzzle: 0.04)
        case .gosha: CrewShape(hx: 0.93, hy: 0.98, hz: 0.95, pear: 0.08, chin: -0.03, cheek: 0.12, muzzle: 0.12)
        case .neutral: CrewShape(hx: 1, hy: 1.08, hz: 0.95, pear: 0, chin: 0.06, cheek: 0.07, muzzle: 0.06)
        }
    }

    static func g2(_ x: Float, _ y: Float, _ cx: Float, _ cy: Float, _ sx: Float, _ sy: Float) -> Float {
        let a = (x - cx) / sx, b = (y - cy) / sy
        return exp(-a * a - b * b)
    }
    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    func widen(_ y: Float) -> Float { min(1.3, max(0.75, 1 + pear * (-y / hy))) }

    func bumps(_ x: Float, _ y: Float) -> Float {
        let g = Self.g2
        return chin * g(x, y, 0, -0.8 * hy, 0.32, 0.2)
            + cheek * (g(x, y, -0.46, -0.28, 0.24, 0.2) + g(x, y, 0.46, -0.28, 0.24, 0.2))
            + muzzle * g(x, y, 0, -0.4, 0.34, 0.24)
            + 0.02 * g(x, y, 0, 0.4, 0.7, 0.12)
            - 0.035 * (g(x, y, -0.32, 0.12, 0.2, 0.16) + g(x, y, 0.32, 0.12, 0.2, 0.16))
    }

    func faceZ(_ x: Float, _ y: Float) -> Float {
        let a = x / (hx * widen(y)), b = y / hy
        let ez = hz * max(0, 1 - a * a - b * b).squareRoot()
        return ez + bumps(x, y) * Self.smooth(0, 0.5 * hz, ez)
    }

    /// Точка лица и нормаль к нему.
    func surface(_ x: Float, _ y: Float) -> (p: F3, n: F3) {
        let e: Float = 0.01
        let z = faceZ(x, y)
        let dx = (faceZ(x + e, y) - faceZ(x - e, y)) / (2 * e)
        let dy = (faceZ(x, y + e) - faceZ(x, y - e)) / (2 * e)
        return (F3(x, y, z), simd_normalize(F3(-dx, -dy, 1)))
    }

    /// Положение и поворот детали на лице (как `place`): точка + нормаль × `lift`, ось +Z — по нормали.
    func place(_ x: Float, _ y: Float, lift: Float = 0) -> (p: F3, q: simd_quatf) {
        let s = surface(x, y)
        return (s.p + s.n * lift, crewFromTo(F3(0, 0, 1), s.n))
    }

    /// Точка на «черепе» по направлению (для волос).
    func onSkull(_ d: F3, _ r: Float = 1) -> F3 {
        let n = simd_normalize(d)
        return F3(n.x * hx * widen(n.y * hy) * r, n.y * hy * r, n.z * hz * r)
    }

    /// Деформация точки единичной сферы в голову (как `headGeometry`).
    func headPoint(_ u: F3) -> F3 {
        let y = u.y * hy
        let x = u.x * hx * widen(y)
        var z = u.z * hz
        if z > 0 { z += bumps(x, y) * Self.smooth(0, 0.5 * hz, z) }
        return F3(x, y, z)
    }

    /// Вершинный цвет головы (румянец щёк и носа, тени глазниц и низа) — множитель к цвету кожи.
    func headShade(_ u: F3) -> F3 {
        let p = headPoint(u)
        let x = p.x, y = p.y
        let g = Self.g2
        let front = max(0, u.z)
        let red = front * (0.9 * (g(x, y, -0.47, -0.25, 0.2, 0.16) + g(x, y, 0.47, -0.25, 0.2, 0.16))
            + 0.6 * g(x, y, 0, -0.12, 0.12, 0.1) + 0.25 * g(x, y, 0, -0.82 * hy, 0.25, 0.14))
        let ao = 1 - front * 0.22 * (g(x, y, -0.32, 0.12, 0.16, 0.12) + g(x, y, 0.32, 0.12, 0.16, 0.12))
            - 0.35 * Self.smooth(-0.55, -0.95, u.y) * (1 - front * 0.6)
        return F3(ao * (1 - 0.02 * red), ao * (1 - 0.2 * red), ao * (1 - 0.18 * red))
    }
}

/// Внешность персонажа (цвета, размеры деталей).
struct CrewLook: Sendable {
    let kind: CrewKind
    let suit: CrewColor, skin: CrewColor, hair: CrewColor, iris: CrewColor
    let shape: CrewShape
    let nose: Float, eye: Float, brow: Float, neck: Float

    static func of(_ id: String) -> CrewLook {
        let k = CrewKind(id: id)
        let s = CrewShape.of(k)
        switch k {
        case .lera:
            return CrewLook(kind: k, suit: CrewColor(0x3e6fb0), skin: CrewColor(0xe9a985), hair: CrewColor(0x9a4a22),
                            iris: CrewColor(0x4a7a3a), shape: s, nose: 0.07, eye: 0.27, brow: 0.05, neck: 0.4)
        case .anton:
            return CrewLook(kind: k, suit: CrewColor(0xb07a3e), skin: CrewColor(0xd99772), hair: CrewColor(0x2c2a28),
                            iris: CrewColor(0x5a3a20), shape: s, nose: 0.13, eye: 0.27, brow: 0.07, neck: 0.5)
        case .mira:
            return CrewLook(kind: k, suit: CrewColor(0x4e9a5a), skin: CrewColor(0xb07455), hair: CrewColor(0x1d1b2e),
                            iris: CrewColor(0x3a2a20), shape: s, nose: 0.065, eye: 0.25, brow: 0.05, neck: 0.36)
        case .gosha:
            return CrewLook(kind: k, suit: CrewColor(0x8a5cc4), skin: CrewColor(0xf1b893), hair: CrewColor(0xe8b23a),
                            iris: CrewColor(0x2f6fb0), shape: s, nose: 0.09, eye: 0.3, brow: 0.045, neck: 0.33)
        case .neutral:
            return CrewLook(kind: k, suit: CrewColor(0x6a7a90), skin: CrewColor(0xe0a07c), hair: CrewColor(0x4a3426),
                            iris: CrewColor(0x4a3a2a), shape: s, nose: 0.07, eye: 0.27, brow: 0.05, neck: 0.4)
        }
    }
}

/// Параметры мимики и движения (`BASE` + сдвиг по характеру `expr`). Все числовые — для плавного перехода.
struct CrewFace: Sendable {
    var brow = 0.0, tilt = 0.0, eye = 1.0, open = 1.0, pupil = 1.0, smile = 0.0, mouth = 0.0, teeth = 0.0
    var shake = 0.0, freq = 0.0, float = 0.0, bounce = 0.0, blush = 0.0, sweat = 0.0, tear = 0.0, soot = 0.0
    var squash = 0.0, happy = 0.0, sparkle = 0.0, heat = 0.0, dart = 0.0
    var cross = 0.0, tongue = 0.0, dizzy = 0.0

    static func base(_ m: CrewMood) -> CrewFace {
        var p = CrewFace()
        switch m {
        case .calm:
            p.smile = 0.35
        case .strain:
            p.brow = -0.2; p.tilt = -0.8; p.eye = 0.95; p.open = 0.35; p.smile = -0.15; p.mouth = 0.3; p.teeth = 1
            p.shake = 0.45; p.freq = 38; p.blush = 0.7; p.sweat = 0.6; p.squash = 0.14
        case .awe:
            p.brow = 0.9; p.tilt = 0.1; p.eye = 1.25; p.open = 1.15; p.pupil = 1.2; p.smile = 0.45; p.mouth = 0.55
            p.float = 1; p.blush = 0.3; p.sparkle = 1
        case .panic:
            p.brow = 0.8; p.tilt = 0.9; p.eye = 1.35; p.open = 1.3; p.pupil = 0.45; p.smile = -0.7; p.mouth = 1
            p.shake = 1; p.freq = 52; p.sweat = 1; p.heat = 1; p.dart = 1
        case .joy:
            p.brow = 0.5; p.smile = 1; p.mouth = 0.75; p.teeth = 1; p.bounce = 1; p.blush = 0.9; p.happy = 1
        case .crash:
            p.brow = 0.3; p.tilt = 0.85; p.eye = 1.05; p.open = 0.85; p.pupil = 0.8; p.smile = -0.8; p.mouth = 0.15
            p.shake = 0.12; p.freq = 9; p.tear = 1; p.soot = 1
        }
        return p
    }

    /// Мимика по настроению и характеру (храбрость `b`, глупость `s`).
    static func expr(_ mood: CrewMood, brave b: Double, silly s: Double) -> CrewFace {
        var p = base(mood)
        switch mood {
        case .panic:
            p.shake *= 1 - 0.55 * b
            p.tilt = p.tilt * (1 - b) - 0.7 * b
            p.mouth *= 1 - 0.7 * b
            p.teeth = b > 0.5 ? 1 : 0
            p.eye -= 0.3 * b
            p.open -= 0.45 * b
            p.smile += 1.3 * s
        case .strain:
            p.eye += 0.35 * (1 - b)
            p.open += 0.7 * (1 - b)
            p.smile += 0.7 * s
            p.shake *= 1.3 - 0.5 * b
        case .crash:
            p.tear *= 1 - 0.8 * b
            p.tilt -= 0.5 * b
            p.dizzy = s
            p.smile += 1.4 * s
            p.open -= 0.3 * s
        case .awe:
            p.tongue = s > 0.55 ? 1 : 0
            p.eye += 0.15 * s
        case .calm:
            p.smile += 0.25 * s
            p.tongue = s > 0.8 ? 1 : 0
        case .joy:
            p.mouth += 0.2 * s
        }
        p.cross = max(0, s - 0.4) * 1.6
        p.smile = max(-1, min(1, p.smile))
        p.open = max(0.15, p.open)
        return p
    }

    func lerp(_ o: CrewFace, _ k: Double) -> CrewFace {
        func m(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        var r = CrewFace()
        r.brow = m(brow, o.brow); r.tilt = m(tilt, o.tilt); r.eye = m(eye, o.eye); r.open = m(open, o.open)
        r.pupil = m(pupil, o.pupil); r.smile = m(smile, o.smile); r.mouth = m(mouth, o.mouth); r.teeth = m(teeth, o.teeth)
        r.shake = m(shake, o.shake); r.freq = m(freq, o.freq); r.float = m(float, o.float); r.bounce = m(bounce, o.bounce)
        r.blush = m(blush, o.blush); r.sweat = m(sweat, o.sweat); r.tear = m(tear, o.tear); r.soot = m(soot, o.soot)
        r.squash = m(squash, o.squash); r.happy = m(happy, o.happy); r.sparkle = m(sparkle, o.sparkle)
        r.heat = m(heat, o.heat); r.dart = m(dart, o.dart); r.cross = m(cross, o.cross); r.tongue = m(tongue, o.tongue)
        r.dizzy = m(dizzy, o.dizzy)
        return r
    }
}

extension CrewMood {
    /// Фон кабины (`BG` макета).
    var portraitBackdrop: CrewColor {
        switch self {
        case .calm: CrewColor(0x1a2232)
        case .strain: CrewColor(0x2a1a1c)
        case .awe: CrewColor(0x070b1c)
        case .panic: CrewColor(0x3a1212)
        case .joy: CrewColor(0x173826)
        case .crash: CrewColor(0x26262a)
        }
    }
    /// Цвет тумана: фон, чуть разбавленный серо-синим.
    var portraitFog: CrewColor { portraitBackdrop.mixed(CrewColor(0x55607a), 0.08) }
}
