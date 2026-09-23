#!/usr/bin/env python3
"""Renders the Passthrough app icon (teal→violet gradient, USB-link glyph) at every size.

`--android` renders only the Android adaptive-icon layers (background and
glyph separately, glyph scaled into the launcher safe zone)."""
import math, struct, zlib, sys, os

def png(width, height, pixels):
    raw = b''.join(b'\x00' + bytes(row) for row in pixels)
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')

def lerp(a, b, t): return a + (b - a) * t

def render(size, rounded, layer="full", glyph_scale=1.0):
    teal, violet = (64, 224, 209), (181, 133, 255)
    bg_dark = (13, 15, 24)
    px = []
    r = size * 0.225  # macOS-style corner radius
    cx = cy = size / 2
    for y in range(size):
        row = []
        for x in range(size):
            # Rounded-square mask (iOS masks itself; mac icons need the shape baked in)
            if rounded:
                dx = max(abs(x + 0.5 - cx) - (size / 2 - r), 0)
                dy = max(abs(y + 0.5 - cy) - (size / 2 - r), 0)
                d = math.hypot(dx, dy) - r
                alpha = max(0.0, min(1.0, 0.5 - d))
            else:
                alpha = 1.0
            t = (x + y) / (2 * size)
            base = tuple(int(lerp(bg_dark[i], lerp(teal[i], violet[i], t) * 0.35 + bg_dark[i] * 0.65, 0.9)) for i in range(3))
            # Glow blob top-left
            g = math.exp(-((x - size * 0.25) ** 2 + (y - size * 0.2) ** 2) / (2 * (size * 0.35) ** 2))
            col = [int(min(255, base[i] + teal[i] * 0.35 * g)) for i in range(3)]
            g2 = math.exp(-((x - size * 0.8) ** 2 + (y - size * 0.85) ** 2) / (2 * (size * 0.35) ** 2))
            col = [int(min(255, col[i] + violet[i] * 0.35 * g2)) for i in range(3)]
            # Glyph: two rounded nodes joined by a link, with a stroke-ring accent
            nx, ny = (x - cx) / size / glyph_scale, (y - cy) / size / glyph_scale
            # Central ring
            rr = math.hypot(nx, ny)
            ring = 1 - min(1, abs(rr - 0.27) / 0.045)
            # Horizontal bar
            bar = 1 - min(1, max(abs(ny) - 0.035, 0) / 0.02) if abs(nx) < 0.17 else 0
            # End caps
            cap1 = 1 - min(1, max(math.hypot(nx + 0.19, ny) - 0.075, 0) / 0.02)
            cap2 = 1 - min(1, max(math.hypot(nx - 0.19, ny) - 0.075, 0) / 0.02)
            glyph = max(ring * 0.9, bar, cap1, cap2)
            gt = min(1.0, max(0.0, nx + 0.5))
            gc = tuple(lerp(teal[i], violet[i], gt) for i in range(3))
            if layer == "fg":
                row += [int(gc[0]), int(gc[1]), int(gc[2]), int(255 * glyph)]
                continue
            if layer == "full":
                col = [int(lerp(col[i], gc[i], glyph)) for i in range(3)]
            row += [col[0], col[1], col[2], int(255 * alpha)]
        px.append(row)
    return png(size, size, px)

if '--android' in sys.argv:
    # Adaptive icon: 108dp layers, 72dp visible; the glyph must sit inside the 66dp safe zone.
    for density, px in (('mdpi', 108), ('hdpi', 162), ('xhdpi', 216), ('xxhdpi', 324), ('xxxhdpi', 432)):
        d = f'android/app/src/main/res/mipmap-{density}'
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, 'ic_launcher_background.png'), 'wb').write(render(px, False, 'bg'))
        open(os.path.join(d, 'ic_launcher_foreground.png'), 'wb').write(render(px, False, 'fg', glyph_scale=0.68))
    print('android icons written')
    sys.exit(0)

out_ios = 'iOS/App/Resources/Assets.xcassets/AppIcon.appiconset'
out_mac = 'macOS/App/Resources/Assets.xcassets/AppIcon.appiconset'
open(os.path.join(out_ios, 'icon-1024.png'), 'wb').write(render(1024, False))
for s in (16, 32, 64, 128, 256, 512, 1024):
    open(os.path.join(out_mac, f'icon-{s}.png'), 'wb').write(render(s, True))
print('icons written')
