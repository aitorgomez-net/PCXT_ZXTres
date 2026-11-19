#!/usr/bin/env bash
# Simulate zxtres_linedouble on a 200-line picture (must be doubled to 31 kHz)
# and on a 350-line one (must pass through).
#
#   zxtres/sim/run_linedouble_test.sh
#
# Run from WSL or Linux with verilator.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcxt/linedouble-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_linedouble_tb \
  --Mdir "$out/obj" -o sim \
  \
  mist-modules/scandoubler/scandoubler_framing.v \
  zxtres/rtl/zxtres_linedouble.sv \
  zxtres/sim/zxtres_linedouble_tb.sv > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/sim" +LINES=200 +PERIOD=4
"$out/obj/sim" +LINES=350 +PERIOD=4
# Scandoubler off: the 200-line picture is not doubled, and leaves with +HSync, +VSync (idle low).
"$out/obj/sim" +LINES=200 +PERIOD=4 +OFF=1

# A CGA's 6845 VSync is 16 lines: undoubled it is held to 3 (vs_pin_lines_x10 of about 30), doubled to 7 lines of 31 kHz.
"$out/obj/sim" +LINES=200 +PERIOD=4 +OFF=1 +VSLINES=16
"$out/obj/sim" +LINES=200 +PERIOD=4 +VSLINES=16
