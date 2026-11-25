# Renders app icon options for the Dock bar concept (one Dock across the
# screen with widgets in it, the notch on top) at 1024 px, drawn at 2x.
# Usage: uv run --with pillow python icon2.py  -> icon2-a..d.png, icon2-options.png
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 2048
BOX = (200, 200, 1848, 1848)
R = 370
W = BOX[2] - BOX[0]


def squircle_mask():
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle(BOX, R, fill=255)
    return m


def gradient(top, bottom, size=(S, S)):
    g = Image.new("RGB", (1, size[1]))
    for y in range(size[1]):
        t = y / (size[1] - 1)
        g.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return g.resize(size)


def finish(body, name):
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((BOX[0], BOX[1] + 30, BOX[2], BOX[3] + 30), R, fill=(0, 0, 0, 110))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(40)))
    body = body.convert("RGBA")
    body.putalpha(squircle_mask())
    icon.alpha_composite(body)
    out = icon.resize((1024, 1024), Image.LANCZOS)
    out.save(name)
    return out


def glass_bar(img, y0, y1, x0=BOX[0] + 110, x1=BOX[2] - 110, tint=(255, 255, 255, 46), rim=(255, 255, 255, 120)):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    r = (y1 - y0) // 2
    d.rounded_rectangle((x0, y0, x1, y1), r, fill=tint, outline=rim, width=6)
    img.alpha_composite(layer)


def tiles(d, xs, y, size, colors):
    for x, c in zip(xs, colors):
        d.rounded_rectangle((x, y, x + size, y + size), size // 4, fill=c)


def widget(d, x, y, h, w, art, text=(255, 255, 255)):
    # cover square and two text lines
    d.rounded_rectangle((x, y, x + h, y + h), h // 4, fill=art)
    d.rounded_rectangle((x + h + 30, y + h * 0.18, x + w, y + h * 0.18 + h * 0.2), h // 10, fill=text + (235,))
    d.rounded_rectangle((x + h + 30, y + h * 0.56, x + w * 0.8, y + h * 0.56 + h * 0.16), h // 12, fill=text + (130,))


def notch(img, w, h, fade_to=None, x_center=S // 2):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    x0, x1 = x_center - w // 2, x_center + w // 2
    if fade_to:
        g = gradient((0, 0, 0), fade_to, (w, h)).convert("RGBA")
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, -200, w, h), 90, fill=255)
        layer.paste(g, (x0, BOX[1]), mask)
    else:
        ImageDraw.Draw(layer).rounded_rectangle((x0, BOX[1] - 200, x1, BOX[1] + h), 70, fill=(0, 0, 0, 255))
    img.alpha_composite(layer)


# A: "Brim" - dusk screen, the notch on top, the full-width glass Dock below.
a = gradient((56, 62, 104), (214, 128, 112)).convert("RGBA")
notch(a, 640, 230)
d = ImageDraw.Draw(a)
d.rounded_rectangle((S // 2 - 250, BOX[1] + 70, S // 2 - 170, BOX[1] + 150), 20, fill=(140, 200, 230))
for i, h in enumerate((40, 70, 52)):
    d.rounded_rectangle((S // 2 + 190 + i * 26, BOX[1] + 160 - h, S // 2 + 206 + i * 26, BOX[1] + 160), 8, fill=(245, 162, 200))
glass_bar(a, 1480, 1700)
d = ImageDraw.Draw(a)
widget(d, BOX[0] + 170, 1530, 120, 430, (255, 196, 120))
tiles(d, [880, 1010, 1140], 1530, 120, [(90, 160, 255), (120, 110, 240), (255, 140, 90)])
widget(d, 1290, 1530, 120, 380, (236, 64, 152))
finish(a, "icon2-a.png")

# B: "Ledge" - the current warm style, the bar now runs edge to edge with a
# widget pill in it.
b = gradient((242, 240, 236), (224, 221, 214)).convert("RGBA")
d = ImageDraw.Draw(b)
d.rounded_rectangle((BOX[0] + 90, 1380, BOX[2] - 90, 1620), 120, fill=(33, 33, 37))
widget(d, BOX[0] + 160, 1440, 120, 470, (220, 120, 90))
tiles(d, [930, 1060, 1190], 1440, 120, [(250, 250, 250)] * 3)
d.rounded_rectangle((1360, 1440, 1520, 1560), 30, fill=(250, 250, 250))
d.rounded_rectangle((1340, 1300, 1360 + 200, 1330), 15, fill=(220, 120, 90))
finish(b, "icon2-b.png")

# C: "Tidebar" - the notch grown into the music card, fading into the cover's
# colour, over a glass Dock.
c = gradient((18, 18, 24), (40, 40, 52)).convert("RGBA")
notch(c, 980, 760, fade_to=(150, 70, 120))
d = ImageDraw.Draw(c)
d.rounded_rectangle((S // 2 - 400, BOX[1] + 330, S // 2 - 220, BOX[1] + 510), 40, fill=(255, 180, 120))
d.rounded_rectangle((S // 2 - 180, BOX[1] + 360, S // 2 + 330, BOX[1] + 400), 20, fill=(255, 255, 255))
d.rounded_rectangle((S // 2 - 180, BOX[1] + 440, S // 2 + 180, BOX[1] + 470), 15, fill=(255, 255, 255, 140))
d.rounded_rectangle((S // 2 - 400, BOX[1] + 590, S // 2 + 400, BOX[1] + 610), 10, fill=(255, 255, 255, 90))
d.rounded_rectangle((S // 2 - 400, BOX[1] + 590, S // 2 - 60, BOX[1] + 610), 10, fill=(255, 255, 255))
glass_bar(c, 1530, 1720, tint=(255, 255, 255, 34), rim=(255, 255, 255, 90))
d = ImageDraw.Draw(c)
tiles(d, [760, 890, 1020, 1150], 1565, 120, [(90, 160, 255), (120, 110, 240), (130, 220, 200), (255, 140, 90)])
finish(c, "icon2-c.png")

# D: "Rim" - minimal: a black notch on top, a bar at the bottom, one accent
# widget in each; the screen between them empty.
dimg = gradient((250, 250, 248), (236, 236, 232)).convert("RGBA")
notch(dimg, 560, 200)
d = ImageDraw.Draw(dimg)
d.rounded_rectangle((S // 2 - 200, BOX[1] + 60, S // 2 - 120, BOX[1] + 140), 20, fill=(236, 64, 152))
d.rounded_rectangle((BOX[0] + 120, 1560, BOX[2] - 120, 1700), 70, fill=(28, 28, 32))
d.rounded_rectangle((BOX[0] + 190, 1590, BOX[0] + 270, 1670), 20, fill=(255, 170, 90))
d.rounded_rectangle((BOX[0] + 300, 1605, BOX[0] + 560, 1630), 12, fill=(255, 255, 255))
for i in range(3):
    d.rounded_rectangle((960 + i * 110, 1595, 1040 + i * 110, 1675), 20, fill=(240, 240, 240))
finish(dimg, "icon2-d.png")

# Side by side with names.
names = ["A  Brim", "B  Ledge", "C  Tidebar", "D  Rim"]
sheet = Image.new("RGB", (4 * 520 + 40, 640), (246, 246, 244))
try:
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 40)
except OSError:
    font = ImageFont.load_default()
for i, (n, f) in enumerate(zip(names, ["icon2-a.png", "icon2-b.png", "icon2-c.png", "icon2-d.png"])):
    im = Image.open(f).resize((480, 480), Image.LANCZOS)
    sheet.paste(im, (40 + i * 520, 30), im)
    ImageDraw.Draw(sheet).text((40 + i * 520 + 150, 540), n, fill=(40, 40, 44), font=font)
sheet.save("icon2-options.png")
