#!/usr/bin/env bash
# Simulate zxtres_ps2_kbd_relay with the machine's KFPS2KB keyboard converter
# (zxtres/sim/zxtres_ps2_kbd_relay_tb.sv). Run from WSL or Linux with verilator.
#
#   zxtres/sim/run_ps2_kbd_relay_test.sh
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcxt/ps2-kbd-relay-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
kb=rtl/KFPC-XT/HDL/KFPS2KB/HDL
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_ps2_kbd_relay_tb \
  --Mdir "$out/obj" -o ps2_kbd_relay_sim \
  zxtres/rtl/zxtres_ps2_kbd_relay.sv "$kb/KFPS2KB_Shift_Register.sv" "$kb/KFPS2KB.sv" "$kb/KFPS2KB_Send_Data.sv" \
  zxtres/sim/zxtres_ps2_kbd_relay_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/ps2_kbd_relay_sim"
