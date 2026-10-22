#!/usr/bin/env python3
"""
从全屏截图里裁出 App 窗口，贴到深色渐变背景上，生成 README 用的界面图。

用法:
    python3 Scripts/make_screenshots.py <全屏截图> <输出文件> [--window x,y,w,h]
"""

import sys
from PIL import Image, ImageDraw, ImageFilter


def gradient_bg(w, h, top=(24, 27, 34), bottom=(40, 45, 56)):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(h - 1, 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (w, y)], fill=c)
    return img


def find_window(img):
    """找白色窗口区域。返回 (x0,y0,x1,y1) 物理坐标。"""
    import numpy as np
    a = np.array(img.convert("RGB"))
    white = (a[:, :, 0] > 246) & (a[:, :, 1] > 246) & (a[:, :, 2] > 246)
    rows = np.where(white.sum(axis=1) > 400)[0]
    cols = np.where(white.sum(axis=0) > 200)[0]
    if not len(rows) or not len(cols):
        return None
    return int(cols.min()), int(rows.min()), int(cols.max()), int(rows.max())


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    src, dst = sys.argv[1], sys.argv[2]
    img = Image.open(src).convert("RGB")

    # 传 --cropped 表示这张图已经是窗口本身，不用再找
    if "--cropped" in sys.argv:
        win = img
        ww, wh = win.size
        margin = 50
        W, H = ww + margin * 2, wh + margin * 2
        canvas = gradient_bg(W, H)
        shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow)
        sd.rounded_rectangle([margin, margin + 8, margin + ww, margin + wh + 8],
                             radius=14, fill=(0, 0, 0, 120))
        shadow = shadow.filter(ImageFilter.GaussianBlur(24))
        canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow)
        mask = Image.new("L", (ww, wh), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, ww - 1, wh - 1], radius=11, fill=255)
        wr = win.convert("RGBA"); wr.putalpha(mask)
        canvas.alpha_composite(wr, (margin, margin))
        canvas.convert("RGB").save(dst, quality=92)
        print(f"已保存: {dst}  {W}x{H}")
        return 0

    box = None
    if "--window" in sys.argv:
        i = sys.argv.index("--window")
        box = tuple(int(v) for v in sys.argv[i + 1].split(","))
        box = (box[0], box[1], box[0] + box[2], box[1] + box[3])
    else:
        box = find_window(img)

    if not box:
        print("没找到窗口")
        return 2

    x0, y0, x1, y1 = box
    # 稍微外扩，把窗口圆角和阴影带进来
    pad = 6
    x0, y0 = max(0, x0 - pad), max(0, y0 - pad)
    x1, y1 = min(img.width, x1 + pad), min(img.height, y1 + pad)

    win = img.crop((x0, y0, x1, y1))
    ww, wh = win.size
    print(f"窗口: {ww}x{wh}")

    # 画布：窗口四周留 60px 边距
    margin = 60
    W, H = ww + margin * 2, wh + margin * 2
    canvas = gradient_bg(W, H)

    # 窗口投影
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([margin, margin + 8, margin + ww, margin + wh + 8],
                         radius=14, fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow)

    # 窗口圆角遮罩
    mask = Image.new("L", (ww, wh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, ww - 1, wh - 1], radius=10, fill=255)
    win_rgba = win.convert("RGBA")
    win_rgba.putalpha(mask)

    canvas.alpha_composite(win_rgba, (margin, margin))
    canvas.convert("RGB").save(dst, quality=92)
    print(f"已保存: {dst}  {W}x{H}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
