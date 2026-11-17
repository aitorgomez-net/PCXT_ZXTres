#!/usr/bin/env bash
# Simulate zxtres_status_ext beside MiST user_io on the controller's SPI
# (zxtres/sim/zxtres_status_ext_tb.sv). Run from WSL or Linux with verilator.
#
#   zxtres/sim/run_status_ext_test.sh
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcxt/status-ext-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
verilator --lint-only -Wall -Wno-DECLFILENAME --top-module zxtres_status_ext zxtres/rtl/zxtres_status_ext.sv
# user_io's tristate MISO as a plain output, as in run_bios_sim.sh.
sed "s/1'b[zZ]/1'b1/g" mist-modules/user_io.v > "$out/user_io.v"
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_status_ext_tb \
  --Mdir "$out/obj" -o status_ext_sim "$out/user_io.v" zxtres/rtl/zxtres_status_ext.sv \
  zxtres/sim/zxtres_status_ext_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/status_ext_sim"
