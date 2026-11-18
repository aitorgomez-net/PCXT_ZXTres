#!/usr/bin/env bash
# Draw the OSD pages saved by the board simulation's +OSD_TOUR
# (zxtres/sim/run_bios_sim.sh +OSD_TOUR or +OSD_ZXCORE) as PNG frames: each .osd in
# DIR becomes a .png beside it, the box over a grey 640x400 picture.
#
#   zxtres/sim/render_osd_tour.sh [DIR]
#
# DIR defaults to build/zxtres-pcxt/bios-sim. Run from WSL or Linux with
# verilator and python3.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
dir=$(realpath "${1:-build/zxtres-pcxt/bios-sim}")
out="$root/build/zxtres-pcxt/osd-render"
rm -rf "${out:?}"
mkdir -p "$out"
python3 zxtres/scripts/make_mem.py osdfont rtl/common/font0.hex "$out/osd_font.mem"
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_osd_tb \
  --Mdir "$out/obj" -o osd_sim zxtres/rtl/zxtres_osd.sv zxtres/sim/zxtres_osd_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
for page in "$dir"/*.osd; do
  name=$(basename "$page")
  cp "$page" "$out/$name"
  (cd "$out" && ./obj/osd_sim +ROWS="$name" > /dev/null)
  python3 zxtres/scripts/ppm_to_png.py "$out/$name.ppm" "$dir/${name%.osd}.png"
  echo "$dir/${name%.osd}.png"
done
