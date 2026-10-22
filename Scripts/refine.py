#!/usr/bin/env python3
"""
Whisper 精修脚本 —— 由 HearMe 调用，不单独使用。

输入：一个 16kHz 单声道 WAV
输出：JSON（stdout 最后一行），格式：
    {"segments": [{"start": 0.0, "end": 2.4, "text": "..."}], "language": "zh"}

为什么需要 VAD：
    Whisper 在长静音段会产生幻觉（"请不吝点赞订阅转发"、"字幕由XX提供"），
    这是训练数据残留，调参无法根治。唯一可靠的做法是先用能量 VAD 切出
    真正的语音段，再逐段识别。这样既消灭幻觉，又快很多（只算有声部分）。
"""

import json
import sys
import wave

import numpy as np

# Whisper 幻觉的典型输出：训练数据里的字幕水印、结尾套话
HALLUCINATION_PATTERNS = [
    "请不吝点赞", "点赞 订阅", "订阅 转发", "打赏支持", "明镜与点点",
    "字幕由", "字幕提供", "字幕志愿者", "由Amara", "amara.org",
    "谢谢观看", "谢谢大家观看", "下集再见", "未完待续",
    "Subtitle", "subtitle", "Thanks for watching",
]


def is_hallucination(text, duration):
    """短且命中水印特征的，判定为幻觉。"""
    t = text.strip()
    if not t:
        return True
    for pat in HALLUCINATION_PATTERNS:
        if pat.lower() in t.lower():
            return True

    # 重复退化：任意短片段连续重复 3 次以上（不限于从头开始）
    if len(t) >= 6:
        for size in (2, 3, 4, 6):
            for i in range(0, min(len(t) - size * 3, size * 2) + 1):
                unit = t[i:i + size]
                if not unit.strip():
                    continue
                reps = 3
                if t[i:i + size * reps] == unit * reps:
                    return True
    # 重复率过高：不同字符占比太小
    if len(t) >= 10 and len(set(t)) / len(t) < 0.25:
        return True
    # 标点/字符种类过于单一（如"、、、、、、"）
    if len(set(t)) <= 2 and len(t) > 4:
        return True
    # 极短片段（<1.5s）且字数很少，多半是噪声被强行解码
    if duration < 1.5 and len(t) <= 6:
        return True
    # 完全没有中文/字母的纯符号
    if not any(ch.isalnum() or '\u4e00' <= ch <= '\u9fff' for ch in t):
        return True
    return False


def load_wav(path):
    with wave.open(path, "rb") as w:
        n, sr, ch, sw = w.getnframes(), w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(n)
    if n == 0:
        return np.zeros(0, dtype=np.float32), sr

    if sw == 2:
        x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif sw == 4:
        x = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        x = np.frombuffer(raw, dtype=np.uint8).astype(np.float32)
        x = (x - 128.0) / 128.0

    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def vad_segments(x, sr, frame_ms=30, thresh_ratio=0.06,
                 min_silence=0.35, min_speech=0.25, pad=0.15):
    """能量 VAD，返回 [(start_sample, end_sample)]。"""
    hop = int(sr * frame_ms / 1000)
    if hop <= 0 or len(x) < hop:
        return []
    n = len(x) // hop
    frames = x[: n * hop].reshape(n, hop)
    rms = np.sqrt(np.mean(frames ** 2, axis=1))

    peak = float(np.percentile(rms, 95))
    if peak < 1e-4:
        return []
    threshold = max(peak * thresh_ratio, 0.004)

    voiced = rms > threshold
    segments = []
    start = None
    silence = 0

    for i, v in enumerate(voiced):
        if v:
            if start is None:
                start = i
            silence = 0
        elif start is not None:
            silence += 1
            if silence * frame_ms / 1000 >= min_silence:
                end = i - silence + 1
                if (end - start) * frame_ms / 1000 >= min_speech:
                    segments.append((start, end))
                start = None
                silence = 0

    if start is not None:
        if (n - start) * frame_ms / 1000 >= min_speech:
            segments.append((start, n))

    padf = int(pad * sr)
    return [(max(0, s * hop - padf), min(len(x), e * hop + padf)) for s, e in segments]


def main():
    if len(sys.argv) < 4:
        print(json.dumps({"error": "usage: refine.py <wav> <model> <language> [prompt]"}))
        return 2

    wav_path, model, language = sys.argv[1], sys.argv[2], sys.argv[3]
    prompt = sys.argv[4] if len(sys.argv) > 4 else None

    x, sr = load_wav(wav_path)
    if len(x) == 0:
        print(json.dumps({"segments": [], "language": language}))
        return 0

    segs = vad_segments(x, sr)
    if not segs:
        print(json.dumps({"segments": [], "language": language}))
        return 0

    import mlx_whisper

    out = []
    for s, e in segs:
        chunk = x[s:e]
        if len(chunk) < int(0.2 * sr):
            continue
        try:
            r = mlx_whisper.transcribe(
                chunk,
                path_or_hf_repo=model,
                language=language,
                temperature=0.0,
                condition_on_previous_text=False,   # 关掉跨段上下文，避免错误累积
                no_speech_threshold=0.6,
                hallucination_silence_threshold=2.0,
                initial_prompt=prompt,
                verbose=None,
            )
        except Exception as exc:                    # 单段失败不影响整体
            print(f"segment failed: {exc}", file=sys.stderr)
            continue

        text = (r.get("text") or "").strip()
        if not text:
            continue
        duration = (e - s) / sr
        if is_hallucination(text, duration):
            print(f"skip hallucination: {text!r}", file=sys.stderr)
            continue
        out.append({
            "start": round(s / sr, 3),
            "end": round(e / sr, 3),
            "text": text,
        })

    print(json.dumps({"segments": out, "language": language}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
