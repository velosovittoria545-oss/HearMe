#!/usr/bin/env python3
"""
生成演示片的标题卡（片头/片尾），2560x1440，深色底。

用法:
    python3 Scripts/make_title_cards.py

输出到 Demo/cards/:
    01-钩子.png        开会时最怕什么？
    02-钩子下句.png     不是听不懂。是听懂了，转头就忘。
    03-片尾.png        Logo + 合秘 HearMe / 听见，但不外传。
    04-隐私角标.png     音频不出本机（透明底，可叠在画面上）
"""

import os
from PIL import Image, ImageDraw, ImageFont

W, H = 2560, 1440
BG = (18, 18, 20)          # 近黑，比纯黑柔和
FG = (245, 245, 247)
DIM = (150, 150, 158)
ACCENT = (90, 160, 250)

OUT = "Demo/cards"
os.makedirs(OUT, exist_ok=True)


def find_font(size, bold=False):
    """找一个能显示中文的系统字体。"""
    candidates = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/Library/Fonts/Arial Unicode.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                # PingFang.ttc 是集合，索引 0=常规，2=中黑
                idx = 2 if (bold and "PingFang" in path) else 0
                return ImageFont.truetype(path, size, index=idx)
            except Exception:
                try:
                    return ImageFont.truetype(path, size)
                except Exception:
                    continue
    return ImageFont.load_default()


def draw_centered(draw, text, font, y, fill=FG, letter_spacing=0):
    """居中绘制一行字，支持字间距（中文标题加一点间距更高级）。"""
    if letter_spacing <= 0:
        bbox = draw.textbbox((0, 0), text, font=font)
        w = bbox[2] - bbox[0]
        draw.text(((W - w) / 2, y), text, font=font, fill=fill)
        return

    # 逐字排布
    widths = []
    for ch in text:
        b = draw.textbbox((0, 0), ch, font=font)
        widths.append(b[2] - b[0])
    total = sum(widths) + letter_spacing * (len(text) - 1)
    x = (W - total) / 2
    for ch, w in zip(text, widths):
        draw.text((x, y), ch, font=font, fill=fill)
        x += w + letter_spacing


def canvas():
    img = Image.new("RGB", (W, H), BG)
    return img, ImageDraw.Draw(img)


# ---------- 01 钩子 ----------
img, d = canvas()
f1 = find_font(96, bold=True)
draw_centered(d, "开会时最怕什么？", f1, H / 2 - 70, letter_spacing=6)
img.save(f"{OUT}/01-钩子.png")

# ---------- 02 钩子下句 ----------
img, d = canvas()
f2 = find_font(72)
draw_centered(d, "不是听不懂。", f2, H / 2 - 130, fill=DIM)
draw_centered(d, "是听懂了，转头就忘。", f2, H / 2 + 10, fill=FG)
img.save(f"{OUT}/02-钩子下句.png")

# ---------- 03 片尾 ----------
img, d = canvas()
logo = Image.open("Icon/icon_1024.png").convert("RGBA").resize((260, 260), Image.LANCZOS)
img.paste(logo, (int((W - 260) / 2), 400), logo)

f3 = find_font(88, bold=True)
f4 = find_font(44)
draw_centered(d, "合秘 HearMe", f3, 730, letter_spacing=4)
draw_centered(d, "听见，但不外传。", f4, 860, fill=DIM, letter_spacing=8)
img.save(f"{OUT}/03-片尾.png")

# ---------- 04 隐私角标（透明底，叠在画面上）----------
badge_w, badge_h = 520, 88
badge = Image.new("RGBA", (badge_w, badge_h), (0, 0, 0, 0))
bd = ImageDraw.Draw(badge)
bd.rounded_rectangle([0, 0, badge_w - 1, badge_h - 1], radius=20, fill=(0, 0, 0, 165))
fb = find_font(34)
text = "音频不出本机"
bbox = bd.textbbox((0, 0), text, font=fb)
tw = bbox[2] - bbox[0]
# 左边画一个小圆点当"指示灯"
bd.ellipse([26, badge_h / 2 - 7, 40, badge_h / 2 + 7], fill=ACCENT)
bd.text((60, (badge_h - (bbox[3] - bbox[1])) / 2 - bbox[1]), text, font=fb, fill=(255, 255, 255, 235))
badge.save(f"{OUT}/04-隐私角标.png")

print("生成完成：")
for f in sorted(os.listdir(OUT)):
    p = os.path.join(OUT, f)
    print(f"  {p}  {os.path.getsize(p) // 1024} KB")
