# PCXT on the ZXTRES+ and ZXTRES++: specification

This file sets out what the ZXTRES+ port of PCXT must do, what exists today
and what is left to develop. The port reuses the board logic of the PCAT-286
ZXTres port (`aitorgomez-net/PCAT-286_ZXTres`), whose SPEC.md records how
that logic was built and checked. This file covers only what is specific to
the PC/XT machine.

Evidence levels used below:

- **Sim**: passes a simulation in `sim/`.
- **Built**: synthesizes and meets timing in Vivado.
- **Board**: observed on a ZXTRES+, with the date of the observation. Nothing
  in this port has reached this level yet.
- **Inherited**: the module is unchanged from the PCAT-286 port, where it
  reached the level stated there. This port does not re-establish that
  level.

## 1. Goal and scope

The goal is to run the PC/XT, Tandy 1000 and PCjr machine of PCXT_MiSTer on
the ZXTRES+ (XC7A100T) and the ZXTRES++ (XC7A200T, the same board with a
larger FPGA, built separately). The machine RTL must stay the MiSTer RTL, so
that a fix in one build reaches the other. Only the glue around the machine
is specific to the board. The core is a `.ZX3` file loaded from the microSD
card, with DeMiSTify for the controller, OSD and storage.

In scope:
- BIOS boot of the three machines;
- CGA (with the Tandy and PCjr modes), Hercules and EGA on the VGA output;
- the PS/2 keyboard and the serial mouse;
- the DB9 joysticks;
- floppy and XT-IDE hard disk images;
- the audio devices;
- the OSD settings that make sense on this board.

Out of scope on this board:

| MiSTer feature | Reason |
| --- | --- |
| MiSTer scaler, HDMI, aspect ratio, HQ2x, scanlines | Replaced by the PCAT-286 board video path. |
| DDR3 framebuffer for the 350-line modes at 15 kHz and 480p | Replaced by the SRAM scan converter (`zxtres_scanconv`). |
| COM2, MIDI, MPU-401, MT32-pi (user port) | No user port. `ENABLE_MIDI` is forced to 0 and the MT32 inputs are tied to 0. |
| Second SD card as an IDE disk | The one microSD slot belongs to the controller. |
| RTC from the HPS | No RTC on the board. |
| Analog joysticks | The DB9 ports are digital. |

## 2. Platform

See SPEC.md of the PCAT-286 port, sections 2.1 and 2.2, for the resources of
the board and for what DeMiSTify provides and where it stops. The limits that
shape this port:

- **Status bits.** DeMiSTify offers 64 status bits (option letters 0-9,
  A-Z and a-z, bits 0-61). The port widens it to 128: the firmware's own
  `statusword.c` sends sixteen bytes with `user_io`'s command 1Eh,
  `user_io` keeps the first eight and `zxtres_status_ext.sv` the rest, and
  the configuration string writes bits 64-127 as the bytes 80h-BFh, which
  the firmware's `configstring_getdigit()` reads. `make_guest.py` gives each
  OSD option a MiST bit and rebuilds the 128-bit MiSTer `status` from them,
  with fixed values for the options that are not offered.
- **No wait signal on `data_io`.** The PCXT ROM loader (`rom_loader`) writes
  the SDRAM only while the bus is held and raises `ioctl_wait`, but `data_io`
  has no wait input. `zxtres_ioctl_fifo` keeps up to 512 words between the
  two.
- **Raw PS/2 keyboard.** The machine's keyboard controller (`KFPS2KB`) takes
  the PS/2 wires, while DeMiSTify passes the keys to the core as bytes from
  the firmware. `zxtres_ps2_kbd_relay` turns the bytes back into a PS/2
  device, the way `hps_io`'s `ps2_device` does, and answers the keyboard
  commands the BIOS sends.

## 3. Current state

The work is on branch `main` and has not run on a board yet.

### 3.1 Done

| Piece | State | Where |
| --- | --- | --- |
| Repository: PCXT_MiSTer main at bd02ffa, DeMiSTify and mist-modules submodules pinned at the PCAT-286 versions | Done | `.gitmodules` |
| Toolchain: firmware from source, Vivado non-project flow to `.ZX3`, Tcl scripts that create the Vivado project | Shared with PCAT-286, renamed | `scripts/build_pcxt.sh`, `build_firmware.sh`, `make_vivado_tcl.py`, `bit_to_zx3.py` |
| Board top: controller, joysticks, PS/2, SD, SRAM, VGA and audio pins | Same top as PCAT-286, renamed | `rtl/zxtres_pcxt_top.sv`, `constraints/zxtres_pcxt.xdc` |
| Machine: MCL86 CPU, KFPC-XT chipset, CGA/Tandy/PCjr, HGC, EGA, EMS, UMBs, XT-IDE, floppy, serial mouse, gameport, Sound Blaster, OPL2, C/MS, Tandy sound, with the `mister_pcxt_full` options | Generated | `rtl/pcxt_zxtres_guest.sv`, which `scripts/make_guest.py` copies from `PCXT.sv`; `--check` catches drift |
| Clocks: 100 and 50 MHz from the board's 50 MHz; 114.545, 57.27 and 28.636 MHz for the video and the SDRAM (MMCM, VCO 630 MHz); 27 MHz for the scan converter | Written | guest `CLOCKS` |
| RAM in the board SDRAM through the MiSTer `sdram_ctrl` at 114.5 MHz | Written | guest |
| 128-bit status word: firmware `statusword.c` (send, get, cycle over four words), `configstring_getdigit()` for bits 64-127, `PCXT.CFG` version 2 with all 128 bits; RTL `zxtres_status_ext` beside `user_io` | Sim (`user_io` and the module on the controller's SPI: bits 0-63 and 64-127, other commands, a 64-bit 1Eh, transfers 5 ns apart) | `firmware/statusword.c`, `firmware/overrides.c`, `rtl/zxtres_status_ext.sv`, `sim/run_status_ext_test.sh` |
| PCjr RAM size (Hardware page, MiST bits 64-67) and tape sound (Audio page, bit 68), with MiSTer's values | Written | guest `CONF_STR` |
| PCjr cartridges: units K and L of the OSD page *BIOS*, ROM loader indices 5 and 6 (`.JRC` with its 512-byte header), for the session (not kept in `PCXT.CFG`); the machine restarts to see one, as on MiSTer | Written | `firmware/overrides.c`, guest `CONF_STR` |
| ROM loading: `PCXT.ROM`, `TANDY.ROM`, `EC00.ROM`, `EGA.ROM` and `PCJR.ROM` loaded by `autoboot()` with the machine held in reset; any other file can be chosen in the OSD page *BIOS*; paths kept in `PCXT.CFG` | Written; the queue in Sim (a loader model with a registered random wait: every word in order with its index and offset, files back to back with words of the previous one still queued) | `firmware/overrides.c`, `rtl/zxtres_ioctl_fifo.sv`, `sim/run_ioctl_fifo_test.sh` |
| Hard disks: the machine's XT-IDE served through the management window by `zxtres_ide_store` (units 0 and 1) | Inherited | `rtl/zxtres_ide_store.sv` |
| Floppies: the machine's floppy controller served by `zxtres_fdd_store` (units 3 and 4) | Inherited | `rtl/zxtres_fdd_store.sv` |
| Keyboard: the byte stream from the firmware to `KFPS2KB` through the PS/2 relay, with Win+F12 filtered out | Sim (against the machine's `KFPS2KB` and `KFPS2KB_Send_Data`: the BIOS keyboard reset answered with FAh AAh, make and break codes, Win+F12 kept and F12 alone passed, the keyboard's own replies dropped) | `rtl/zxtres_ps2_kbd_relay.sv`, `sim/run_ps2_kbd_relay_test.sh` |
| Mouse: the PS/2 mouse wires to `MSMouseWrapper` on COM1 | Written, as in PCAT-286 | guest |
| Video: CGA and EGA through the splash fade, HGC sampled at 57 MHz, then the F12 credits, the line doubler and the OSD; 350-line pictures through the SRAM scan converter; video information page | Written, modules inherited | guest `VIDEO_OUT` |
| Audio: the MiSTer mix (speaker, OPL2, C/MS, Tandy, Sound Blaster), the compressor and the stereo mix, to the sigma-delta and I2S outputs | Written | guest `AUDIO_STAGE` |
| OSD: title *PCXT ZXTres*, pages Video (with Output), Audio, Hardware, BIOS and Settings | Written | `rtl/zxtres_osd.sv` (`TITLE` parameter), guest `CONF_STR` |
| OSD entries that follow the machine and the card, as MiSTer's `status_menumask`: an entry starting with a flag byte `0xC0+n` in `CONF_STR` is shown only while bit `n` of `menu_mask()` is set (`0xE0+n`: while it is clear; one byte each because the string `user_io.v` serves ends at 2047 bytes, which `make_guest.py` enforces); hidden entries take no row | Written; the firmware builds, not yet seen on the board | `firmware/overrides.c` (`menu_mask()`), `scripts/expand_demistify_osd.py`, `scripts/make_guest.py` (`HIDE_*`) |
| Boot splash: the MiSTer picture with "MiSTer" redrawn as a striped, slanted "ZXTres" (T, r and e from the original word, Z, X and s drawn in the same lettering, white top stripes as in the PCAT-286 splash) | Done | `scripts/make_splash.py`, `splash/splash_320x200.hex`, used by `build_pcxt.sh` in place of `rtl/video/splash_320x200.hex` |
| F12 credits with the ZXTres art and the port's credits | Done | `credits/msg`, and `credits/msg.bin`, which is the first 8192 rows (four pages) of the binary output of the core's own `credits/msg2hex` |
| Unit tests of the shared modules | Inherited | `sim/` |
| `PCXT.CFG` writer for test cards (nine paths of 52 bytes, format `PCXT` version 2, as `overrides.c` reads it) | Done | `sim/make_cfg_file.py` |
| Return to the Spectrum core: *Reload ZX core* on the Settings page asks first, then the firmware sets status bit 69 (never saved in `PCXT.CFG`) and the board top sends the ICAP warm boot (IPROG, WBSTAR 0) through DeMiSTify's `zx3w/return_to_core1.v`, which reloads the core at flash address 0 | Sim (the ICAP words against an ICAPE2 model, and in the whole-board simulation from the OSD keys to the IPROG, `+OSD_ZXCORE`); on the A100T board it starts the Spectrum core directly, with or without the SD card | `firmware/overrides.c`, guest `CONF_STR`, `rtl/zxtres_pcxt_top.sv`, `sim/run_return_to_core_test.sh` |
| Whole-board simulation: the real firmware on the GHDL-converted controller reads `PCXT.CFG` and the ROMs from an SD card model, the ROM queue fills the SDRAM model behind the board's pin timing, the machine runs the Turbo XT BIOS 3.1; frames after the line doubler and the OSD; the OSD pages walked with the keyboard (`+OSD_TOUR`) | Sim (see 5.2) | `sim/run_bios_sim.sh`, `sim/zxtres_pcxt_bios_tb.sv`, `sim/render_osd_tour.sh` |

### 3.2 Not started

- Trying the A200T build on a ZXTRES++.
- DisplayPort and I/O timing constraints.

## 4. Decisions

| Decision | Reason |
| --- | --- |
| Board logic copied from PCAT-286, not shared through a submodule | The two repositories evolve separately. The copied files are byte-identical except `zxtres_osd.sv`, whose title became a parameter. A fix to one should be copied to the other. |
| MiST bit allocation in `make_guest.py` (`CONF_ENTRIES`) | One table drives both the `CONF_STR` and the remapping to MiSTer bits, so the two cannot drift. |
| The Output page (`P1P6`) declared after the BIOS files in `CONF_STR`, and `check_file_entries()` in `make_guest.py` | DeMiSTify's `buildmenu()` counts a page declared inside a page twice when it numbers the entries, and a file entry reads its extensions from the entry with its number: with Output first, every BIOS file took the extensions of the next entry, so *EC00 BIOS* listed only `.JRC` and `.BIN` files, no `.ROM` and *PCjr cart. 2* listed nothing. The generator now repeats the firmware's count and stops on such an order. |
| MiSTer bits fixed instead of offered: MPU-401 off (bit 88) | No MIDI on the board. |
| Status word widened to 128 bits in the port's firmware and RTL, not in DeMiSTify or mist-modules | The submodules stay as they are: the firmware replaces DeMiSTify's `statusword.c` at build time and overrides the weak `configstring_getdigit()`, and a separate module reads bytes 9-16 of the command that `user_io` stops at 8. |
| Joystick type offered with Digital first | The DB9 ports are digital; MiSTer offers Analog first. The OSD value is remapped. |
| The ROM loader waits behind a FIFO | `rom_loader` writes only while the CPU bus is held. During reset the hold is granted at once, so the FIFO only needs to absorb the SDRAM refresh and arbitration latency. Each word carries the parity of its download: when the firmware starts the next ROM before the loader has taken the last words of the previous one, those words keep their index, and the next download reaches the loader after a few idle clocks. The first version changed the index under the queued words; the test caught it. |
| Win+F12 filtered at byte level before the PS/2 relay | The OSD key must not reach the machine. F12 alone stays with the machine, for the credits and the splash. |
| Machine files with `` `default_nettype none `` and untyped ports relaxed in the build copy | The Graphics Gremlin files (HGC, CGA ports) declare ports with no net type, which Quartus accepts and Vivado refuses. The repository file is not changed. `build_pcxt.sh` writes `` `default_nettype wire `` into the frozen copy, and `make_vivado_tcl.py` puts that copy into `zxtres/vivado/generated`. |
| `HBlank_VGA` declared `reg` in the guest | `PCXT.sv` declares it `wire` and assigns it in `always @*`, which Quartus accepts and Vivado refuses. `make_guest.py` changes the declaration. |

## 5. Remaining work

Priority: **P0** blocks a usable core, **P1** is part of the scope, **P2** is
optional. Size: **S** is days, **M** is a week or two, **L** is longer.

### 5.0 First build (P0, S)

The A100T builds and closes timing (17 November 2026): 29.8k LUTs (47 %),
17.3k registers, 30 of 135 block RAM tiles, WNS +0.002 ns, WHS +0.053 ns, no
critical warnings. The worst path runs from `splash_pending` (on the
register-derived `clk_14_318`) to the `hgc_*_meta` registers, which sample
the Hercules picture at 114.5 MHz. Most of that path is clock skew, and MiSTer
leaves it timed. The worst per-clock slacks are clk_114 +0.76 ns,
clk_chipset +0.90 ns and clk_100 +2.1 ns. Getting there needed the
constraints of section 4 and the exceptions of MiSTer's `SYSTEM.sdc`: the
configuration latched at reset, `splash_off`, and the 27 MHz clock
asynchronous to all others.

The build of the same day with the PCjr cartridges, the ROM queue fix and
the narrower `default_nettype` handling has WNS +0.321 ns, WHS +0.056 ns,
29.8k LUTs, 17.3k registers, 30 block RAM tiles, no critical warnings. With
the 128-bit status word (`zxtres_status_ext`, PCjr RAM and Tape sound in the
OSD) it has WNS +0.102 ns, WHS +0.052 ns, 29.8k LUTs, 17.3k registers, 30
block RAM tiles, no critical warnings; with the OSD page order and names fixed,
WNS +0.093 ns and WHS +0.039 ns; with the return to the Spectrum core, WNS
+0.210 ns and WHS +0.028 ns. The slack moves from build to build by a few
hundred picoseconds.

The A200T build (`build_pcxt.sh A200T`, `xc7a200tfbg484-2`) of the same
sources has WNS +0.343 ns, WHS +0.051 ns, 29.8k LUTs, 17.4k registers, 30
block RAM tiles and no critical warnings; it has not been tried on a board.

Still to do: watch the `clk_14_318` to clk_114 crossing,
which has little margin of its own.

### 5.1 First board bring-up (P0, S)

1. The splash and the OSD appear.
2. `PCXT.ROM` loads and the BIOS POST runs.
3. The keyboard answers the POST test (the FF reset and the AA reply through
   the relay).
4. A floppy boots.
5. The XT-IDE BIOS (`EC00.ROM`) finds a hard disk image.

Then the same steps with the Tandy and PCjr machines, and with the EGA and
Hercules cards.

### 5.2 Whole-board simulation (P1, M)

`run_bios_sim.sh` runs the whole board: the firmware loads `PCXT.ROM` and
`EC00.ROM` through the ROM queue (the BIOS at 35 ms, both by 437 ms), the
machine leaves reset at 543 ms, and the Turbo XT BIOS 3.1 draws its banner
and hardware list (8088, CGA, LPT 378h, COM 3F8h and 2F8h, game port, clock)
in CGA text and counts the RAM test (088K at 3.67 s, CPU at Max). Win+F12
opens the OSD over that picture. The SDRAM model saw 22.3 million reads and
1.9 million writes with no protocol or timing error, no DQ contention and no
read sampled outside the data valid window. The OSD frame showed the main
page stopping at Video: the page declarations of the configuration string
were nested (fixed in `make_guest.py`: each page is declared right before
its entries).

`run_bios_sim.sh +OSD_TOUR` opens the OSD as soon as the machine runs and
walks it with the keyboard as a person would, finding each entry by its
text: the main page, Video, Output, Video info (which shows the core's own
measure of the picture: 640x200 line doubled, 31.38 kHz and 59.9 Hz at the
VGA pins), Audio, Hardware, Settings, BIOS, the file selector and ESC back.
`render_osd_tour.sh` draws each saved page with `zxtres_osd` as a PNG. Small
ROM files are enough for it, and bring the OSD at 0.27 s instead of 0.54 s.
Two lessons of the testbench: keys must be held about 5 ms and spaced 20 ms
or more, as a person types, or the firmware's 8-byte PS/2 ring buffer
drops some; and Verilator 5.020 does not evaluate again a loop condition
that calls functions on the design's memories in a timed task, so the
result is kept in a variable.

The simulation runs at about 2 s of machine time per 100 minutes, so the
remaining steps need long runs:
- the POST to the boot prompt: the RAM test counts about 250K per second
  of machine time (056K at 3.54 s, 088K at 3.67 s), so 640K ends near 6 s,
  some five hours of simulation;
- a VHD through the XT-IDE BIOS (`ZXTRES_SIM_VHD`), and a floppy;
- the Tandy and PCjr machines, EGA and Hercules.

## 6. Verification

- `zxtres/scripts/make_guest.py --check`: the committed guest matches
  `PCXT.sv`.
- The unit tests in `zxtres/sim` (WSL or Linux):
  - the IDE and floppy stores against the machine's own devices;
  - the line doubler;
  - the scan converter;
  - the video information page;
  - the OSD;
  - the keyboard events;
  - the keyboard relay with the machine's `KFPS2KB`;
  - the ROM loading queue;
  - the status bits 64-127 beside `user_io`;
  - the serial mouse;
  - the ICAP warm boot of the return to the Spectrum core.
- A Vivado build with no critical warnings and positive WNS and WHS.
