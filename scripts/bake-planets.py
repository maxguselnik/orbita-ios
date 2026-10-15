#!/usr/bin/env python3
"""Bake original planet textures from the game's actual terrain and palette.

Requires Swift 6 and Pillow. Run from any directory:
    SWIFTC=/path/to/swiftc python3 scripts/bake-planets.py
No physics changes, downloaded artwork, or pixel generation at game runtime.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "App/Assets.xcassets"

PORTABLE_MATH = r"""
import Foundation
typealias D3 = SIMD3<Double>
func clampd(_ x: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, x)) }
func vec3(_ v: D3) -> Vec3 { Vec3(v.x, v.y, v.z) }
func simd_dot(_ a: D3, _ b: D3) -> Double { a.x*b.x + a.y*b.y + a.z*b.z }
func simd_cross(_ a: D3, _ b: D3) -> D3 {
    D3(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x)
}
func simd_normalize(_ a: D3) -> D3 { a / sqrt(simd_dot(a, a)) }
"""

MAIN = r"""
import Foundation
let output = CommandLine.arguments[1]
for body in [BodyID.terra, .luna] {
    let name = body == .terra ? "TerraSurface" : "LunaSurface"
    let width = PlanetSurface.width, height = PlanetSurface.height
    var pixels = [UInt8](repeating: 0, count: width * height * 3)
    for face in 0..<6 {
        for j in 0..<PlanetSurface.tileSize {
            let b = 1 - 2 * (Double(j) + 0.5 - Double(PlanetSurface.gutter)) / Double(PlanetSurface.faceSize)
            for i in 0..<PlanetSurface.tileSize {
                let a = -1 + 2 * (Double(i) + 0.5 - Double(PlanetSurface.gutter)) / Double(PlanetSurface.faceSize)
                let d = CubeSphere.direction(face: face, a: a, b: b)
                let h = Terrain.height(body: body, direction: vec3(d))
                let uv = Palette.terrainUV(body: body, direction: d, height: h,
                    noise: hashNoise(d, scale: Bodies.body(body).radius / (body == .terra ? 900 : 300)),
                    craterShade: body == .luna ? Terrain.craterShade(body: body, direction: vec3(d)) : 0)
                let color: D3
                if body == .terra {
                    let zone = clampd((1 - Double(uv.y)) * Double(Palette.terraZoneCount) - 0.5,
                                      0, Double(Palette.terraZoneCount - 1))
                    let low = Int(floor(zone)), high = min(low + 1, Palette.terraZoneCount - 1)
                    let t = zone - Double(low)
                    let c0 = Palette.terraColor(zone: low, u: Double(uv.x))
                    let c1 = Palette.terraColor(zone: high, u: Double(uv.x))
                    color = c0 + (c1 - c0) * t
                } else {
                    color = D3(repeating: Palette.lunaGrey(Double(uv.x)))
                }
                let x = face % 3 * PlanetSurface.tileSize + i
                let y = face / 3 * PlanetSurface.tileSize + j
                let index = (y * width + x) * 3
                pixels[index] = UInt8((clampd(color.x, 0, 1) * 255).rounded())
                pixels[index + 1] = UInt8((clampd(color.y, 0, 1) * 255).rounded())
                pixels[index + 2] = UInt8((clampd(color.z, 0, 1) * 255).rounded())
            }
        }
        FileHandle.standardOutput.write(Data("\(name): face \(face + 1)/6\n".utf8))
    }
    var data = Data("P6\n\(width) \(height)\n255\n".utf8)
    data.append(contentsOf: pixels)
    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".ppm"))
}
"""


def portable(source):
    return "\n".join(line for line in source.splitlines() if not line.startswith("import "))


def main():
    # Reuse the current source of truth rather than keeping a second copy of geography.
    palette = (ROOT / "App/Render/Palette.swift").read_text()
    first = palette.index("    /// Изображение `width")
    last = palette.index("    // MARK: - Шум", first)
    palette = portable(palette[:first] + palette[last:])
    cube = (ROOT / "App/Render/TerrainPatch.swift").read_text().split("/// Готовая геометрия")[0]
    render_math = (ROOT / "App/Render/RenderMath.swift").read_text()
    noise = render_math[render_math.index("func hashNoise"):]
    with tempfile.TemporaryDirectory(prefix="orbita-planets-") as tmp:
        tmp = Path(tmp)
        helpers = tmp / "BakeSupport.swift"
        helpers.write_text(PORTABLE_MATH + noise + portable(cube) + palette)
        source = tmp / "main.swift"
        source.write_text(MAIN)
        executable = tmp / "bake-planets"
        physics = sorted((ROOT / "Packages/OrbitPhysics/Sources/OrbitPhysics").glob("*.swift"))
        subprocess.run([os.environ.get("SWIFTC", "swiftc"), "-O", "-swift-version", "6",
                        *map(str, physics), str(helpers), str(ROOT / "App/Render/PlanetSurface.swift"),
                        str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable), str(tmp)], check=True)
        ASSETS.mkdir(exist_ok=True)
        (ASSETS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
        for name in ("TerraSurface", "LunaSurface"):
            folder = ASSETS / (name + ".imageset")
            folder.mkdir(exist_ok=True)
            with Image.open(tmp / (name + ".ppm")) as image:
                image.save(folder / (name + ".png"), optimize=True)
            contents = {"images": [{"filename": name + ".png", "idiom": "universal"}],
                        "info": {"author": "xcode", "version": 1}}
            (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
            print(folder / (name + ".png"), flush=True)


if __name__ == "__main__":
    main()
