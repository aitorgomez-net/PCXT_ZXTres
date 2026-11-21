# Profile zx3_a35t_pcxt_ega: an IBM PCXT with the EGA card for the ZXTres with the
# XC7A35T. mister_pcxt_ega less what does not fit the small FPGA: no C/MS, no RTC.
# Sound: OPL2 (AdLib / SB FM), Sound Blaster and the Tandy SN76489 at 0C0h.
# No COM2 (the board has no pins for it) and no MIDI.
# Sourced by build_pcxt.sh (PCXT_PROFILE); see scripts/config_check.tcl.

# Option layout of the OSD: the EGA one
set_global_assignment -name VERILOG_MACRO "LAYOUT_EGA=1"
set_global_assignment -name VERILOG_MACRO "SYSTEM_VARIANT_TANDY=0"
set_global_assignment -name VERILOG_MACRO "ROM_VARIANT_TANDY=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_VIDEO=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_AUDIO=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_KBD=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_CGA=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_HGC=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_EGA=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_EMS=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_A000_UMB=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_UMB=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_OPL2=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_CMS=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_SB=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_MIDI=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_RTC=0"
set_global_assignment -name VERILOG_MACRO "ENABLE_COM2=0"
