from PIL import Image, ImageDraw, ImageFilter
import os

SRC = 'Icon/source.png'
OUT = 'Icon'
os.makedirs(OUT, exist_ok=True)

S = 1024            # 最终画布
INSET = 100         # macOS 图标内容区留白（824x824）
RADIUS = 185        # 圆角半径，接近 Big Sur squircle

img = Image.open(SRC).convert('RGBA')
# 源图是正方形，直接缩放
side = S - INSET * 2
art = img.resize((side, side), Image.LANCZOS)

# 圆角遮罩
mask = Image.new('L', (side, side), 0)
d = ImageDraw.Draw(mask)
d.rounded_rectangle([0, 0, side - 1, side - 1], radius=RADIUS, fill=255)
art.putalpha(mask)

canvas = Image.new('RGBA', (S, S), (0, 0, 0, 0))

# 柔和投影，让图标在 Dock 里有层次
shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle(
    [INSET, INSET + 10, INSET + side, INSET + side + 10],
    radius=RADIUS, fill=(0, 0, 0, 70)
)
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
canvas.alpha_composite(shadow)
canvas.alpha_composite(art, (INSET, INSET))
canvas.save(f'{OUT}/icon_1024.png')

# 生成 iconset
sizes = [16, 32, 64, 128, 256, 512, 1024]
iconset = f'{OUT}/HearMe.iconset'
os.makedirs(iconset, exist_ok=True)
for s in sizes:
    im = canvas.resize((s, s), Image.LANCZOS)
    im.save(f'{iconset}/icon_{s}x{s}.png')
    if s * 2 <= 1024:
        im2 = canvas.resize((s * 2, s * 2), Image.LANCZOS)
        im2.save(f'{iconset}/icon_{s}x{s}@2x.png')
print('iconset ready')

# 用法：
#   python3 Scripts/make_icon.py Icon/source.png
#   iconutil -c icns Icon/HearMe.iconset -o Icon/AppIcon.icns
#
# 说明：macOS 图标规范是 1024x1024 画布，内容区留 100px 边距（824x824），
# 圆角半径约 185px 接近 Big Sur 的 squircle。加一层高斯模糊投影，
# 让图标在 Dock 里有浮起感，而不是一块死板的圆角矩形。
