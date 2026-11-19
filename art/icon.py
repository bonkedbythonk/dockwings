# Renders DockWings app icon options at 1024 px (drawn at 2x, downsampled).
# Usage: uv run --with pillow python icon.py  -> icon-a.png, icon-b.png, icon-c.png, icon-options.png
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # supersampled canvas
BOX = (200, 200, 1848, 1848)  # macOS icon grid: 824/1024 body
R = 370

def squircle_mask():
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle(BOX, R, fill=255)
    return m

def gradient(top, bottom):
    g = Image.new("RGB", (1, S))
    for y in range(S):
        t = y / (S - 1)
        g.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return g.resize((S, S))

def soft(img, radius):
    return img.filter(ImageFilter.GaussianBlur(radius))

def pill(draw, box, fill, r=None):
    draw.rounded_rectangle(box, r if r is not None else (box[3] - box[1]) // 2, fill=fill)

def finish(body, name):
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((BOX[0], BOX[1] + 30, BOX[2], BOX[3] + 30), R, fill=(0, 0, 0, 110))
    icon = Image.alpha_composite(icon, soft(shadow, 40))
    body = body.convert("RGBA"); body.putalpha(squircle_mask())
    icon = Image.alpha_composite(icon, body)
    icon.resize((1024, 1024), Image.LANCZOS).save(name)

def option_a():
    # Night: dark blue squircle, frosted Dock bar, two glowing wings.
    img = gradient((30, 42, 74), (8, 10, 22)).convert("RGBA")
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0)); g = ImageDraw.Draw(glow)
    pill(g, (330, 1330, 690, 1450), (255, 170, 90, 200)); pill(g, (1358, 1330, 1718, 1450), (120, 180, 255, 200))
    img = Image.alpha_composite(img, soft(glow, 60))
    d = ImageDraw.Draw(img)
    pill(d, (330, 1340, 690, 1440), (255, 196, 140, 255)); pill(d, (1358, 1340, 1718, 1440), (160, 205, 255, 255))
    bar = Image.new("RGBA", (S, S), (0, 0, 0, 0)); b = ImageDraw.Draw(bar)
    pill(b, (740, 1290, 1308, 1490), (255, 255, 255, 70), r=70)
    img = Image.alpha_composite(img, bar)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((740, 1290, 1308, 1490), 70, outline=(255, 255, 255, 140), width=6)
    for i, c in enumerate([(255, 255, 255, 230)] * 3):
        x = 830 + i * 150
        d.rounded_rectangle((x, 1330, x + 110, 1440), 28, fill=c)
    return img

def option_b():
    # Sunset: warm gradient, white Dock bar, wings as soft white strokes.
    img = gradient((255, 150, 90), (190, 60, 120)).convert("RGBA")
    d = ImageDraw.Draw(img)
    pill(d, (300, 1360, 660, 1420), (255, 255, 255, 170)); pill(d, (1388, 1360, 1748, 1420), (255, 255, 255, 170))
    d.rounded_rectangle((710, 1270, 1338, 1510), 90, fill=(255, 255, 255, 235))
    for i in range(3):
        x = 800 + i * 170
        d.rounded_rectangle((x, 1320, x + 120, 1440), 32, fill=(214, 104, 108, 255))
    return img

def option_c():
    # Paper: light squircle, dark Dock bar, two small orange wings.
    img = gradient((246, 244, 240), (222, 218, 212)).convert("RGBA")
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((640, 1250, 1408, 1500), 100, fill=(32, 32, 36, 255))
    for i in range(4):
        x = 720 + i * 170
        d.rounded_rectangle((x, 1300, x + 120, 1420), 32, fill=(250, 250, 250, 255))
    pill(d, (360, 1335, 580, 1415), (217, 119, 87, 255)); pill(d, (1468, 1335, 1688, 1415), (217, 119, 87, 255))
    return img

for name, fn in [("icon-a.png", option_a), ("icon-b.png", option_b), ("icon-c.png", option_c)]:
    finish(fn(), name)

sheet = Image.new("RGB", (3 * 560, 600), (236, 236, 236))
dr = ImageDraw.Draw(sheet)
for i, (name, label) in enumerate([("icon-a.png", "A  Night"), ("icon-b.png", "B  Sunset"), ("icon-c.png", "C  Paper")]):
    sheet.paste(Image.open(name).resize((480, 480), Image.LANCZOS), (40 + i * 560, 30), Image.open(name).resize((480, 480), Image.LANCZOS))
    dr.text((40 + i * 560 + 200, 540), label, fill=(20, 20, 20), font_size=28)
sheet.save("icon-options.png")
