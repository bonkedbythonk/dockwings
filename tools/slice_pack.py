import math, os, sys
from PIL import Image

def remove_background(im_rgb, threshold=235):
    """Converts a white-background RGB/RGBA image into RGBA with straight (unassociated) alpha."""
    w, h = im_rgb.size
    out = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    px = im_rgb.load()
    out_px = out.load()
    
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y][:3]
            dist = math.sqrt((255 - r)**2 + (255 - g)**2 + (255 - b)**2)
            if dist < 22:
                out_px[x, y] = (0, 0, 0, 0)
            elif dist < 58:
                a = int(((dist - 22) / 36.0) * 255.0)
                # Straight alpha: un-premultiply color channels
                rf = min(255, int(r * 255.0 / max(a, 1)))
                gf = min(255, int(g * 255.0 / max(a, 1)))
                bf = min(255, int(b * 255.0 / max(a, 1)))
                out_px[x, y] = (rf, gf, bf, a)
            else:
                out_px[x, y] = (r, g, b, 255)
    return out

def get_char_bbox(cell_rgba):
    """Finds bbox of solid character pixels in cell."""
    w, h = cell_rgba.size
    px = cell_rgba.load()
    min_x, max_x, min_y, max_y = w, 0, h, 0
    found = 0
    for y in range(h):
        for x in range(w):
            if px[x, y][3] > 40:
                min_x = min(min_x, x); max_x = max(max_x, x)
                min_y = min(min_y, y); max_y = max(max_y, y)
                found += 1
    if found == 0:
        return None
    return (min_x, min_y, max_x, max_y)

def slice_grid(sheet_path, grid_layout, out_pack_dir, base_stand_h=114):
    """
    grid_layout is a 2D list of frame numbers, e.g. [[1, 2, 3]] or [[4, 18, 19], [20, 21, 22]]
    """
    os.makedirs(out_pack_dir, exist_ok=True)
    im = Image.open(sheet_path).convert('RGB')
    w, h = im.size
    rows = len(grid_layout)
    cols = len(grid_layout[0])
    cell_w = w // cols
    cell_h = h // rows
    
    for r in range(rows):
        for c in range(cols):
            num = grid_layout[r][c]
            if num is None:
                continue
            
            # Crop cell
            cell = im.crop((c * cell_w, r * cell_h, (c + 1) * cell_w, (r + 1) * cell_h))
            cell_rgba = remove_background(cell)
            bbox = get_char_bbox(cell_rgba)
            if bbox is None:
                print(f"Warning: frame {num} empty in {sheet_path}")
                continue
            
            min_x, min_y, max_x, max_y = bbox
            char_w = max_x - min_x + 1
            char_h = max_y - min_y + 1
            cropped = cell_rgba.crop((min_x, min_y, max_x + 1, max_y + 1))
            
            # Construct final 128x128 frame according to pose rules
            frame = Image.new('RGBA', (128, 128), (0, 0, 0, 0))
            
            # Scaling:
            # Stand/walk frames have reference height ~base_stand_h (114px)
            if num in (1, 2, 3, 4, 22):
                scale = base_stand_h / float(char_h)
                tw = max(1, int(round(char_w * scale)))
                th = max(1, int(round(char_h * scale)))
                sc = cropped.resize((tw, th), Image.Resampling.LANCZOS)
                px = max(0, min(128 - tw, (128 - tw) // 2))
                py = max(0, 127 - th) # feet at bottom edge (y=127)
                frame.alpha_composite(sc, (px, py))
            elif num in (18, 19, 20, 21):
                # Squash/crawling/sleeping - scale proportional to base_stand_h
                scale = (base_stand_h * 0.9) / max(char_w if num == 21 else char_h, 1)
                tw = max(1, int(round(char_w * scale)))
                th = max(1, int(round(char_h * scale)))
                sc = cropped.resize((tw, th), Image.Resampling.LANCZOS)
                px = max(0, min(128 - tw, (128 - tw) // 2))
                py = max(0, 127 - th) # bottom edge on floor
                frame.alpha_composite(sc, (px, py))
            elif num in (11, 15, 16, 17, 26, 30):
                # Sitting - seat on bottom edge (y=127)
                scale = (base_stand_h * 0.85) / float(char_h)
                tw = max(1, int(round(char_w * scale)))
                th = max(1, int(round(char_h * scale)))
                sc = cropped.resize((tw, th), Image.Resampling.LANCZOS)
                px = max(0, min(128 - tw, (128 - tw) // 2))
                py = max(0, 127 - th)
                frame.alpha_composite(sc, (px, py))
            elif num in (12, 13, 14):
                # Wall climbing - hugs left edge (x=0..12)
                scale = base_stand_h / float(char_h)
                tw = max(1, int(round(char_w * scale)))
                th = max(1, int(round(char_h * scale)))
                sc = cropped.resize((tw, th), Image.Resampling.LANCZOS)
                px = 2 # hug left edge
                py = max(0, min(128 - th, (128 - th) // 2))
                frame.alpha_composite(sc, (px, py))
            elif num in (23, 24, 25):
                # Ceiling hang - hands at y=48
                scale = base_stand_h / float(char_h)
                tw = max(1, int(round(char_w * scale)))
                th = max(1, int(round(char_h * scale)))
                sc = cropped.resize((tw, th), Image.Resampling.LANCZOS)
                px = max(0, min(128 - tw, (128 - tw) // 2))
                py = 46 # top of hands near y=48
                frame.alpha_composite(sc, (px, py))
            elif num in (31, 32, 33):
                # Ledge sitting - seat at 112, legs reach 127
                scale = (base_stand_h * 0.95) / float(char_h)
                tw = max(1, int(round(char_w * scale)))
                th = max(1, int(round(char_h * scale)))
                sc = cropped.resize((tw, th), Image.Resampling.LANCZOS)
                px = max(0, min(128 - tw, (128 - tw) // 2))
                py = max(0, 127 - th)
                frame.alpha_composite(sc, (px, py))
            elif num in (5, 6, 7, 8, 9, 10):
                # Held dangling - head/collar near top
                scale = (base_stand_h * 0.95) / float(char_h)
                tw = max(1, int(round(char_w * scale)))
                th = max(1, int(round(char_h * scale)))
                sc = cropped.resize((tw, th), Image.Resampling.LANCZOS)
                px = max(0, min(128 - tw, (128 - tw) // 2))
                py = 10 # near top
                frame.alpha_composite(sc, (px, py))
            else:
                scale = base_stand_h / float(char_h)
                tw = max(1, int(round(char_w * scale)))
                th = max(1, int(round(char_h * scale)))
                sc = cropped.resize((tw, th), Image.Resampling.LANCZOS)
                px = max(0, min(128 - tw, (128 - tw) // 2))
                py = max(0, 127 - th)
                frame.alpha_composite(sc, (px, py))
                
            out_path = os.path.join(out_pack_dir, f"shime{num}.png")
            frame.save(out_path)
            print(f"Saved {out_path}")

print("slice_pack module loaded")
