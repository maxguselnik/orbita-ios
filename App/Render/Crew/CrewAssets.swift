import CoreGraphics
import Foundation
import RealityKit
import UIKit

/// Описание материала портрета; одинаковые описания — один общий материал (кэш на всё приложение).
struct CrewMat: Hashable {
    var color: UInt32
    var rough: Float = 0.6
    var metal: Float = 0
    var coat: Float = 0
    var coatRough: Float = 0
    var emissive: UInt32 = 0
    var glow: Float = 0
    var opacity: Float = 1
    /// Ключ текстуры цвета (`CrewAssets.texture`).
    var tex: String?
    /// Без освещения (MeshBasicMaterial макета).
    var unlit = false
    /// Прозрачность — из альфы текстуры (мягкие пятна, копоть, Френель).
    var alphaTex = false
}

/// Текстуры (канва макета → CGContext → `TextureResource`) и кэш материалов портретов.
/// Текстуры готовятся асинхронно один раз; персонажи строятся после `prepare`.
@MainActor
final class CrewAssets {
    static let shared = CrewAssets()

    private var textures: [String: TextureResource] = [:]
    private var materials: [CrewMat: any Material] = [:]
    private var common: Task<Void, Never>?

    func texture(_ key: String) -> TextureResource? { textures[key] }
    var textureCount: Int { textures.count }
    /// Диагностика загрузки текстур (галерея CI).
    private(set) var failures = 0
    private(set) var lastError = ""
    /// Сколько текстур начато и какая создаётся сейчас (поиск зависания).
    private(set) var started = 0
    private(set) var current = ""

    /// Общие текстуры + текстуры персонажа (радужка, нашивка, бирка, голова).
    func prepare(id: String, name: String) async {
        if common == nil {
            common = Task { await self.loadCommon() }
        }
        await common?.value
        let look = CrewLook.of(id)
        await ensure(Self.irisKey(look.iris)) { Self.irisImage(look.iris) }
        await ensure(Self.patchKey(look.suit)) { Self.patchImage(look.suit) }
        await ensure(Self.tagKey(name)) { Self.labelImage(Self.tagText(name), fg: 0x20242e, bg: 0xe7ebf2) }
        await ensure(Self.headKey(look.kind)) { Self.headImage(look.shape) }
    }

    private func loadCommon() async {
        await ensure("spot") { Self.spotImage() }
        await ensure("soot") { Self.sootImage() }
        await ensure("hairTube") { Self.hairTubeImage() }
        await ensure("hairCap") { Self.hairCapImage() }
        await ensure("hole") { Self.holeImage() }
        await ensure("fresnel") { Self.fresnelImage() }
        await ensure("o2") { Self.labelImage("O₂ 98%", fg: 0x7ce38b, bg: 0x081a10) }
        for k in 0..<3 { await ensure("screen\(k)") { Self.screenImage(k) } }
        for (k, s) in Self.panelLabels.enumerated() { await ensure("panel\(k)") { Self.labelImage(s, fg: 0xcfe8d6, bg: 0x0f2a1c) } }
    }

    private func ensure(_ key: String, _ draw: () -> CGImage?) async {
        guard textures[key] == nil else { return }
        guard let cg = draw() else {
            failures += 1
            lastError = "\(key): нет картинки"
            return
        }
        // Без мипмапов, как у облаков: текстуры маленькие, а генерация мипмапов на симуляторе может не завершаться.
        var options = TextureResource.CreateOptions(semantic: .color)
        options.mipmapsMode = .none
        started += 1
        current = key
        if let t = await Self.makeTexture(cg, options: options, timeout: .seconds(2)) {
            textures[key] = t
        } else {
            failures += 1
            lastError = "\(key): не создалась за 2 с"
        }
        current = 
    }

    /// Флаг «ответ уже отдан» для гонки создания текстуры с таймаутом.
    @MainActor private final class Once {
        var done = false
    }

    /// Создание текстуры с таймаутом: на симуляторе CI отдельные `TextureResource(image:)` не завершаются —
    /// такая текстура пропускается, остальные идут дальше (материал без неё — запасной цвет).
    private static func makeTexture(_ cg: CGImage, options: TextureResource.CreateOptions,
                                    timeout: Duration) async -> TextureResource? {
        await withCheckedContinuation { (cont: CheckedContinuation<TextureResource?, Never>) in
            let once = Once()
            Task { @MainActor in
                let t = try? await TextureResource(image: cg, options: options)
                guard !once.done else { return }
                once.done = true
                cont.resume(returning: t)
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !once.done else { return }
                once.done = true
                cont.resume(returning: nil)
            }
        }
    }

    // MARK: - Ключи

    static let panelLabels = ["ПИТ", "СВЯЗЬ", "O2", "СТУП", "РСУ", "SAS"]
    static func irisKey(_ c: CrewColor) -> String { "iris\(c.hex)" }
    static func patchKey(_ c: CrewColor) -> String { "patch\(c.hex)" }
    static func tagKey(_ name: String) -> String { "tag:" + name }
    static func headKey(_ k: CrewKind) -> String { "head:" + k.rawValue }
    static func tagText(_ name: String) -> String { name.isEmpty ? "НОВИЧОК" : name.uppercased() }

    // MARK: - Материалы

    func material(_ s: CrewMat) -> any Material {
        if let m = materials[s] { return m }
        let tex = s.tex.flatMap { textures[$0] }
        let m: any Material
        if s.unlit {
            var u = UnlitMaterial(color: CrewColor(s.color).ui)
            if let tex { u.color = .init(tint: CrewColor(s.color).ui, texture: .init(tex)) }
            if s.alphaTex, let tex {
                u.blending = .transparent(opacity: .init(scale: s.opacity, texture: .init(tex)))
            } else if s.alphaTex {
                // Текстура ещё не загружена — не показывать (иначе глухой диск вместо стекла).
                u.blending = .transparent(opacity: .init(floatLiteral: 0))
            } else if s.opacity < 1 {
                u.blending = .transparent(opacity: .init(floatLiteral: s.opacity))
            }
            m = u
        } else {
            var p = PhysicallyBasedMaterial()
            p.baseColor = .init(tint: CrewColor(s.color).ui, texture: tex.map { MaterialParameters.Texture($0) })
            p.roughness = .init(floatLiteral: s.rough)
            p.metallic = .init(floatLiteral: s.metal)
            if s.coat > 0 {
                p.clearcoat = .init(floatLiteral: s.coat)
                p.clearcoatRoughness = .init(floatLiteral: s.coatRough)
            }
            if s.glow > 0 {
                p.emissiveColor = .init(color: CrewColor(s.emissive).ui)
                p.emissiveIntensity = s.glow
            }
            if s.opacity < 1 { p.blending = .transparent(opacity: .init(floatLiteral: s.opacity)) }
            m = p
        }
        // Материал без нужной текстуры не кэшируется: после загрузки текстур места пересобираются.
        if s.tex == nil || tex != nil { materials[s] = m }
        return m
    }

    // MARK: - Рисование

    /// Явный RGBA8 sRGB с премультиплицированной альфой (как у текстур облаков): формат UIGraphicsImageRenderer
    /// `TextureResource` не принимал. Начало координат — сверху слева, как в UIKit; текст рисуется через UIKit.
    private static func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        g.translateBy(x: 0, y: CGFloat(h))
        g.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(g)
        body(g)
        UIGraphicsPopContext()
        return g.makeImage()
    }

    private static func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { CrewColor.ui(CrewColor(hex).srgb, alpha: a).cgColor }
    private static func rgba(_ c: F3, _ a: CGFloat = 1) -> CGColor { CrewColor.ui(c, alpha: a).cgColor }

    private static func radial(_ g: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c0: CGColor, _ c1: CGColor) {
        guard r > 0, let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c0, c1] as CFArray,
                                           locations: [0, 1]) else { return }
        g.drawRadialGradient(grad, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                             endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
    }

    private static func linear(_ g: CGContext, from: CGPoint, to: CGPoint, _ stops: [(CGFloat, CGColor)]) {
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map(\.1) as CFArray,
                                    locations: stops.map(\.0)) else { return }
        g.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Попиксельная текстура: (u, v) в 0…1 по строкам сверху вниз → sRGB + альфа.
    private static func pixels(_ w: Int, _ h: Int, _ f: (Float, Float) -> SIMD4<Float>) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for j in 0..<h {
            for i in 0..<w {
                let c = f((Float(i) + 0.5) / Float(w), (Float(j) + 0.5) / Float(h))
                let a = min(1, max(0, c.w))
                let o = (j * w + i) * 4
                bytes[o] = UInt8(min(1, max(0, c.x)) * a * 255)
                bytes[o + 1] = UInt8(min(1, max(0, c.y)) * a * 255)
                bytes[o + 2] = UInt8(min(1, max(0, c.z)) * a * 255)
                bytes[o + 3] = UInt8(a * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Мягкое пятно (румянец, боке, дым).
    private static func spotImage() -> CGImage? {
        pixels(64, 64) { u, v in
            let dx = u * 2 - 1, dy = v * 2 - 1
            return SIMD4(1, 1, 1, max(0, 1 - (dx * dx + dy * dy).squareRoot()))
        }
    }

    private static func sootImage() -> CGImage? {
        draw(128, 128) { g in
            for i in 0..<70 {
                let fi = CGFloat(i)
                let x = 64 + cos(fi * 2.4) * (fi * 0.7), y = 64 + sin(fi * 1.7) * (fi * 0.55)
                radial(g, x, y, 18 - fi * 0.15, rgba(0x141414, 0.35), rgba(0x141414, 0))
            }
        }
    }

    /// Радужка в полярных координатах: x — угол, y — от зрачка к краю.
    private static func irisImage(_ c: CrewColor) -> CGImage? {
        let base = c.srgb
        return draw(256, 64) { g in
            let w: CGFloat = 256, h: CGFloat = 64
            linear(g, from: .zero, to: CGPoint(x: 0, y: h), [
                (0, rgba(base + (CrewColor(0xffe2a0).srgb - base) * 0.45)),
                (0.35, rgba(base)),
                (0.82, rgba(base * 0.7)),
                (1, rgba(base * 0.25)),
            ])
            for i in 0..<140 {
                let x = (CGFloat(i) * 37.3).truncatingRemainder(dividingBy: w)
                let a = 0.08 + CGFloat(i % 5) * 0.04
                g.setStrokeColor(i % 3 != 0 ? rgba(0xffffff, a) : rgba(0x000000, a))
                g.setLineWidth(CGFloat(1 + i % 2))
                g.move(to: CGPoint(x: x, y: h * 0.12))
                g.addLine(to: CGPoint(x: x + sin(CGFloat(i)) * 4, y: h * 0.9))
                g.strokePath()
            }
        }
    }

    /// Пряди: волоски вдоль трубки, у корня темнее.
    private static func hairTubeImage() -> CGImage? {
        draw(128, 128) { g in
            g.setFillColor(rgba(0xd0d0d0))
            g.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            for i in 0..<90 {
                let y = (CGFloat(i) * 13.7).truncatingRemainder(dividingBy: 128)
                g.setFillColor(i % 2 == 1 ? rgba(0xffffff, 0.35) : rgba(0x281e14, 0.3))
                g.fill(CGRect(x: 0, y: y, width: 128, height: CGFloat(1 + i % 3)))
            }
            linear(g, from: .zero, to: CGPoint(x: 128, y: 0), [(0, rgba(0x000000, 0.35)), (0.35, rgba(0x000000, 0))])
        }
    }

    private static func hairCapImage() -> CGImage? {
        draw(256, 128) { g in
            g.setFillColor(rgba(0xd0d0d0))
            g.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
            for i in 0..<160 {
                let x = (CGFloat(i) * 23.1).truncatingRemainder(dividingBy: 256)
                g.setFillColor(i % 2 == 1 ? rgba(0xffffff, 0.14) : rgba(0x281e14, 0.12))
                g.fill(CGRect(x: x, y: 0, width: CGFloat(1 + i % 2), height: 128))
            }
            linear(g, from: .zero, to: CGPoint(x: 0, y: 128), [(0, rgba(0x000000, 0.3)), (0.4, rgba(0x000000, 0))])
        }
    }

    /// Надпись по центру (бирка, подписи пультов).
    private static func labelImage(_ text: String, fg: UInt32, bg: UInt32) -> CGImage? {
        draw(256, 96) { g in
            g.setFillColor(rgba(bg))
            g.fill(CGRect(x: 0, y: 0, width: 256, height: 96))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 44, weight: .bold),
                .foregroundColor: CrewColor(fg).ui,
            ]
            let s = text as NSString
            let size = s.size(withAttributes: attrs)
            let scale: CGFloat = size.width > 244 ? 244 / size.width : 1
            g.saveGState()
            g.translateBy(x: 128, y: 49)
            g.scaleBy(x: scale, y: 1)
            s.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attrs)
            g.restoreGState()
        }
    }

    /// Экранчики пультов: график, орбита, цифры.
    private static func screenImage(_ k: Int) -> CGImage? {
        draw(256, 192) { g in
            let w: CGFloat = 256, h: CGFloat = 192
            switch k {
            case 0:
                g.setFillColor(rgba(0x08180f))
                g.fill(CGRect(x: 0, y: 0, width: w, height: h))
                g.setStrokeColor(rgba(0x7ce38b, 0.25))
                g.setLineWidth(1)
                for x in stride(from: CGFloat(0), to: w, by: 32) { g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: h)) }
                for y in stride(from: CGFloat(0), to: h, by: 32) { g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: w, y: y)) }
                g.strokePath()
                g.setStrokeColor(rgba(0x7ce38b))
                g.setLineWidth(4)
                for x in stride(from: CGFloat(0), through: w, by: 4) {
                    let p = CGPoint(x: x, y: h / 2 + sin(x / 22) * 40 * exp(-x / 300))
                    if x == 0 { g.move(to: p) } else { g.addLine(to: p) }
                }
                g.strokePath()
            case 1:
                g.setFillColor(rgba(0x0a1420))
                g.fill(CGRect(x: 0, y: 0, width: w, height: h))
                g.saveGState()
                g.translateBy(x: w / 2, y: h / 2)
                g.rotate(by: -0.3)
                g.setStrokeColor(rgba(0x3ec6f0))
                g.setLineWidth(4)
                g.strokeEllipse(in: CGRect(x: -90, y: -50, width: 180, height: 100))
                g.restoreGState()
                g.setFillColor(rgba(0x3ec6f0))
                g.fillEllipse(in: CGRect(x: w / 2 - 16, y: h / 2 - 16, width: 32, height: 32))
                g.setFillColor(rgba(0xf2a03d))
                g.fillEllipse(in: CGRect(x: w / 2 + 62, y: h / 2 - 48, width: 16, height: 16))
            default:
                g.setFillColor(rgba(0x14100a))
                g.fill(CGRect(x: 0, y: 0, width: w, height: h))
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 34, weight: .bold),
                    .foregroundColor: CrewColor(0xf2a03d).ui,
                ]
                for (i, s) in ["ТЯГА 100", "ТОПЛ  62", "Δv  2140"].enumerated() {
                    (s as NSString).draw(at: CGPoint(x: 18, y: 52 + CGFloat(i) * 52 - 34), withAttributes: attrs)
                }
            }
        }
    }

    /// Нашивка на плече: орбита вокруг планеты, кант цвета персонажа.
    private static func patchImage(_ c: CrewColor) -> CGImage? {
        draw(128, 128) { g in
            g.setFillColor(rgba(0x1b2233))
            g.fillEllipse(in: CGRect(x: 2, y: 2, width: 124, height: 124))
            g.setStrokeColor(rgba(c.hex))
            g.setLineWidth(8)
            g.strokeEllipse(in: CGRect(x: 8, y: 8, width: 112, height: 112))
            g.saveGState()
            g.translateBy(x: 64, y: 66)
            g.rotate(by: -0.4)
            g.setStrokeColor(rgba(0xf2f4f8))
            g.setLineWidth(4)
            g.strokeEllipse(in: CGRect(x: -42, y: -18, width: 84, height: 36))
            g.restoreGState()
            g.setFillColor(rgba(0x3ec6f0))
            g.fillEllipse(in: CGRect(x: 48, y: 50, width: 32, height: 32))
            g.setFillColor(rgba(0xffd54a))
            g.fillEllipse(in: CGRect(x: 91, y: 39, width: 14, height: 14))
        }
    }

    /// Полость рта (вершинные цвета макета): u — поперёк рта, v — от нижней кромки (низ картинки) к верхней.
    private static func holeImage() -> CGImage? {
        let a = CrewColor(0x5a1420).linear, b = CrewColor(0x12030a).linear
        return pixels(32, 16) { u, y in
            let v = 1 - y
            let edge = min(1, sin(Float.pi * u) * 1.6)
            let t = min(1, v * 1.1 + (1 - edge) * 0.3)
            let c = CrewColor.toSRGB(a + (b - a) * t)
            return SIMD4(c, 1)
        }
    }

    /// Запечённые вершинные цвета головы по UV сферы (строка — θ, столбец — φ).
    private static func headImage(_ s: CrewShape) -> CGImage? {
        pixels(128, 64) { u, v in
            let ph = u * 2 * .pi, th = v * .pi
            let d = F3(-cos(ph) * sin(th), cos(th), sin(ph) * sin(th))
            return SIMD4(CrewColor.toSRGB(s.headShade(d)), 1)
        }
    }

    /// Стекло шлема: непрозрачность по Френелю для камеры спереди (вид вдоль −Z), запечена по UV передней полусферы (φ 0…π).
    private static func fresnelImage() -> CGImage? {
        pixels(64, 64) { u, v in
            let ph = u * .pi, th = v * .pi
            let nz = sin(ph) * sin(th)
            return SIMD4(1, 1, 1, 0.03 + pow(1 - abs(nz), 2.5) * 0.55)
        }
    }
}
