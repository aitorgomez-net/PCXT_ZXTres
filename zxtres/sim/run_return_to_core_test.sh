#!/usr/bin/env bash
# Simulate the ICAP warm boot of the OSD "Reload ZX core" entry
# (zxtres/sim/zxtres_return_to_core_tb.sv). Run from WSL or Linux with
# verilator.
#
#   zxtres/sim/run_return_to_core_test.sh
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcxt/return-to-core-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_return_to_core_tb \
  --Mdir "$out/obj" -o return_to_core_sim zxtres/sim/xilinx_clock_models.sv \
  DeMiSTify/templates/zxtres/zx3w/return_to_core1.v zxtres/sim/zxtres_return_to_core_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/return_to_core_sim"
