# Checks Shimeji packs against docs/shimeji-frames.md and makes a contact sheet per pack.
# Run: uv run --with pillow python tools/shimeji-check.py art/Buddies /tmp/sheets
# Prints per pack: frame count, unique frames, identical frames, and the placement of
# standing feet, climbing (12-14, should hug the left), ceiling (23-25, hands near y=48)
# and ledge (31-33, legs reaching the bottom edge) frames. ISSUE lines must be fixed:
# wrong size, no transparency, opaque background, empty frame, or a known
# "Not available" placeholder image saved as a frame.
import sys, os, hashlib, glob
from PIL import Image, ImageDraw, ImageFont
root = sys.argv[1]; out = sys.argv[2]
# Files known to be a download site's "Not available" image, not art.
PLACEHOLDERS = {"3d9a7dc577db40fb06ff5b9a05f45b5b"}
os.makedirs(out, exist_ok=True)
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
for pack in sorted(os.listdir(root)):
    d = os.path.join(root, pack)
    if not os.path.isdir(d): continue
    frames = sorted([f for f in os.listdir(d) if f.startswith("shime") and f.endswith(".png")], key=lambda f: int(f[5:-4]))
    issues = []; hashes = {}; info = {}
    for f in frames:
        im = Image.open(os.path.join(d, f))
        n = int(f[5:-4])
        if im.size != (128, 128): issues.append(f"{n}: size {im.size}")
        if im.mode not in ("RGBA", "LA", "P"): issues.append(f"{n}: no alpha ({im.mode})")
        a = im.convert("RGBA").getchannel("A")
        bbox = a.point(lambda v: 255 if v > 40 else 0).getbbox()
        if bbox is None: issues.append(f"{n}: empty"); continue
        # corners opaque = background not removed
        px = im.convert("RGBA").load()
        if all(px[x, y][3] > 200 for x, y in [(0, 0), (127, 0), (0, 127), (127, 127)]): issues.append(f"{n}: opaque background")
        if hashlib.md5(open(os.path.join(d, f), "rb").read()).hexdigest() in PLACEHOLDERS: issues.append(f"{n}: 'Not available' placeholder, not a frame")
        h = hashlib.md5(im.convert("RGBA").tobytes()).hexdigest()
        hashes.setdefault(h, []).append(n)
        info[n] = bbox
    dups = [v for v in hashes.values() if len(v) > 1]
    def b(n): return info.get(n)
    stand = b(1)
    line = f"== {pack}: {len(frames)} frames, unique {len(hashes)}"
    print(line)
    if stand: print(f"   stand bbox {stand} (feet gap {127 - stand[3]}px)")
    for n in (2, 3): 
        if b(n) and stand: print(f"   walk {n} bbox {b(n)} feet gap {127 - b(n)[3]}")
    for n in (12, 13, 14):
        if b(n): print(f"   climb {n} left edge at x={b(n)[0]}, bbox {b(n)}")
    for n in (23, 24, 25):
        if b(n): print(f"   ceiling {n} top at y={b(n)[1]} (hands should be near y=48)")
    for n in (31, 32, 33):
        if b(n): print(f"   dangle {n} bottom at y={b(n)[3]}")
    if dups: print("   identical frames:", "; ".join(",".join(map(str, v)) for v in dups[:12]))
    for i in issues: print("   ISSUE", i)
    # contact sheet
    cols = 10; rows = (len(frames) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * 132, rows * 150), (60, 60, 70, 255))
    dr = ImageDraw.Draw(sheet)
    for i, f in enumerate(frames):
        im = Image.open(os.path.join(d, f)).convert("RGBA")
        x, y = (i % cols) * 132, (i // cols) * 150
        dr.rectangle([x + 1, y + 1, x + 129, y + 129], outline=(110, 110, 120, 255))
        sheet.alpha_composite(im, (x + 2, y + 2))
        dr.text((x + 4, y + 130), f[5:-4], fill=(255, 255, 255, 255), font=font)
    sheet.convert("RGB").save(os.path.join(out, pack + ".png"))
