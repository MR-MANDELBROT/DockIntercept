#!/usr/bin/env bash
# Regenerate every derived asset of the scroll-linked demo from one screen recording.
#
#   tools/make-demo-assets.sh path/to/recording.mov
#
# Writes, relative to the site root:
#   assets/demo.mp4                    larger screens: scroll scrubbing and "Play video"
#                                      (max 1280 px wide, 30 fps, keyframe every 10 frames, no B-frames)
#   assets/demo-mobile.mp4             phones: "Play video", reduced motion, fallback
#                                      (max 720 px wide, 30 fps)
#   assets/demo-frames/NNNNN.jpg       phones: scroll scrubbing frame sequence
#                                      (max 720 px wide, 15 fps, repeated frames dropped;
#                                      NNNNN is the 15 fps slot the image starts at)
#   assets/demo-frames/manifest.json   frame rate, slot count, size, kept slots
#   assets/poster.jpg                  first frame, shown until the demo is ready
#
# Same source in, same files out: everything is rebuilt in a temp dir and then
# swapped in, so the script can be rerun at any time. Keep the original
# recording outside assets/ (e.g. ~/Movies); re-encoding an output of this
# script only loses quality.
#
# Environment overrides: FFMPEG, FFPROBE, FRAME_BUDGET (bytes, default 6000000).
set -euo pipefail
export LC_ALL=C

FFMPEG=${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}
FFPROBE=${FFPROBE:-$(command -v ffprobe || echo /opt/homebrew/bin/ffprobe)}
FRAME_BUDGET=${FRAME_BUDGET:-6000000}

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 <source-recording>" >&2
  exit 64
fi
for tool in "$FFMPEG" "$FFPROBE"; do
  [ -x "$tool" ] || { echo "missing $tool (brew install ffmpeg)" >&2; exit 69; }
done

SRC_ARG=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ASSETS="$ROOT/assets"
SRC_ABS=$(cd "$(dirname "$SRC_ARG")" && pwd)/$(basename "$SRC_ARG")
TMP=$(mktemp -d "${TMPDIR:-/tmp}/demo-assets.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Private copy: the source may even be one of the files that get replaced.
cp "$SRC_ABS" "$TMP/source"
SRC="$TMP/source"

ff() { "$FFMPEG" -hide_banner -loglevel error -nostdin -y "$@"; }
probe() { "$FFPROBE" -v error -select_streams v:0 -show_entries "$1" -of default=nw=1:nk=1 "$2" | head -1; }
bytes() { wc -c < "$1" | tr -d ' '; }
mb() { awk -v b="$1" 'BEGIN { printf "%.2f MB", b / 1000000 }'; }

SRC_W=$(probe stream=width "$SRC")
SRC_H=$(probe stream=height "$SRC")
[ -n "$SRC_W" ] || { echo "no video stream in $SRC_ARG" >&2; exit 65; }
echo "source: $SRC_ARG (${SRC_W}x${SRC_H})"
case "$(probe stream=color_primaries "$SRC")" in
  smpte432|smpte431|bt2020)
    echo "note: the recording is tagged with a wide-gamut color space; the outputs assume BT.709/sRGB," \
         "so colors may look slightly off. Record or export in sRGB if that matters." ;;
esac

# Timestamps start at 0, square pixels (browsers draw JPEGs with square pixels),
# frame rate normalised per output; never upscale; even sizes.
PRE="setpts=PTS-STARTPTS,scale='trunc(iw*sar/2)*2':ih,setsar=1"
scale() { echo "scale='trunc(min($1,iw)/2)*2':-2:flags=lanczos:$2,setsar=1"; }
X264="-c:v libx264 -preset slow -profile:v high -pix_fmt yuv420p -bf 0 -sc_threshold 0"
CLEAN="-an -sn -dn -map_metadata -1 -map_chapters -1 -movflags +faststart"

echo "encoding assets/demo.mp4 ..."
# shellcheck disable=SC2086
ff -i "$SRC" -vf "$PRE,fps=30,$(scale 1280 out_range=tv)" $X264 -crf 22 -g 10 -keyint_min 10 $CLEAN "$TMP/demo.mp4"

echo "encoding assets/demo-mobile.mp4 ..."
# shellcheck disable=SC2086
ff -i "$SRC" -vf "$PRE,fps=30,$(scale 720 out_range=tv)" $X264 -crf 24 -g 15 -keyint_min 15 $CLEAN "$TMP/demo-mobile.mp4"

echo "extracting assets/poster.jpg ..."
ff -i "$SRC" -vf "$PRE,$(scale 1280 out_color_matrix=bt601:out_range=pc),format=yuvj420p" -frames:v 1 -q:v 4 "$TMP/poster.jpg"

# Frame sequence: 15 fps slots, frames identical to the previous kept one are
# dropped (mpdecimate), each file is named by its slot. If the set exceeds the
# phone budget, step down quality first, then frame rate.
SLOTS=0; FPS=0; Q=0; TOTAL=0
for setting in "15 10" "15 12" "12 12" "10 14" "8 16"; do
  set -- $setting
  FPS=$1; Q=$2
  rm -rf "$TMP/frames"; mkdir "$TMP/frames"
  echo "extracting frames: ${FPS} fps, quality $Q ..."
  ff -i "$SRC" -vf "$PRE,fps=$FPS,$(scale 720 out_color_matrix=bt601:out_range=pc),format=yuvj420p,mpdecimate" \
     -fps_mode vfr -c:v mjpeg -q:v "$Q" -frame_pts 1 "$TMP/frames/%05d.jpg"
  TOTAL=$(cat "$TMP"/frames/*.jpg | wc -c | tr -d ' ')
  [ "$TOTAL" -le "$FRAME_BUDGET" ] && break
  echo "  $(mb "$TOTAL") is over the $(mb "$FRAME_BUDGET") budget, trying smaller"
done
# Number of 15 fps slots in the clip (before dropping repeats).
SLOTS=$("$FFMPEG" -hide_banner -loglevel error -nostdin -i "$SRC" -vf "$PRE,fps=$FPS" -f null - -progress pipe:1 \
        | sed -n 's/^frame=//p' | tail -1)
KEEP=$(cd "$TMP/frames" && ls -- *.jpg | sed -e 's/\.jpg$//' -e 's/^0*//' -e 's/^$/0/' | sort -n | paste -sd, -)
COUNT=$(ls "$TMP/frames" | wc -l | tr -d ' ')
FIRST=$(ls "$TMP/frames" | head -1)
FW=$(probe stream=width "$TMP/frames/$FIRST")
FH=$(probe stream=height "$TMP/frames/$FIRST")
DUR=$(probe stream=duration "$TMP/demo.mp4")
VER=$(cat "$SRC" "$0" | shasum -a 256 | cut -c1-10)   # cache key: source + these settings
case ",$KEEP," in ,0,*) ;; *) echo "frame sequence does not start at slot 0" >&2; exit 70;; esac
printf '{"v":"%s","fps":%s,"slots":%s,"width":%s,"height":%s,"duration":%s,"keep":[%s]}\n' \
  "$VER" "$FPS" "$SLOTS" "$FW" "$FH" "$DUR" "$KEEP" > "$TMP/frames/manifest.json"

# Swap everything in at once.
mkdir -p "$ASSETS"
rm -rf "$ASSETS/demo-frames.new"
mv "$TMP/frames" "$ASSETS/demo-frames.new"
rm -rf "$ASSETS/demo-frames"
mv "$ASSETS/demo-frames.new" "$ASSETS/demo-frames"
mv "$TMP/demo.mp4" "$TMP/demo-mobile.mp4" "$TMP/poster.jpg" "$ASSETS/"

VW=$(probe stream=width "$ASSETS/demo.mp4"); VH=$(probe stream=height "$ASSETS/demo.mp4")
MW=$(probe stream=width "$ASSETS/demo-mobile.mp4"); MH=$(probe stream=height "$ASSETS/demo-mobile.mp4")
D_BYTES=$(bytes "$ASSETS/demo.mp4"); M_BYTES=$(bytes "$ASSETS/demo-mobile.mp4"); P_BYTES=$(bytes "$ASSETS/poster.jpg")
F_BYTES=$(cat "$ASSETS"/demo-frames/* | wc -c | tr -d ' ')

echo
echo "assets (clip ${DUR} s):"
printf '  %-30s %10s  %s\n' "demo.mp4" "$(mb "$D_BYTES")" "${VW}x${VH}, 30 fps, desktop scrub + playback"
printf '  %-30s %10s  %s\n' "demo-mobile.mp4" "$(mb "$M_BYTES")" "${MW}x${MH}, 30 fps, phone playback"
printf '  %-30s %10s  %s\n' "demo-frames/ ($COUNT images)" "$(mb "$F_BYTES")" "${FW}x${FH}, $COUNT of $SLOTS slots at $FPS fps, JPEG q$Q, phone scrub"
printf '  %-30s %10s  %s\n' "poster.jpg" "$(mb "$P_BYTES")" "first frame"
echo "  phone scrub payload:   $(mb $((F_BYTES + P_BYTES))) (frames + poster, loaded as the demo approaches)"
echo "  desktop scrub payload: $(mb $((D_BYTES + P_BYTES))) (video + poster)"

# Things in index.html that depend on the clip (read only, nothing is edited).
HTML="$ROOT/index.html"
if [ -f "$HTML" ]; then
  echo
  echo "caption timings in index.html are fractions of the clip; with this clip they fall at:"
  grep -o 'data-from="[0-9.]*" *data-to="[0-9.]*"[^>]*>.*</p>' "$HTML" | while read -r line; do
    from=$(echo "$line" | sed 's/.*data-from="\([0-9.]*\)".*/\1/')
    to=$(echo "$line" | sed 's/.*data-to="\([0-9.]*\)".*/\1/')
    text=$(echo "$line" | sed -e 's/^[^>]*>//' -e 's/<[^>]*>//g')
    awk -v f="$from" -v t="$to" -v d="$DUR" -v s="$text" \
      'BEGIN { if (t > 1) t = 1; printf "  %5.1f s - %5.1f s  %s\n", f * d, t * d, s }'
  done
  CSS_AR=$(sed -n 's/.*aspect-ratio: *\([0-9.]*\) *\/ *\([0-9.]*\).*/\1 \2/p' "$HTML" | head -1)
  if [ -n "$CSS_AR" ]; then
    awk -v css="$CSS_AR" -v w="$VW" -v h="$VH" 'BEGIN {
      split(css, a, " "); r = a[1] / a[2]; v = w / h; d = (r > v ? r / v : v / r) - 1
      if (d > 0.005) printf "\nnote: the .demo-frame rule in index.html uses %s / %s (aspect-ratio and width), the clip is %d / %d;\n      replace both with the new ratio to avoid a layout shift when the demo loads.\n", a[1], a[2], w, h
    }'
  fi
fi
case "$SRC_ABS" in
  "$ASSETS"/*) echo; echo "note: the source was inside assets/ and has been replaced by its encode; keep the original recording elsewhere." ;;
esac
