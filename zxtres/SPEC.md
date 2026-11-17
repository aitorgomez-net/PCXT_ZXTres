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

- **64 status bits.** DeMiSTify offers 64 status bits (option letters 0-9,
  A-Z and a-z, bits 0-61). PCXT uses 128. `make_guest.py` gives each OSD
  option a MiST bit and rebuilds the 128-bit MiSTer `status` from them, with
  fixed values for the options that are not offered.
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
| ROM loading: `PCXT.ROM`, `TANDY.ROM`, `EC00.ROM`, `EGA.ROM` and `PCJR.ROM` loaded by `autoboot()` with the machine held in reset; any other file can be chosen in the OSD page *BIOS*; paths kept in `PCXT.CFG` | Written | `firmware/overrides.c`, `rtl/zxtres_ioctl_fifo.sv` |
| Hard disks: the machine's XT-IDE served through the management window by `zxtres_ide_store` (units 0 and 1) | Inherited | `rtl/zxtres_ide_store.sv` |
| Floppies: the machine's floppy controller served by `zxtres_fdd_store` (units 3 and 4) | Inherited | `rtl/zxtres_fdd_store.sv` |
| Keyboard: the byte stream from the firmware to `KFPS2KB` through the PS/2 relay, with Win+F12 filtered out | Written | `rtl/zxtres_ps2_kbd_relay.sv` |
| Mouse: the PS/2 mouse wires to `MSMouseWrapper` on COM1 | Written, as in PCAT-286 | guest |
| Video: CGA and EGA through the splash fade, HGC sampled at 57 MHz, then the F12 credits, the line doubler and the OSD; 350-line pictures through the SRAM scan converter; video information page | Written, modules inherited | guest `VIDEO_OUT` |
| Audio: the MiSTer mix (speaker, OPL2, C/MS, Tandy, Sound Blaster), the compressor and the stereo mix, to the sigma-delta and I2S outputs | Written | guest `AUDIO_STAGE` |
| OSD: title *PCXT ZXTres*, pages Video (with Output), Audio, Hardware, BIOS and Settings | Written | `rtl/zxtres_osd.sv` (`TITLE` parameter), guest `CONF_STR` |
| Boot splash: the MiSTer picture with "MiSTer" redrawn as a striped, slanted "ZXTres" (T, r and e from the original word, Z, X and s drawn in the same lettering, white top stripes as in the PCAT-286 splash) | Done | `scripts/make_splash.py`, `splash/splash_320x200.hex`, used by `build_pcxt.sh` in place of `rtl/video/splash_320x200.hex` |
| F12 credits with the ZXTres art and the port's credits | Done | `credits/msg`, and `credits/msg.bin`, which is the first 8192 rows (four pages) of the binary output of the core's own `credits/msg2hex` |
| Unit tests of the shared modules | Inherited | `sim/` |

### 3.2 Not started

- The first board bring-up (the A100T `.ZX3` exists, not tried yet).
- The A200T build.
- The whole-board simulation: `run_bios_sim.sh` and its testbench were not
  copied.
- PCjr cartridges (MiSTer indices 5 and 6), the PCjr RAM size option and
  tape sound.
- DisplayPort, I/O timing constraints, and the return to the Spectrum core
  from the OSD.

## 4. Decisions

| Decision | Reason |
| --- | --- |
| Board logic copied from PCAT-286, not shared through a submodule | The two repositories evolve separately. The copied files are byte-identical except `zxtres_osd.sv`, whose title became a parameter. A fix to one should be copied to the other. |
| MiST bit allocation in `make_guest.py` (`CONF_ENTRIES`) | One table drives both the `CONF_STR` and the remapping to MiSTer bits, so the two cannot drift. |
| MiSTer bits fixed instead of offered: MPU-401 off (bit 88), PCjr 640 KiB (bits 98-101), splash time from MiST bits 8-9 (MiSTer bits 103-104) | No MIDI on the board; the PCjr options wait for the cartridges. |
| Joystick type offered with Digital first | The DB9 ports are digital; MiSTer offers Analog first. The OSD value is remapped. |
| The ROM loader waits behind a FIFO | `rom_loader` writes only while the CPU bus is held. During reset the hold is granted at once, so the FIFO only needs to absorb the SDRAM refresh and arbitration latency. |
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

Still to do: build the A200T, and get some margin on the
`clk_14_318` to clk_114 crossing if a later build fails there.

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

Adapt the PCAT-286 `run_bios_sim.sh` and its testbench to this guest:
- the five ROM slots through the FIFO;
- the keyboard relay;
- no CMOS.

The target is the PCXT BIOS reaching the boot prompt with a CGA picture.

### 5.3 PCjr options (P2, S)

The PCjr cartridges as ROM indices 5 and 6, in the OSD page *BIOS*. The PCjr
RAM size option.

### 5.4 Settings file (P1, S)

`sim/make_cfg_file.py` still writes the PCAT-286 file. It must write
`PCXT.CFG` in the layout of `overrides.c`: format `PCXT`, version 1, nine
paths of 52 bytes.

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
  - the serial mouse.
- New modules without a test yet: `zxtres_ps2_kbd_relay` and
  `zxtres_ioctl_fifo`.
- A Vivado build with no critical warnings and positive WNS and WHS.
