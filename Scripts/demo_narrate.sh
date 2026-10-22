#!/bin/bash
# 生成"介绍这段录屏"的解说词
# 用法: ./Scripts/demo_narrate.sh [voice] [rate]
set -euo pipefail
cd "$(dirname "$0")/.."

VOICE="${1:-Tingting}"
RATE="${2:-170}"
OUT="Demo/narration"
mkdir -p "$OUT"
rm -f "$OUT"/*.aiff

say_line() {
  local idx="$1"; local text="$2"
  say -v "$VOICE" -r "$RATE" -o "$OUT/${idx}.aiff" "$text"
  local dur=$(afinfo "$OUT/${idx}.aiff" 2>/dev/null | awk '/estimated duration/ {print $3}')
  printf "%-4s %6.2fs  %s\n" "$idx" "${dur:-0}" "$text"
}

echo "=== 生成解说词 (voice=$VOICE rate=$RATE) ==="
# 按画面顺序，一句一个动作
say_line 01 "这是我写的一个 macOS 小工具，叫合秘。"
say_line 02 "它把会议里对方说的话，实时变成文字。"
say_line 03 "注意看，文字是一句一句出来的。"
say_line 04 "点这个按钮，字幕会变成浮窗，叠在会议窗口上。"
say_line 05 "半透明，鼠标穿透，不挡你点按钮。"
say_line 06 "我最在意的是：文字随时能选中复制。"
say_line 07 "新句子一直进来，选区不会被打断。"
say_line 08 "会议结束，留下转写、字幕、和原始录音。"
say_line 09 "字幕是标准 SRT，拖进剪辑软件就能用。"
say_line 10 "全程音频不出本机。不联网，不上传。"
say_line 11 "合秘 HearMe。听见，但不外传。"

echo
echo "=== 总时长 ==="
total=0
for f in "$OUT"/*.aiff; do
  d=$(afinfo "$f" 2>/dev/null | awk '/estimated duration/ {print $3}')
  total=$(echo "$total + ${d:-0}" | bc -l)
done
printf "合计 %.1f 秒\n" "$total"
