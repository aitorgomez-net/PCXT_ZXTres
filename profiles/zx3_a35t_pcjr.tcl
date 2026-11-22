# Profile zx3_a35t_pcjr: an IBM PCjr for the ZXTres with the XC7A35T, as
# mister_pcjr: the CGA with the PCjr video gate array, the PCjr BIOS (slot 4),
# the infrared keyboard, the cartridges and the SN76489. A PCjr has no expansion
# slots, so no OPL2, C/MS, Sound Blaster or EMS (the core keeps them off on a
# PCjr anyway). No COM2 (the board has no pins for it) and no MIDI.
# Sourced by build_pcxt.sh (PCXT_PROFILE); see scripts/config_check.tcl.
# Option layout of the OSD: the EGA one. The ZXTres OSD (make_guest.py) feeds
# the machine its status word in that layout only; without it the composite,
# border, frame stacking, joystick swap, EMS and A000 UMB entries would be read
# from other bits (and the EMS frame would sit at C000h).
set_global_assignment -name VERILOG_MACRO "LAYOUT_EGA=1"
set_global_assignment -name VERILOG_MACRO "SYSTEM_VARIANT_PCJR=1"
set_global_assignment -name VERILOG_MACRO "ROM_VARIANT_PCJR=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_PCJR=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_VIDEO=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_AUDIO=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_KBD=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_CGA=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_HGC=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_EGA=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_EMS=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_A000_UMB=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_UMB=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_OPL2=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_CMS=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_SB=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_MIDI=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_COM2=0"
