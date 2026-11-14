#!/bin/bash
# Records a short demo of Encore with whatever song is playing, and writes
# media/encore-demo.mp4 and media/encore-demo.gif.
#
# Play a song first (one with lyrics shows the most), then run this. Encore
# covers the screen with a stand-in lock screen and runs itself for about
# twenty seconds: the card, the cover opening to full screen, the lyrics, and
# back. Nothing on your desktop is in the recording. Needs ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Encore.app
[ -d "$APP" ] || ./scripts/build.sh
mkdir -p media

# ffmpeg lists the screens and then exits with an error, which is expected.
SCREEN=$( (ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true) | grep -m1 "Capture screen" | sed -E 's/.*\[([0-9]+)\] Capture.*/\1/')

pkill -x Encore 2>/dev/null || true
sleep 1

# Encore says when the stand-in lock screen is up and a song is showing.
# Recording starts only after that, so the desktop is never in the picture.
READY="${TMPDIR:-/tmp}/encore-tour-ready"
READY="${READY//\/\///}"
rm -f "$READY"
open "$APP" --args --tour
for _ in $(seq 1 100); do
    [ -e "$READY" ] && break
    sleep 0.15
done
if [ ! -e "$READY" ]; then
    pkill -x Encore 2>/dev/null || true
    open /Applications/Encore.app 2>/dev/null || true
    echo "Nothing is playing, so there was nothing to record. Play a song and run this again."
    exit 1
fi
rm -f "$READY"

ffmpeg -hide_banner -loglevel error -y -f avfoundation -framerate 30 -capture_cursor 0 -i "$SCREEN:none" \
    -t 17.8 -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p media/raw.mp4

pkill -x Encore 2>/dev/null || true

# Trim the empty edges, keeping the clock at the top, so the player and the
# lyrics are a little larger in the frame.
CROP="crop=iw*0.88:ih*0.88:iw*0.06:0"

ffmpeg -hide_banner -loglevel error -y -i media/raw.mp4 -vf "$CROP,scale=1920:-2:flags=lanczos" -r 30 \
    -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart media/encore-demo.mp4
ffmpeg -hide_banner -loglevel error -y -i media/raw.mp4 \
    -vf "$CROP,fps=18,scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=200[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
    media/encore-demo.gif
rm media/raw.mp4

# Put the everyday Encore back.
open /Applications/Encore.app 2>/dev/null || open "$APP"

ls -lh media/encore-demo.mp4 media/encore-demo.gif | awk '{print $5, $9}'
