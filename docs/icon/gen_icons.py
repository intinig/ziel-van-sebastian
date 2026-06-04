#!/usr/bin/env python3
"""Generate three app-icon candidates for Ziel van Sebastian."""
from PIL import Image, ImageDraw, ImageFilter
import os

OUT = "/tmp/ziel-icons"
S = 1024                       # canvas
BOX = 824                      # macOS icon-grid content square
RAD = 185                      # Big Sur squircle-ish corner radius
M = (S - BOX) // 2             # margin

# Locked FaceGeometry (19x16 grid)
RECTS = [(0,0,2,5),(17,0,2,5),(9,0,2,11),(6,9,3,2),(2,12,2,2),(4,14,11,2),(15,12,2,2)]
GRID_W, GRID_H = 19, 16

GREEN = (65, 255, 106)
AMBER = (255, 176, 0)


def draw_face(layer, color, gp, ox, oy):
    d = ImageDraw.Draw(layer)
    for (x, y, w, h) in RECTS:
        d.rectangle([ox + x*gp, oy + y*gp, ox + (x+w)*gp - 1, oy + (y+h)*gp - 1], fill=color + (255,))


def glow_stack(face_layer, color):
    """sharp face + two blurred glow layers underneath"""
    out = Image.new("RGBA", face_layer.size, (0, 0, 0, 0))
    big = face_layer.filter(ImageFilter.GaussianBlur(34))
    mid = face_layer.filter(ImageFilter.GaussianBlur(11))
    for img, alpha in ((big, 110), (mid, 150)):
        tint = img.copy()
        a = tint.getchannel("A").point(lambda v: v * alpha // 255)
        tint.putalpha(a)
        out.alpha_composite(tint)
    out.alpha_composite(face_layer)
    return out


def scanlines(img, region, period=7, dark=46):
    """darken horizontal bands inside region=(x0,y0,x1,y1)"""
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    x0, y0, x1, y1 = region
    y = y0
    while y < y1:
        d.rectangle([x0, y, x1, y + period // 2 - 1], fill=(0, 0, 0, dark))
        y += period
    return Image.alpha_composite(img, ov)


def rounded_mask(size, box, rad, margin):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([margin, margin, margin + box, margin + box], radius=rad, fill=255)
    return m


def vignette(img, region, strength=120):
    x0, y0, x1, y1 = region
    w, h = x1 - x0, y1 - y0
    grad = Image.new("L", (w, h), 0)
    gd = ImageDraw.Draw(grad)
    cx, cy = w / 2, h / 2
    maxd = (cx**2 + cy**2) ** 0.5
    # radial gradient via concentric ellipses (coarse but fine after blur)
    steps = 40
    for i in range(steps, 0, -1):
        f = i / steps
        a = int(strength * (f ** 2))
        gd.ellipse([cx - cx*f*1.45, cy - cy*f*1.45, cx + cx*f*1.45, cy + cy*f*1.45], fill=a)
    grad = grad.filter(ImageFilter.GaussianBlur(30))
    grad = grad.point(lambda v: strength - min(v, strength))
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    black = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    black.putalpha(grad)
    ov.paste(black, (x0, y0))
    return Image.alpha_composite(img, ov)


def squircle_icon(color, fname):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(bg)
    # subtle vertical gradient: deep green-black -> black
    for i in range(BOX):
        t = i / BOX
        base = (10 + int(6 * (1 - t)), 15 + int(8 * (1 - t)), 10 + int(6 * (1 - t)))
        d.line([(M, M + i), (M + BOX, M + i)], fill=base + (255,))
    # face: ~56% of box width
    gp = int(BOX * 0.56 / GRID_W)
    fw, fh = gp * GRID_W, gp * GRID_H
    ox, oy = (S - fw) // 2, (S - fh) // 2
    face = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_face(face, color, gp, ox, oy)
    # background treatments first; the glowing face goes ON TOP so the
    # vignette can't dim the phosphor
    bg = vignette(bg, (M, M, M + BOX, M + BOX))
    bg.alpha_composite(glow_stack(face, color))
    bg = scanlines(bg, (M, M, M + BOX, M + BOX), period=8, dark=38)
    img.paste(bg, (0, 0), rounded_mask(S, BOX, RAD, M))
    img.save(f"{OUT}/{fname}")
    return img


def crt_icon(fname):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(body)
    # beige monitor body fills the icon grid box
    BEIGE = (226, 219, 200)
    BEIGE_D = (196, 188, 168)
    d.rounded_rectangle([M, M, M + BOX, M + BOX], radius=RAD, fill=BEIGE + (255,))
    # screen inset: upper portion
    sx0, sy0 = M + 96, M + 92
    sx1, sy1 = M + BOX - 96, M + int(BOX * 0.66)
    d.rounded_rectangle([sx0 - 22, sy0 - 22, sx1 + 22, sy1 + 22], radius=46, fill=BEIGE_D + (255,))
    d.rounded_rectangle([sx0, sy0, sx1, sy1], radius=30, fill=(8, 12, 8, 255))
    # chin: floppy slit
    d.rounded_rectangle([M + 110, M + BOX - 150, M + 340, M + BOX - 122], radius=14, fill=BEIGE_D + (255,))
    # face on the screen
    sw = sx1 - sx0
    gp = int(sw * 0.62 / GRID_W)
    fw, fh = gp * GRID_W, gp * GRID_H
    ox = sx0 + (sw - fw) // 2
    oy = sy0 + ((sy1 - sy0) - fh) // 2
    face = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_face(face, GREEN, gp, ox, oy)
    body.alpha_composite(glow_stack(face, GREEN))
    body = scanlines(body, (sx0, sy0, sx1, sy1), period=6, dark=60)
    img.paste(body, (0, 0), rounded_mask(S, BOX, RAD, M))
    img.save(f"{OUT}/{fname}")
    return img


os.makedirs(OUT, exist_ok=True)
a = squircle_icon(GREEN, "icon-a-green.png")
b = crt_icon("icon-b-crt.png")
c = squircle_icon(AMBER, "icon-c-amber.png")
for name in ("icon-a-green", "icon-b-crt", "icon-c-amber"):
    im = Image.open(f"{OUT}/{name}.png")
    im.resize((256, 256), Image.LANCZOS).save(f"{OUT}/{name}-256.png")
    im.resize((64, 64), Image.LANCZOS).save(f"{OUT}/{name}-64.png")
print("done")
