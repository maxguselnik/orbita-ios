#!/usr/bin/env python3
"""Original, deterministic cube atlases for Vella, Arda and Taros.

Run with Python 3, NumPy and Pillow. 512px faces have the same relative gutters
as PlanetSurface (1024/8), so all flight/map LODs share one seam-safe layout.
No generation on the game thread and no downloaded artwork.
"""
import json
from pathlib import Path

import numpy as np
from PIL import Image

ASSETS = Path(__file__).resolve().parents[1] / "App/Assets.xcassets"
SIZE, GUTTER = 512, 4
TILE = SIZE + GUTTER * 2


def noise(p):
    cell = np.floor(p).astype(np.int64)
    f = p - cell
    u = f*f*f*(f*(f*6-15)+10)
    result = np.zeros(p.shape[:-1])
    for x in range(2):
        for y in range(2):
            for z in range(2):
                q = cell + (x, y, z)
                h = (q[..., 0]*1597334677 ^ q[..., 1]*3812015801 ^ q[..., 2]*2798796415) & 0xffffffff
                h = ((h ^ (h >> 16))*2246822519) & 0xffffffff
                h = ((h ^ (h >> 13))*3266489917) & 0xffffffff
                h ^= h >> 16
                weight = (u[..., 0] if x else 1-u[..., 0]) * (u[..., 1] if y else 1-u[..., 1]) * (u[..., 2] if z else 1-u[..., 2])
                result += (h/4294967295*2-1) * weight
    return result


def fbm(d, scale=4, octaves=5):
    value = np.zeros(d.shape[:-1])
    amplitude = 0.55
    for _ in range(octaves):
        value += amplitude * noise(d*scale + (17.3, 4.8, -2.1))
        scale *= 2.03
        amplitude *= 0.5
    return value


def smooth(a, b, x):
    t = np.clip((x-a)/(b-a), 0, 1)
    return t*t*(3-2*t)


def color(body, d):
    x, y, z = d[..., 0], d[..., 1], d[..., 2]
    broad = fbm(d, 3, 5)
    detail = fbm(d, 58, 4)
    if body == "Vella":
        # Basalt highlands and ochre plains; same large terrain waves as Terrain.height.
        height = 1300 + 1000*np.sin(x*9+y*4) + 650*np.sin(z*23+x*11) + 180*np.sin(y*83-z*47) + 45*np.sin(x*311+z*217)
        high = smooth(800, 2600, height + broad*1300)
        low = np.array([0.39, 0.23, 0.10])
        upper = np.array([0.78, 0.63, 0.36])
        rgb = low + high[..., None]*(upper-low)
        ridges = np.exp(-np.abs(fbm(d, 21, 4))*24)
        rgb *= (0.91 + broad*.26 + detail*.15 + ridges*.09)[..., None]
        # Broad sulphur haze in the atlas, with the actual atmosphere rendered separately.
        veil = smooth(-.15, .6, fbm(d, 5, 5))*.28
        rgb = rgb*(1-veil[..., None]) + np.array([.88, .75, .45])*veil[..., None]
    elif body == "Arda":
        height = 800+650*np.sin(x*7-y*3)+420*np.sin(y*19+z*9)+130*np.sin(z*67+x*41)+30*np.sin(y*283+z*191)
        high = smooth(200, 1800, height + broad*1000)
        rgb = np.array([.59, .24, .115]) + high[..., None]*np.array([.17, .16, .12])
        channels = np.exp(-np.abs(fbm(d, 12, 4)+broad*.4)*35)
        rgb *= (.94 + broad*.30 + detail*.18 - channels*.18)[..., None]
        ice = smooth(.86, .96, np.abs(z)+broad*.12)
        rgb = rgb*(1-ice[..., None]) + np.array([.88, .89, .83])*ice[..., None]
    else:
        # Continuous latitude belts, turbulence and elliptical storms, no rock relief.
        latitude = np.arcsin(np.clip(z, -1, 1))
        warp = latitude + .042*fbm(d, 13, 5) + .015*np.sin(x*28+y*13)
        band = .5+.5*np.sin(warp*36 + .6*np.sin(warp*11))
        fine = np.sin(warp*170+fbm(d, 47, 4)*4)
        rgb = np.array([.47, .37, .28]) + band[..., None]*np.array([.38, .36, .31])
        rgb *= (1+detail*.12+fine*.035)[..., None]
        center = np.array([.84, .48, -.26]); center /= np.linalg.norm(center)
        east = np.cross([0, 0, 1], center); east /= np.linalg.norm(east)
        north = np.cross(center, east)
        a = np.sum(d*east, axis=-1)/.22
        b = np.sum(d*north, axis=-1)/.09
        distance = np.sqrt(a*a+b*b)
        storm = (1-smooth(.65, 1.25, distance))*smooth(.8, .95, np.sum(d*center, axis=-1))
        swirl = .5+.5*np.sin(distance*22+np.arctan2(b, a)*2 + detail*4)
        stormcolor = np.array([.69, .33, .16]) + swirl[..., None]*np.array([.16, .14, .11])
        rgb = rgb*(1-storm[..., None]) + stormcolor*storm[..., None]
    return np.uint8(np.clip(rgb*255, 0, 255))


def direction(face, a, b):
    qa, qb = np.tan(a*np.pi/4), np.tan(b*np.pi/4)
    one = np.ones_like(a)
    components = [(one, qa, qb), (-one, qb, qa), (qb, one, qa),
                  (qa, -one, qb), (qa, qb, one), (qb, qa, -one)]
    p = np.stack(components[face], axis=-1)
    return p / np.linalg.norm(p, axis=-1, keepdims=True)


def main():
    q = -1 + 2*(np.arange(TILE)+.5-GUTTER)/SIZE
    a, b = np.meshgrid(q, -q)
    for body in ("Vella", "Arda", "Taros"):
        atlas = np.empty((TILE*2, TILE*3, 3), dtype=np.uint8)
        for face in range(6):
            atlas[(face//3)*TILE:(face//3+1)*TILE, (face%3)*TILE:(face%3+1)*TILE] = color(body, direction(face, a, b))
        name = body+"Surface"
        folder = ASSETS/(name+".imageset")
        folder.mkdir(parents=True, exist_ok=True)
        Image.fromarray(atlas).save(folder/(name+".png"), optimize=True)
        (folder/"Contents.json").write_text(json.dumps({"images": [{"filename": name+".png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, indent=2)+"\n")
        print(f"{name}: {atlas.shape[1]}x{atlas.shape[0]}", flush=True)


if __name__ == "__main__":
    main()
