#!/usr/bin/env bash
# The hard disk path from the machine's IDE device to the DeMiSTify firmware
# (zxtres/sim/zxtres_hdd_chain_tb.sv): ide.v, the IDE and floppy stores, the
# SD arbiter and the real MiST user_io driven over SPI by a firmware model.
# Usage: run_hdd_chain_test.sh <hdd0 image> [floppy A image]
# Needs verilator. Prints ZXTRES_HDD_CHAIN_PASS on success.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
hdd0=$(realpath "$1")
fda=${2:+$(realpath "$2")}
out="$root/build/zxtres-pcxt/hdd-chain-test"
cd "$root"
mkdir -p "$out"

# user_io releases MISO with 1'bZ, which Verilator does not model
sed "s/SPI_MISO <= 1'bZ;/SPI_MISO <= 1'b1;/" mist-modules/user_io.v > "$out/user_io.v"
if [ ! -x "$out/obj/hdd_chain_test" ] || [ -n "$(find zxtres/rtl zxtres/sim rtl/common/ide.v mist-modules/user_io.v -newer "$out/obj/hdd_chain_test" -name '*.*v' | head -1)" ]; then
  verilator --binary --timing -O2 -Wno-fatal --top-module zxtres_hdd_chain_tb \
    --Mdir "$out/obj" -o hdd_chain_test \
    zxtres/rtl/zxtres_dpram.sv rtl/common/ide.v zxtres/rtl/zxtres_ide_store.sv \
    zxtres/rtl/zxtres_fdd_store.sv zxtres/rtl/zxtres_sd_arb.sv "$out/user_io.v" \
    zxtres/sim/zxtres_hdd_chain_tb.sv > "$out/verilator-build.log" 2>&1 \
    || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
fi
args=(+HDD0="$hdd0" ${EXTRA:-})
[ -n "$fda" ] && args+=(+FDA="$fda")
"$out/obj/hdd_chain_test" "${args[@]}" | tee "$out/run.log"
grep -q ZXTRES_HDD_CHAIN_PASS "$out/run.log"
