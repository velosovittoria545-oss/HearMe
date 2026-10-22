#!/bin/bash
# 生成演示片旁白。每条对应一个分镜，文件名带序号方便对轴。
# 用法: ./Scripts/demo_voice.sh [voice] [rate]
#   voice 默认 Meijia（女声，偏自然）
#   rate  默认 165（比正常慢一点，方便观众跟上）
set -euo pipefail
cd "$(dirname "$0")/.."

VOICE="${1:-Meijia}"
RATE="${2:-165}"
OUT="Demo/voice"
mkdir -p "$OUT"
rm -f "$OUT"/*.aiff "$OUT"/*.wav

say_line() {
  local idx="$1"; shift
  local text="$1"; shift
  local file="$OUT/${idx}.aiff"
  say -v "$VOICE" -r "$RATE" -o "$file" "$text"
  # 同时导出 wav，方便直接拖进剪辑软件
  afconvert -f WAVE -d LEI16@44100 "$file" "$OUT/${idx}.wav" 2>/dev/null || true
  local dur
  dur=$(afinfo "$file" 2>/dev/null | awk '/estimated duration/ {print $3}')
  printf "%-4s %6.2fs  %s\n" "$idx" "${dur:-0}" "$text"
}

echo "=== 生成旁白 (voice=$VOICE rate=$RATE) ==="
say_line 01 "开会时最怕什么？不是听不懂。是听懂了，转头就忘。"
say_line 02 "一场会开完，你记住了三句话。剩下的，都在录音文件里躺着，你不会再打开第二次。"
say_line 03 "所以我写了个小工具，叫合秘。只在你这台电脑上跑，点一下就开始。"
say_line 04 "对方说的话，一句一句变成文字。点这里，字幕会浮到会议窗口上面，半透明、不挡鼠标。"
say_line 05 "重点在这儿。文字随时可以选中、复制。新的话一直在进来，但你的选区不会被打断。"
say_line 06 "每场会议，一个文件夹。转写、字幕、原始录音，都在里面。字幕是标准格式，直接拖进剪辑软件就能用。"
say_line 07 "整个过程，音频不离开这台电脑。不联网，不上传，不要账号。"
say_line 08 "合秘 HearMe。听见，但不外传。"

echo
echo "=== 30 秒版 ==="
say_line s1 "开会记不住重点？我自己写了个小工具，叫合秘。把对方说的话实时变成文字，浮在会议窗口上。随时选中、随时复制，散会自动存成字幕文件。全部在本地跑，音频不出电脑。合秘 HearMe，听见，但不外传。"

echo
echo "=== 总时长 ==="
total=0
for f in "$OUT"/*.aiff; do
  d=$(afinfo "$f" 2>/dev/null | awk '/estimated duration/ {print $3}')
  total=$(echo "$total + ${d:-0}" | bc -l)
done
printf "旁白合计: %.1f 秒（加上停顿后约 %.0f 秒）\n" "$total" "$(echo "$total * 1.35" | bc -l)"
echo "输出目录: $OUT"
