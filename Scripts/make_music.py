#!/usr/bin/env python3
"""
合成演示片背景音乐 —— 用 ffmpeg 的正弦波叠加，不依赖任何外部音频素材。

为什么自己合成：
  1. 没有版权问题，AGPL 项目可以直接分发
  2. 体积小，几 MB 变几百 KB
  3. 可以精确控制长度，正好卡在 55 秒

音乐设计：
  - 四个和弦循环两遍（Cmaj7 → Am7 → Fmaj7 → G6），都是舒缓的大七/小七和弦
  - 每个音用正弦波 + 轻微失谐（两个相近频率叠加），产生自然的"合唱"感
  - 低通滤波削掉高频毛刺，加一点延迟营造空间
  - 整体音量压得很低，只做底噪，不抢人声

用法:
    python3 Scripts/make_music.py [时长秒数]
输出:
    Demo/music.wav
"""

import os
import subprocess
import sys

OUT = "Demo/music.wav"
TMP = "/tmp/hearme_music"
os.makedirs(TMP, exist_ok=True)

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 57.0

# 和弦（Hz）。选大七和弦是因为它不"解决"，听起来悬停、不催人
CHORDS = [
    ("Cmaj7", [261.63, 329.63, 392.00, 493.88]),   # C E G B
    ("Am7",   [220.00, 261.63, 329.63, 392.00]),   # A C E G
    ("Fmaj7", [174.61, 220.00, 261.63, 329.63]),   # F A C E
    ("G6",    [196.00, 246.94, 293.66, 329.63]),   # G B D E
]

CHORD_SEC = 8.0
XFADE = 1.0


def build_chord(name, freqs, idx):
    """一个和弦 = 4 个音 × 2 个失谐层 = 8 路正弦叠加"""
    inputs = []
    # 根音低八度，垫底
    inputs.append(freqs[0] / 2)
    for f in freqs:
        # 主音 + 高 3 音分（约 0.17%）的失谐层，产生缓慢拍频
        inputs.append(f)
        inputs.append(f * 1.0017)

    args = ["ffmpeg", "-y", "-loglevel", "error"]
    for f in inputs:
        args += ["-f", "lavfi", "-i",
                 f"sine=frequency={f:.3f}:duration={CHORD_SEC}:sample_rate=44100"]

    # 8 路混音，每路音量递减（高音轻一点，避免刺耳）
    vols = []
    for i in range(len(inputs)):
        v = 0.30 if i % 2 == 0 else 0.22
        # 越高的音越轻
        if i >= 4:
            v *= 0.65
        vols.append(f"[{i}:a]volume={v:.3f}[v{i}]")

    mixin = "".join(f"[v{i}]" for i in range(len(inputs)))
    # 低通 + 缓慢颤音 + 首尾淡入淡出
    filters = ";".join(vols) + f";{mixin}amix=inputs={len(inputs)}:normalize=0[m];" \
        f"[m]lowpass=f=1800,highpass=f=70,tremolo=f=0.16:d=0.10," \
        f"aecho=0.7:0.55:220|420:0.22|0.12," \
        f"afade=t=in:st=0:d={XFADE * 1.2},afade=t=out:st={CHORD_SEC - XFADE * 1.2}:d={XFADE * 1.2}[out]"

    out = f"{TMP}/{idx:02d}_{name}.wav"
    args += ["-filter_complex", filters, "-map", "[out]", out]
    subprocess.run(args, check=True)
    return out


print(f"=== 合成背景音乐（目标 {DURATION}s）===")
segments = []
idx = 0
total = 0.0
while total < DURATION + CHORD_SEC:
    name, freqs = CHORDS[idx % len(CHORDS)]
    seg = build_chord(name, freqs, idx)
    segments.append(seg)
    print(f"  {idx + 1}. {name}  {CHORD_SEC}s")
    total += CHORD_SEC - XFADE
    idx += 1
    if idx > 20:
        break

# 交叉淡入淡出拼接，让和弦切换不突兀
print("=== 拼接 ===")
if len(segments) == 1:
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", segments[0],
                    "-t", str(DURATION), OUT], check=True)
else:
    args = ["ffmpeg", "-y", "-loglevel", "error"]
    for s in segments:
        args += ["-i", s]

    # 链式 acrossfade
    filters = []
    prev = "[0:a]"
    for i in range(1, len(segments)):
        label = f"[x{i}]"
        filters.append(f"{prev}[{i}:a]acrossfade=d={XFADE}:c1=tri:c2=tri{label}")
        prev = label
    filters.append(f"{prev}atrim=0:{DURATION},asetpts=N/SR/TB,"
                   f"volume=2.2,alimiter=limit=0.85,"
                   f"afade=t=in:st=0:d=1.5,afade=t=out:st={DURATION - 3}:d=3,"
                   f"aformat=sample_fmts=s16:channel_layouts=stereo[out]")

    args += ["-filter_complex", ";".join(filters), "-map", "[out]", OUT]
    subprocess.run(args, check=True)

print(f"完成: {OUT}")
subprocess.run(["afinfo", OUT])
