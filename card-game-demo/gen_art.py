# 生成本地演示插画（占位美术）
# 产出 card-game-demo/art/fire_mage.png 和 art/ice_bolt.png
from PIL import Image, ImageDraw
import os, random

os.makedirs("card-game-demo/art", exist_ok=True)

W, H = 512, 384

def base_gradient(c1, c2):
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)], fill=(
            int(c1[0] + (c2[0] - c1[0]) * t),
            int(c1[1] + (c2[1] - c1[1]) * t),
            int(c1[2] + (c2[2] - c1[2]) * t)))
    return img

def radial_layer(center, radius, color, steps=48):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for i in range(steps):
        r = int(radius * (steps - i) / steps)
        alpha = int(255 * i / steps)
        d.ellipse([center[0]-r, center[1]-r, center[0]+r, center[1]+r],
                  fill=color + (alpha,))
    return layer

def vignette():
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for i in range(60):
        t = i / 60
        r = int(min(W, H) * (0.45 + 0.55 * t))
        alpha = int(90 * t * t)
        d.ellipse([W/2 - r, H/2 - r, W/2 + r, H/2 + r], fill=(0, 0, 0, alpha))
    return layer

def compose(base, layers):
    base = base.convert("RGBA")
    for l in layers:
        base = Image.alpha_composite(base, l)
    return base

# ---------- 烈焰术士：暖橙火焰 ----------
img = compose(base_gradient((28, 22, 60), (58, 30, 24)),
              [radial_layer((W*0.5, H*0.42), 260, (255, 160, 40)),
               radial_layer((W*0.42, H*0.55), 150, (255, 90, 20)),
               radial_layer((W*0.58, H*0.35), 130, (255, 220, 120)),
               vignette()])
d = ImageDraw.Draw(img)
for (fx, fy, fw, fh, fc) in [
    (W*0.34, H*0.52, 70, 110, (255, 200, 60)),
    (W*0.46, H*0.56, 90, 130, (255, 140, 30)),
    (W*0.60, H*0.50, 60, 100, (255, 120, 20)),
    (W*0.40, H*0.42, 45, 80,  (255, 240, 150)),
]:
    d.ellipse([fx - fw/2, fy - fh/2, fx + fw/2, fy + fh/2], fill=fc)
img.save("card-game-demo/art/fire_mage.png")

# ---------- 寒冰箭：冷蓝晶体 ----------
img = compose(base_gradient((10, 18, 45), (30, 60, 95)),
              [radial_layer((W*0.5, H*0.5), 300, (90, 180, 255)),
               radial_layer((W*0.5, H*0.5), 150, (190, 235, 255)),
               vignette()])
d = ImageDraw.Draw(img)
cx, cy = W*0.5, H*0.5
d.polygon([(cx, cy-90), (cx+70, cy), (cx, cy+90), (cx-70, cy)], fill=(235, 250, 255))
d.polygon([(cx, cy-90), (cx+30, cy), (cx, cy+90), (cx-30, cy)], fill=(255, 255, 255))
d.polygon([(cx, cy-40), (cx+90, cy), (cx, cy+40), (cx-90, cy)], fill=(200, 235, 255))
random.seed(7)
for _ in range(26):
    x = random.randint(60, W-60)
    y = random.randint(60, H-60)
    s = random.randint(2, 5)
    d.ellipse([x-s, y-s, x+s, y+s], fill=(220, 240, 255))
img.save("card-game-demo/art/ice_bolt.png")

print("ok")
