# Profile zx3_a35t_tandy1000: a Tandy 1000 for the ZXTres with the XC7A35T, kept to
# what the real machine had, plus AdLib. CGA with the Tandy video modes (video
# memory shared with the system RAM), Tandy BIOS, Tandy keyboard, SN76489 sound;
# OPL2 at 388h (AdLib, which most Tandy-era games support). No Hercules, EGA,
# C/MS or Sound Blaster, no RTC (most Tandy 1000 models had none) and one serial
# port (COM1, with the serial mouse).
# Sourced by config.tcl / build_pcxt.sh; see scripts/config_check.tcl.
set_global_assignment -name VERILOG_MACRO "SYSTEM_VARIANT_TANDY=1"
set_global_assignment -name VERILOG_MACRO "ROM_VARIANT_TANDY=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_VIDEO=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_AUDIO=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_KBD=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_CGA=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_HGC=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_EGA=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_EMS=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_A000_UMB=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_UMB=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_OPL2=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_CMS=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_SB=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_MIDI=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_RTC=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_COM2=0"
