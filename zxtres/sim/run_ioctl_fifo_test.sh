#!/usr/bin/env bash
# Simulate zxtres_ioctl_fifo between a data_io model and a ROM loader model
# (zxtres/sim/zxtres_ioctl_fifo_tb.sv). Run from WSL or Linux with verilator.
#
#   zxtres/sim/run_ioctl_fifo_test.sh
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcxt/ioctl-fifo-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_ioctl_fifo_tb \
  --Mdir "$out/obj" -o ioctl_fifo_sim zxtres/rtl/zxtres_ioctl_fifo.sv zxtres/sim/zxtres_ioctl_fifo_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/ioctl_fifo_sim"
