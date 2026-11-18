#!/usr/bin/env bash
# Board-level simulation of the PCXT ZXTRES+ target booting a real BIOS
# (zxtres/sim/zxtres_pcxt_bios_tb.sv). Run from WSL or Linux with ghdl,
# verilator, gcc, make and python3:
#
#   zxtres/sim/run_bios_sim.sh [PCXT_ROM [EC00_ROM]] [plusargs...]
#
# The ROMs default to SW/ROMs/pcxt_pcxt31.rom and SW/ROMs/ide_xtl.rom; they
# go into the simulated SD card as PCXT/PCXT.ROM and PCXT/EC00.ROM, with a
# PCXT/PCXT.CFG whose settings skip the boot splash and run the CPU at Max,
# to keep the run short. Plusargs pass to the testbench, e.g. +POST_MS=3000
# +OSD +KEYS=0076. Frames go to build/zxtres-pcxt/bios-sim.
#
# ZXTRES_SIM_CFG=file is PCXT/PCXT.CFG instead (sim/make_cfg_file.py).
# ZXTRES_SIM_LOW=hex is the low status word of that file instead (60300: CPU
# at Max, splash 0 s). ZXTRES_SIM_VHD=file is DISKS/BOOT.VHD, mounted as the
# first hard disk. ZXTRES_SIM_EXTRA="file ..." puts more files on the card's
# root, or in a folder as FOLDER/NAME.EXT=file. ZXTRES_SIM_OUT=dir replaces
# the output directory. ZXTRES_SIM_KEEP_FIRMWARE=1 uses the firmware already
# built; a Vivado build rebuilds it in the same directory, so the two must not
# run together.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
pcxt_rom=SW/ROMs/pcxt_pcxt31.rom
ec00_rom=SW/ROMs/ide_xtl.rom
if [[ $# -gt 0 && "$1" != +* ]]; then pcxt_rom=$1; shift; fi
if [[ $# -gt 0 && "$1" != +* ]]; then ec00_rom=$1; shift; fi
pcxt_rom=$(realpath "$pcxt_rom"); ec00_rom=$(realpath "$ec00_rom")
out="${ZXTRES_SIM_OUT:-$root/build/zxtres-pcxt/bios-sim}"
profile=${PCXT_PROFILE:-mister_pcxt_full}

if [[ -z "${ZXTRES_SIM_KEEP_FIRMWARE:-}" ]]; then
  mkdir -p build
  bash zxtres/scripts/build_firmware.sh > build/zxtres-pcxt-firmware.log 2>&1 \
    || { tail -20 build/zxtres-pcxt-firmware.log >&2; exit 1; }
fi
rm -rf "${out:?}"
mkdir -p "$out/files" "$out/ghdl" "$out/patched"
cp "$pcxt_rom" "$out/files/PCXT.ROM"
cp "$ec00_rom" "$out/files/EC00.ROM"
card=("PCXT/PCXT.ROM=$out/files/PCXT.ROM" "PCXT/EC00.ROM=$out/files/EC00.ROM")
if [[ -n "${ZXTRES_SIM_CFG:-}" ]]; then
  cp "$ZXTRES_SIM_CFG" "$out/files/PCXT.CFG"
else
  disk=()
  [[ -n "${ZXTRES_SIM_VHD:-}" ]] && disk=(--disk0 DISKS/BOOT.VHD)
  python3 zxtres/sim/make_cfg_file.py "$out/files/PCXT.CFG" --low "${ZXTRES_SIM_LOW:-60300}" "${disk[@]}"
fi
card+=("PCXT/PCXT.CFG=$out/files/PCXT.CFG")
if [[ -n "${ZXTRES_SIM_VHD:-}" ]]; then
  cp "$ZXTRES_SIM_VHD" "$out/files/BOOT.VHD"
  card+=("DISKS/BOOT.VHD=$out/files/BOOT.VHD")
fi
for file in ${ZXTRES_SIM_EXTRA:-}; do
  card+=("$file")
done
python3 zxtres/sim/make_fat16_image.py "$out/sd.img" "${card[@]}"
rm -f "$out/sd.img"                      # keep only the sparse form
# Memory images, loaded with $readmemh by name.
cp rtl/8088/mcl86_ucode.mem rtl/video/cga.hex rtl/video/hgc.hex rtl/common/font0.hex "$out/"
cp zxtres/splash/splash_320x200.hex zxtres/credits/msg.bin "$out/"
python3 zxtres/scripts/make_mem.py osdfont rtl/common/font0.hex "$out/osd_font.mem"

ghdl_flags=(--std=08 -frelaxed -fsynopsys --workdir="$out/ghdl")
# The DeMiSTify controller (VHDL), converted to Verilog by GHDL. GHDL fixes each
# generic at its default, which is what zxtres_pcxt_top uses.
controller=(
  zxtres/demistify/demistify_config_pkg.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_pkg.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_shifter.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_alu.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_aligner.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_aligner_le.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_decode.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_fetchloadstore.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_hazard.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_debug.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_cpu.vhd
  DeMiSTify/controller/simple_uart.vhd
  DeMiSTify/controller/jtag_uart.vhd
  zxtres/sim/debug_bridge_jtag_stub.vhd
  DeMiSTify/controller/io_ps2_com.vhd
  DeMiSTify/controller/interrupt_controller.vhd
  DeMiSTify/controller/timer_controller.vhd
  DeMiSTify/controller/spi_controller.vhd
  build/zxtres-pcxt/firmware/controller_rom1_word.vhd
  build/zxtres-pcxt/firmware/controller_rom2_word.vhd
  DeMiSTify/firmware/controller_rom.vhd
  DeMiSTify/controller/substitute_mcu.vhd
  DeMiSTify/templates/demistify/common/joystick_sega.vhd
)
mapfile -t uart < <(python3 zxtres/scripts/pcxt_sources.py vhdl | tr -d '\r')
for source in "${controller[@]}" "${uart[@]}"; do
  ghdl -a "${ghdl_flags[@]}" "$source" 2>&1 | grep -v ":warning:" | grep -v "^\s" || true
done
for unit in substitute_mcu joystick_sega uart_16750; do
  ghdl synth "${ghdl_flags[@]}" --out=verilog "$unit" > "$out/ghdl/$unit.vg" 2> "$out/ghdl/$unit.log"
  python3 zxtres/sim/fix_ghdl_verilog.py "$out/ghdl/$unit.vg"
done
# GHDL fixes the UART at RX_MIDSTOP 0 and drops the generic; uart.v still
# passes it (1 for COM2, which has no pins on the board), so the converted
# module takes it and ignores it.
sed -i 's/^module uart_16750$/module uart_16750 #(parameter RX_MIDSTOP = 0)/' "$out/ghdl/uart_16750.vg"
for source in mist-modules/user_io.v mist-modules/data_io.v; do
  sed "s/1'b[zZ]/1'b1/g" "$source" > "$out/patched/$(basename "$source")"
done

# The machine options of the MiSTer profile, less MIDI, as in build_pcxt.sh.
mapfile -t defines < <(sed -n 's/^set_global_assignment -name VERILOG_MACRO "\([A-Z0-9_]*\)=\([0-9]*\)".*/\1=\2/p' \
                         "profiles/$profile.tcl" | grep -v '^ENABLE_MIDI=' | tr -d '\r')
defines+=(ENABLE_MIDI=0)
mapfile -t sv < <(python3 zxtres/scripts/pcxt_sources.py sv | tr -d '\r')
# Verilator 5.020 refuses the constant tables of saa1099.sv declared as nets
# with an initializer; the simulation copy declares them as variables, which
# Quartus and Vivado read the same way. The repository file is not changed.
sed -E 's/^wire( +)(phases\[8\]|\[1:0\] env\[8\]\[2\]|\[3:0\] levels\[4\]\[16\]) =/logic\1\2 =/' \
  rtl/sound/saa1099.sv > "$out/patched/saa1099.sv"
for i in "${!sv[@]}"; do
  [[ "${sv[$i]}" == rtl/sound/saa1099.sv ]] && sv[$i]="$out/patched/saa1099.sv"
done
mapfile -t includes < <(python3 zxtres/scripts/pcxt_sources.py includes | tr -d '\r')
# -Wno-BLKANDNBLK: XT2IDE.sv drives the high byte of ide_data_bus_out from a
# flip-flop and the low byte from combinational logic, which Verilator
# refuses for one variable unless told.
verilator --binary --timing -O2 +1364-2005ext+vg --x-initial fast -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK \
  -j "$(nproc)" -I"$root" "${includes[@]/#/-I}" --top-module zxtres_pcxt_bios_tb \
  "${defines[@]/#/+define+}" \
  --Mdir "$out/obj" -o bios_sim \
  zxtres/sim/xilinx_clock_models.sv zxtres/rtl/zxtres_dpram.sv "$out"/ghdl/*.vg "${sv[@]}" \
  mist-modules/scandoubler/scandoubler_framing.v zxtres/rtl/zxtres_linedouble.sv \
  zxtres/rtl/zxtres_sram_ctrl.sv zxtres/rtl/zxtres_scanconv.sv zxtres/sim/zxtres_sram_model.sv \
  "$out/patched/user_io.v" "$out/patched/data_io.v" zxtres/rtl/zxtres_osd.sv \
  DeMiSTify/templates/demistify/common/joydecoder_neptuno.v \
  DeMiSTify/templates/zxtres/zx3w/sigma_delta_codec.v DeMiSTify/templates/zxtres/zx3w/i2s_sound.v \
  DeMiSTify/templates/zxtres/zx3w/return_to_core1.v \
  zxtres/rtl/zxtres_ps2_rx.sv zxtres/rtl/zxtres_ps2_key.sv zxtres/rtl/zxtres_ps2_kbd_relay.sv \
  zxtres/rtl/zxtres_ioctl_fifo.sv zxtres/rtl/zxtres_status_ext.sv zxtres/rtl/zxtres_ide_store.sv zxtres/rtl/zxtres_fdd_store.sv \
  zxtres/rtl/zxtres_sd_arb.sv zxtres/rtl/zxtres_vidinfo.sv zxtres/rtl/pcxt_zxtres_guest.sv \
  zxtres/rtl/zxtres_pcxt_top.sv rtl/mem/TESTBENCH/sdram_model.sv \
  zxtres/sim/sd_card_model.sv zxtres/sim/zxtres_pcxt_bios_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }

(cd "$out" && ./obj/bios_sim "$@") | tee "$out/sim.log" | grep -v heartbeat
for frame in "$out"/*.ppm; do
  [[ -e "$frame" ]] && python3 zxtres/scripts/ppm_to_png.py "$frame" "${frame%.ppm}.png"
done
ls "$out"/*.png 2>/dev/null || true
