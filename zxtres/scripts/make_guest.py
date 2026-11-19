#!/usr/bin/env python3
"""Generate zxtres/rtl/pcxt_zxtres_guest.sv from the MiSTer top.

  make_guest.py [--check]

The ZXTRES guest keeps the board-independent parts of PCXT.sv verbatim and
replaces only the MiSTer glue, the same way as the PCAT-286 port does:

- hps_io and hps_ext become MiST user_io and data_io, with the ZXTRES
  storage masters (zxtres_ide_store, zxtres_fdd_store) on the management
  window, a queue in front of the ROM loader (zxtres_ioctl_fifo) and the
  physical PS/2 keyboard relayed to the machine (zxtres_ps2_kbd_relay);
- the Quartus PLLs and the DDIO output become two MMCMs and an ODDR;
- the MiSTer video shell (video_mixer, the DDR3 350-line framebuffer, the
  HDMI retiming) becomes the board video path: the F12 credits, the line
  doubler, the SRAM scan converter and the character-grid OSD;
- MT32-pi, the UART pins of the user port and the HPS notices are left out.

The kept parts are:

- the build options and the option logic, with the MiSTer status word
  rebuilt from the 64 MiST status bits (status_zx below);
- XTEGACTL, the clocks enables and resets;
- the SDRAM path: arbiter, controller, video fetch engines, ROM loader;
- the splash, the chipset and the 8088;
- the audio mixer and compressor;
- the CGA, Hercules and EGA front ends up to the monochrome converters.

Each kept block is located by a unique marker line, so a change to the
MiSTer top that moves or removes one stops the generator rather than
producing a silently different guest. With --check the generated text is
compared with the committed file.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'PCXT.sv'
TARGET = ROOT / 'zxtres/rtl/pcxt_zxtres_guest.sv'


def index_of(lines, marker):
    found = [i for i, line in enumerate(lines) if marker in line]
    if len(found) != 1:
        sys.exit(f'marker {marker!r}: {len(found)} matches in {SOURCE.name}')
    return found[0]


def block(lines, start, end, include_end=True):
    """Lines from the unique line containing START to the first line after
    it containing END."""
    first = index_of(lines, start)
    for i in range(first + 1, len(lines)):
        if end in lines[i]:
            return lines[first:i + 1 if include_end else i]
    sys.exit(f'end marker {end!r} not found after {start!r}')


def between(lines, start, end):
    """Lines after the unique line containing START, up to (not including)
    the unique line containing END."""
    return lines[index_of(lines, start) + 1:index_of(lines, end)]


def span(lines, start, end):
    """Lines from the unique line containing START up to (not including)
    the unique line containing END."""
    return lines[index_of(lines, start):index_of(lines, end)]


def replace(text, old, new, count=1):
    if text.count(old) != count:
        sys.exit(f'expected {count} of {old!r}, found {text.count(old)}')
    return text.replace(old, new)


def drop(text, start, end):
    """Remove the text from START to the first END after it, inclusive."""
    if text.count(start) != 1:
        sys.exit(f'expected one {start!r}, found {text.count(start)}')
    a = text.index(start)
    b = text.index(end, a) + len(end)
    return text[:a] + text[b:]


# ----------------------------------------------------------------------
# The OSD. DeMiSTify reads option bits in the MiST digit form: 0-9, then A-Z
# for 10-35 and a-z for 36-61, low bit first.

def bit(n):
    """The character of status bit n in the configuration string: 0-9, A-Z
    and a-z for bits 0-61, as DeMiSTify reads them, and the bytes 80h-BFh
    (octal escapes in the Verilog string) for bits 64-127, which the
    firmware's configstring_getdigit() reads (zxtres/firmware/overrides.c).
    Bits 62 and 63 have no character."""
    if 0 <= n <= 61:
        return '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'[n]
    if 64 <= n <= 127:
        return '\\%03o' % (0x80 + n - 64)
    sys.exit(f'status bit {n} has no character in the configuration string')


def opt(page, low, high, text, h=''):
    """An option entry; h is its hide flag (see HIDE)."""
    return f'{h}{page}O{bit(low)}{bit(high)},{text};'


# Hide flags: an entry that starts with a flag byte, 0xC0+n, is shown only while bit n
# of menu_mask() (firmware/overrides.c) is set (0xE0+n: only while it is clear), as the
# MiSTer core's entries are with its status_menumask. One byte each, as the string the
# core answers with cannot pass 2047 bytes (user_io's byte counter has 11 bits). They
# follow the machine chosen and the card:
def hide(n, inverse=False):
    return chr(92) + '%03o' % (0xC0 + n + (0x20 if inverse else 0))


HIDE_NOT_PCJR = hide(2)     # no expansion slots, second drive, hard disk, speed choice, CPU type, Fake 286
HIDE_CGA_CARD = hide(7)     # CGA/HGC card in use (a Tandy 1000 and a PCjr have it)
HIDE_EGA_CARD = hide(8)     # EGA card in use
HIDE_PCXT = hide(10)        # the PCXT only
HIDE_TANDY = hide(11)       # the Tandy 1000 only
HIDE_PCXT_CGA = hide(13)    # the PCXT with the CGA/HGC card
HIDE_PCJR = hide(14)        # the PCjr only
HIDE_A000 = hide(1)         # not a PCjr, not an EGA card


# MiST status bits of this OSD (see HEADER for the MiSTer bits they feed):
#   0 reset, 1-2 Settings page triggers (save, defaults; the firmware handles
#   them), 3-4 machine, 5 EMS off, 6 video card, 7 CPU 8086, 8-9 splash time,
#   10 composite, 11-13 OSD position, 14-16 display, 17-18 CPU speed, 19-20
#   write protect, 21 border, 22 border CRT offsets, 23-27 joysticks, 28 frame
#   stacking, 29 1st video, 30-31 BIOS writable, 32-33 speaker volume, 34-35
#   350-line CRT, 36-37 audio boost, 38-39 stereo mix, 40 CGA graphics off,
#   41 Hercules graphics off, 42-43 OPL2, 44-45 monitor, 46-49 CRT H offset,
#   50-52 CRT V offset, 53 fake 286 FLAGS, 54 A000 UMB off, 55 UMB off, 56-57
#   audio 220h, 58 joystick swap, 59 Tandy sound, 60 scandoubler off, 61 Sound
#   Blaster IRQ, 64-67 PCjr RAM, 68 PCjr tape sound, 69 back to the ZX core
#   (set by the firmware after its confirmation; never saved). Bits 64-127
#   reach the core through zxtres_status_ext.sv.
CONF_ENTRIES = [
    'PCXT;;',
    'S3,IMGIMAVFD,Floppy A:;',
    HIDE_NOT_PCJR + 'S4,IMGIMAVFD,Floppy B:;',
    HIDE_NOT_PCJR + 'S0,VHDIMG,Hard disk 0:;',
    HIDE_NOT_PCJR + 'S1,VHDIMG,Hard disk 1:;',
    'L,Machine;',
    opt('', 3, 4, 'Machine,IBM PCXT,Tandy 1000,IBM PCjr'),
    opt('', 17, 18, 'CPU Speed,4.77MHz,7.16MHz,9.54MHz,Max', HIDE_NOT_PCJR),
    opt('', 19, 20, 'Write protect,None,A:,B:,A: & B:', HIDE_NOT_PCJR),
    opt('', 19, 19, 'Write protect,No,Yes', HIDE_PCJR),   # one drive: A: only, as MiSTer
    # A page is declared ("P1,Video;") right before its own entries: the
    # firmware reads a declaration that follows another one as a page inside
    # it, so the root pages cannot be listed together. A page inside a page
    # ("P6PP,Video info;") may follow a declaration, which is why Video info
    # comes after Info, as in the PCAT port; it shows on the Output page.
    # A page inside a page also counts twice in the firmware's count of
    # entries, which tells a file entry where its extensions are: no file
    # entry (S) may come after one, so the Output page ("P1P6") is declared
    # after the BIOS files, still the last row of Video (check_file_entries).
    # Video
    'P1,Video;',
    HIDE_PCXT + 'P1L,Card;',
    opt('P1', 6, 6, 'Video card,CGA/HGC,EGA', HIDE_PCXT),
    opt('P1', 44, 45, 'Monitor,5154/ECD,5153/CGA,5151/MDA', HIDE_EGA_CARD),
    opt('P1', 29, 29, '1st video,CGA,Hercules', HIDE_PCXT_CGA),
    opt('P1', 40, 40, 'CGA graphics,Yes,No', HIDE_PCXT_CGA),
    opt('P1', 41, 41, 'HGC graphics,Yes,No', HIDE_PCXT_CGA),
    'P1L,Picture;',
    opt('P1', 14, 16, 'Display,Full Color,Green,Amber,B&W,Red,Blue,Fuchsia,Purple'),
    opt('P1', 10, 10, 'Composite,Off,On', HIDE_CGA_CARD),
    opt('P1', 21, 21, 'Border,No,Yes', HIDE_CGA_CARD),
    opt('P1', 22, 22, 'Border CRT offs,No,Yes', HIDE_CGA_CARD),
    opt('P1', 28, 28, 'Frame stacking,Native,Rebuilt', HIDE_CGA_CARD),
    # Audio
    'P2,Audio;',
    HIDE_NOT_PCJR + 'P2L,Sound cards;',
    opt('P2', 56, 57, 'Audio 220h,C/MS,Sound Blaster,Off', HIDE_NOT_PCJR),
    opt('P2', 42, 43, 'OPL2,Adlib 388h,SB FM 388h/228h,Off', HIDE_NOT_PCJR),
    opt('P2', 59, 59, 'Tandy Sound,Off,On', HIDE_PCXT),
    opt('P2', 61, 61, 'SB IRQ,5,7', HIDE_NOT_PCJR),
    HIDE_PCJR + 'P2L,PCjr;',
    opt('P2', 68, 68, 'Tape sound,Off,On', HIDE_PCJR),
    'P2L,Levels;',
    opt('P2', 32, 33, 'Speaker Volume,1,2,3,4'),
    opt('P2', 36, 37, 'Audio Boost,No,2x,4x'),
    opt('P2', 38, 39, 'Stereo Mix,none,25%,50%,100%'),
    # Hardware
    'P4,Hardware;',
    HIDE_NOT_PCJR + 'P4L,CPU;',
    opt('P4', 7, 7, 'CPU Type,8088,8086', HIDE_NOT_PCJR),
    opt('P4', 53, 53, 'Fake 286 FLAGS,Off,On', HIDE_NOT_PCJR),
    opt('P4', 30, 31, 'BIOS Writable,None,EC00,Main,All', HIDE_NOT_PCJR),
    'P4L,Memory;',
    opt('P4', 5, 5, 'EMS D000-DFFF,Enabled,Disabled', HIDE_NOT_PCJR),
    opt('P4', 55, 55, 'UMB C400-CFFF,Enabled,Disabled', HIDE_NOT_PCJR),
    opt('P4', 54, 54, 'A000 UMB,Enabled,Disabled', HIDE_A000),
    opt('P4', 64, 67, 'PCjr RAM,128K,192K,256K,320K,384K,448K,512K,576K,640K', HIDE_PCJR),
    'P4L,Joysticks;',
    opt('P4', 23, 24, 'Joystick 1,Digital,Analog,Off'),
    opt('P4', 25, 26, 'Joystick 2,Digital,Analog,Off'),
    opt('P4', 27, 27, 'Sync to CPU,No,Yes', HIDE_NOT_PCJR),
    opt('P4', 58, 58, 'Swap Joysticks,No,Yes'),
    # BIOS
    'P5,BIOS;',
    HIDE_PCXT + 'P5SB,ROMBIN,PCXT BIOS:;',
    HIDE_TANDY + 'P5ST,ROMBIN,Tandy BIOS:;',
    HIDE_PCJR + 'P5SJ,ROMBIN,PCjr BIOS:;',
    HIDE_EGA_CARD + 'P5SE,ROMBIN,EGA BIOS:;',
    HIDE_NOT_PCJR + 'P5SC,ROMBIN,EC00 BIOS:;',
    HIDE_PCJR + 'P5SK,JRCBIN,PCjr cart. 1:;',
    HIDE_PCJR + 'P5SL,JRCBIN,PCjr cart. 2:;',
    'P1P6,Output;',
    # Video > Output
    'P6L,Position;',
    opt('P6', 46, 49, 'CRT H offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15'),
    opt('P6', 50, 52, 'CRT V offset,0,1,2,3,4,5,6,7'),
    'P6L,Output;',
    opt('P6', 60, 60, 'Scandoubler,Auto,Off'),
    opt('P6', 34, 35, '350-line CRT,480p 31 kHz,Native,480i 15 kHz,240p 15 kHz'),
    'P6L,Boot splash;',
    opt('P6', 8, 9, 'Splash time,5 s,10 s,15 s,0 s'),
    # Settings
    'P3,Settings;',
    'P3PQ,Info;',
    'P6PP,Video info;',
    'P3L,Appearance;',
    opt('P3', 11, 13, 'OSD position,Centre,Top left,Top right,Bottom left,Bottom right'),
    'P3L,Settings file;',
    'P3T1,Save settings;',
    'P3T2,Reset to defaults;',
    'P3L,Board;',
    f'P3T{bit(69)},Reload ZX core;',
    'T0,Reset;',
    'V,v0.1',
]


def check_file_entries():
    """Each file entry (S) must find its own extensions. The firmware's
    buildmenu() (DeMiSTify/firmware/main.c) numbers the entries of the
    configuration string, and configstring_matchextension() reads the
    extensions of the entry with that number; but buildmenu() counts a page
    declared inside a page ("P1P6,Output;") twice, so a file entry after one
    would read the extensions of the next entry. This repeats that count."""
    s = ''.join(CONF_ENTRIES)
    fields = s.split(';')

    def skip_flags(p):                # hide flags are escapes of four characters
        while s[p] == chr(92):
            p += 4
        return p

    pos = s.index(';') + 2            # after "PCXT;" and the empty field
    idx = 1
    while pos < len(s):
        pos = skip_flags(pos)
        while s[pos] == 'P':          # page prefixes and declarations
            pos += 2
            if s[pos] == ',':
                pos = s.index(';', pos) + 1
            pos = skip_flags(pos)
            if s[pos] == 'P':         # the next entry's page, or a page inside a page
                idx += 1
        end = s.find(';', pos)
        entry = s[pos:end if end >= 0 else len(s)]
        own = s[:pos].count(';') - 1  # the entry's real number
        if entry.startswith('S') and idx != own:
            sys.exit(f'CONF_STR: file entry {entry!r} would take the extensions of '
                     f'{fields[idx + 1]!r}: declare pages inside pages after it')
        pos = end + 1 if end >= 0 else len(s)
        idx += 1


CONF_STR_LIMIT = 2047         # user_io.v: byte_cnt has 11 bits and stops there


def conf_str_length():
    """The length of the string the core answers the firmware with, in bytes."""
    n = 0
    for entry in CONF_ENTRIES:
        n += len(re.sub(re.escape(chr(92)) + '[0-7]{3}', 'x', entry))
    return n


def conf_str():
    check_file_entries()
    n = conf_str_length()
    if n > CONF_STR_LIMIT:
        sys.exit(f'CONF_STR is {n} bytes: user_io.v serves 2047 at most and the firmware '
                 f'would read the last byte for ever. Shorten the entries.')
    return '\n'.join(f'        "{entry}"' + (',' if i + 1 < len(CONF_ENTRIES) else '')
                     for i, entry in enumerate(CONF_ENTRIES))


HEADER = r'''// GENERATED by zxtres/scripts/make_guest.py from PCXT.sv. Do not edit:
// change the MiSTer top or the generator, then regenerate.
//
// PCXT guest core for DeMiSTify on the ZXTRES+ and ZXTRES++ (MiST
// interface). The machine (8088, chipset, CGA/Hercules/EGA, Tandy 1000 and
// PCjr, sound devices), its memory path to the SDRAM and the video front ends
// are the MiSTer core's own blocks; the MiSTer HPS glue is replaced by MiST
// user_io/data_io, the board storage masters, a character-grid OSD over the
// VGA output and the ZXTRES PS/2 keyboard and mouse.
//
// Not available on this board: MIDI, MT32-pi and the COM2 pins, the second SD
// card, the HPS real-time clock (zxtres/SPEC.md).
`timescale 1ns/1ps

module pcxt_zxtres_guest (
    input  logic        CLOCK_50,       // 50 MHz from a global buffer
    input  logic        RESET_N,        // from the DeMiSTify controller
    output logic        LED,
    output logic        REBOOT_FPGA,    // OSD "Reload ZX core": reload from flash address 0

    output logic [12:0] SDRAM_A,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nWE,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCS,
    output logic [1:0]  SDRAM_BA,
    output logic        SDRAM_CLK,
    output logic        SDRAM_CKE,

    output wire         SPI_DO,
    input  logic        SPI_DI,
    input  logic        SPI_SCK,
    input  logic        SPI_SS2,
    input  logic        SPI_SS3,
    input  logic        SPI_SS4,
    input  logic        CONF_DATA0,

    output logic [7:0]  VGA_R,
    output logic [7:0]  VGA_G,
    output logic [7:0]  VGA_B,
    output logic        VGA_HS,
    output logic        VGA_VS,

    output logic [19:0] SRAM_A,         // 2 MiB asynchronous SRAM (scan converter)
    inout  wire  [15:0] SRAM_Q,
    output logic        SRAM_WE,        // active low
    output logic        SRAM_OE,
    output logic        SRAM_UB,
    output logic        SRAM_LB,

    input  logic        PS2K_CLK_IN,    // physical keyboard, blocked while the OSD is open
    input  logic        PS2K_DAT_IN,
    input  logic        OSD_OPEN,       // the controller is keeping the keyboard
    input  logic        PS2M_CLK_IN,    // physical mouse
    input  logic        PS2M_DAT_IN,
    output logic        PS2M_CLK_OUT,   // open collector: 0 pulls the line low
    output logic        PS2M_DAT_OUT,

    output logic [15:0] DAC_L,
    output logic [15:0] DAC_R
);
    wire CLK_50M = CLOCK_50;
    // Core reset: the controller's reset; status bit 0 (OSD reset and the
    // firmware's hold while it loads the ROMs) resets the machine below.
    wire RESET = !RESET_N;

    // ------------------------------------------------------------------
    // OSD (bits in zxtres/scripts/make_guest.py, CONF_ENTRIES).
    localparam CONF_STR = {
@@CONF_STR@@
    };

    logic [127:0] mist_status;
    logic [31:0] joystick_0, joystick_1;

    // The MiSTer status word of the verbatim blocks (the EGA menu layout,
    // LAYOUT_EGA), rebuilt from the 128 MiST bits. MiSTer options with no
    // place on this board read as their first value; the joysticks offer
    // Digital first (the DB9 pads have no analog axes) and are put back in
    // MiSTer order (Analog, Digital, Disabled).
    function automatic [1:0] joy_mode(input [1:0] osd);
        joy_mode = osd == 2'd0 ? 2'b01 : osd == 2'd1 ? 2'b00 : 2'b10;   // {disable, digital}
    endfunction
    wire [127:0] status_zx;
    assign status_zx[0]       = mist_status[0];
    assign status_zx[4:1]     = 4'd0;                 // scaler, MT32-pi ROM
    assign status_zx[5]       = mist_status[5];       // EMS off
    assign status_zx[13:6]    = 8'd0;                 // USER I/O, aspect, CGA-layout options, MT32-pi
    assign status_zx[16:14]   = mist_status[16:14];   // display
    assign status_zx[18:17]   = mist_status[18:17];   // CPU speed
    assign status_zx[20:19]   = mist_status[20:19];   // write protect
    assign status_zx[22:21]   = 2'd0;                 // second SD card
    assign status_zx[24:23]   = joy_mode(mist_status[24:23]);
    assign status_zx[26:25]   = joy_mode(mist_status[26:25]);
    assign status_zx[27]      = mist_status[27];      // joystick sync
    assign status_zx[29:28]   = 2'd0;                 // CGA-layout options
    assign status_zx[31:30]   = mist_status[31:30];   // BIOS writable
    assign status_zx[33:32]   = mist_status[33:32];   // speaker volume
    assign status_zx[35:34]   = 2'd0;                 // the MiSTer DDR3 350-line output
    assign status_zx[39:36]   = mist_status[39:36];   // audio boost, stereo mix
    assign status_zx[41:40]   = 2'd0;                 // MT32-pi
    assign status_zx[43:42]   = mist_status[43:42];   // OPL2
    assign status_zx[45:44]   = 2'd0;                 // CGA-layout options
    assign status_zx[52:46]   = mist_status[52:46];   // CRT H and V offsets
    assign status_zx[53]      = mist_status[53];      // fake 286 FLAGS
    assign status_zx[62:54]   = 9'd0;                 // CGA-layout options, MT32-pi
    assign status_zx[63]      = mist_status[7];       // CPU type
    assign status_zx[69:64]   = 6'd0;                 // CGA-layout options
    assign status_zx[70]      = mist_status[61];      // Sound Blaster IRQ
    assign status_zx[71]      = mist_status[10];      // composite
    assign status_zx[72]      = mist_status[21];      // border
    assign status_zx[73]      = mist_status[22];      // border CRT offsets
    assign status_zx[74]      = mist_status[28];      // frame stacking
    assign status_zx[75]      = mist_status[29];      // first video
    assign status_zx[76]      = mist_status[40];      // CGA graphics off
    assign status_zx[77]      = mist_status[41];      // Hercules graphics off
    assign status_zx[78]      = mist_status[6];       // video card
    assign status_zx[79]      = mist_status[54];      // A000 UMB off
    assign status_zx[81:80]   = mist_status[45:44];   // monitor
    assign status_zx[82]      = mist_status[55];      // UMB off
    assign status_zx[83]      = 1'b0;
    assign status_zx[85:84]   = mist_status[57:56];   // audio 220h
    assign status_zx[86]      = mist_status[58];      // joystick swap
    assign status_zx[87]      = mist_status[59];      // Tandy sound
    assign status_zx[88]      = 1'b1;                 // MPU-401 off: no MIDI on the board
    assign status_zx[95:89]   = 7'd0;                 // sync widths: auto
    assign status_zx[97:96]   = mist_status[4:3];     // machine
    assign status_zx[101:98]  = mist_status[67:64];   // PCjr RAM
    assign status_zx[102]     = mist_status[68];      // PCjr tape sound
    assign status_zx[104:103] = mist_status[9:8];     // splash time
    assign status_zx[127:105] = '0;
'''

MIST_IO = r'''
    // ------------------------------------------------------------------
    // MiST interface on the chipset clock.
    /* verilator lint_off PINCONNECTEMPTY */
    // Block devices 0 and 1 are the hard disks (zxtres_ide_store below), 3
    // and 4 the floppy drives (zxtres_fdd_store); 2 is not used (the PC/AT
    // port keeps its CMOS there). zxtres_sd_arb shares the request lines.
    wire [1:0]  ide_sd_rd, ide_sd_wr;
    wire [31:0] ide_sd_lba;
    wire [7:0]  ide_sd_din;
    wire [1:0]  fdd_sd_rd, fdd_sd_wr;
    wire [31:0] fdd_sd_lba;
    wire [7:0]  fdd_sd_din;
    wire [4:0]  arb_sd_rd, arb_sd_wr;
    wire [31:0] arb_sd_lba;
    wire [7:0]  arb_sd_din;
    wire [4:0]  sd_ack_x;
    wire [7:0]  sd_dout;
    wire        sd_dout_strobe;
    wire [8:0]  sd_buff_addr;
    wire [4:0]  img_mounted;
    wire [63:0] img_size;
    wire [7:0]  vi_leds;
    user_io #(.STRLEN($size(CONF_STR) >> 3), .PS2DIV(2000), .SD_IMAGES(5)) u_user_io (
        .conf_str(CONF_STR), .conf_addr(), .conf_chr(8'h00),
        .clk_sys(clk_chipset), .clk_sd(clk_chipset),
        .SPI_CLK(SPI_SCK), .SPI_SS_IO(CONF_DATA0), .SPI_MISO(SPI_DO), .SPI_MOSI(SPI_DI),
        .joystick_0(joystick_0), .joystick_1(joystick_1), .joystick_2(), .joystick_3(),
        .joystick_4(), .joystick_analog_0(), .joystick_analog_1(),
        .buttons(), .switches(), .scandoubler_disable(), .ypbpr(), .no_csync(),
        .status(mist_status[63:0]), .core_mod(), .rtc(),
        .sd_lba(arb_sd_lba), .sd_rd(arb_sd_rd), .sd_wr(arb_sd_wr),
        .sd_ack(), .sd_ack_conf(), .sd_ack_x(sd_ack_x), .sd_conf(1'b0), .sd_sdhc(1'b1),
        .sd_dout(sd_dout), .sd_dout_strobe(sd_dout_strobe), .sd_din(arb_sd_din),
        .sd_din_strobe(), .sd_buff_addr(sd_buff_addr),
        .img_mounted(img_mounted), .img_size(img_size),
        .ps2_kbd_clk(), .ps2_kbd_data(), .ps2_kbd_clk_i(1'b1), .ps2_kbd_data_i(1'b1),
        .ps2_mouse_clk(), .ps2_mouse_data(), .ps2_mouse_clk_i(1'b1), .ps2_mouse_data_i(1'b1),
        .key_pressed(), .key_extended(), .key_code(), .key_strobe(),
        .kbd_out_data(8'h00), .kbd_out_strobe(1'b0), .leds(vi_leds),
        .mouse_x(), .mouse_y(), .mouse_z(), .mouse_flags(), .mouse_strobe(), .mouse_idx(),
        .i2c_start(), .i2c_read(), .i2c_addr(), .i2c_subaddr(), .i2c_dout(),
        .i2c_din(8'h00), .i2c_ack(1'b0), .i2c_end(1'b0),
        .serial_data(8'h00), .serial_strobe(1'b0)
    );
    // Status bits 64-127: bytes 9-16 of the same SPI command.
    zxtres_status_ext u_status_ext (
        .clk_sys(clk_chipset), .SPI_CLK(SPI_SCK), .SPI_SS_IO(CONF_DATA0), .SPI_MOSI(SPI_DI),
        .status_ext(mist_status[127:64])
    );

    // ROM files from the card. MiST data_io cannot wait; the words go through
    // a queue to the ROM loader, which waits for the bus and for each write.
    wire        mist_download, mist_wr;
    wire [7:0]  mist_index;
    wire [26:0] mist_addr;
    wire [15:0] mist_data;
    data_io #(.DOUT_16(1'b1)) u_data_io (
        .clk_sys(clk_chipset), .SPI_SCK(SPI_SCK), .SPI_SS2(SPI_SS2), .SPI_SS4(SPI_SS4),
        .SPI_DI(SPI_DI), .QCSn(1'b1), .QSCK(1'b1), .QDAT(4'hF), .clkref_n(1'b0),
        .ioctl_download(mist_download), .ioctl_upload(), .ioctl_index(mist_index),
        .ioctl_wr(mist_wr), .ioctl_addr(mist_addr), .ioctl_dout(mist_data),
        .ioctl_din(8'h00), .ioctl_fileext(), .ioctl_filesize(),
        .hdd_clk(clk_chipset), .hdd_cmd_req(1'b0), .hdd_cdda_req(1'b0), .hdd_dat_req(1'b0),
        .hdd_cdda_wr(), .hdd_status_wr(), .hdd_addr(), .hdd_wr(), .hdd_data_out(),
        .hdd_data_in(16'h0000), .hdd_data_rd(), .hdd_data_wr(), .hdd0_ena(), .hdd1_ena()
    );
    wire ioctl_overflow;
    zxtres_ioctl_fifo u_ioctl_fifo (
        .clk(clk_chipset), .reset(RESET),
        .in_download(mist_download), .in_index(mist_index), .in_wr(mist_wr),
        .in_addr(mist_addr), .in_data(mist_data), .overflow(ioctl_overflow),
        .out_download(ioctl_download), .out_index(ioctl_index), .out_wr(ioctl_wr),
        .out_addr(ioctl_addr), .out_data(ioctl_data), .out_wait(ioctl_wait)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // DB9 joysticks in the MiSTer bit order; no analog axes (centred).
    assign joy0  = joystick_0[13:0];
    assign joy1  = joystick_1[13:0];
    assign joya0 = 16'h0000;
    assign joya1 = 16'h0000;

    // The physical PS/2 keyboard: the bytes it sends, as MiSTer ps2_key events
    // for the splash F12 hold (Win+F12 is the OSD's), and relayed to the
    // machine's keyboard port as the PS/2 device hps_io emulates.
    wire [7:0]  kbd_byte;
    wire        kbd_strobe;
    zxtres_ps2_rx u_kbd_rx (
        .clk(clk_chipset), .reset(RESET), .ps2_clk(PS2K_CLK_IN), .ps2_data(PS2K_DAT_IN),
        .data(kbd_byte), .strobe(kbd_strobe), .error()
    );
    zxtres_ps2_key u_kbd_events (
        .clk(clk_chipset), .reset(RESET), .osd_open(OSD_OPEN),
        .byte_valid(kbd_strobe), .byte_in(kbd_byte), .ps2_key(ps2_key)
    );
    zxtres_ps2_kbd_relay u_kbd_relay (
        .clk(clk_chipset), .reset(RESET), .osd_open(OSD_OPEN),
        .byte_valid(kbd_strobe), .byte_in(kbd_byte),
        .host_clk(ps2_kbd_clk_out), .host_dat(ps2_kbd_data_out),
        .dev_clk(ps2_kbd_clk_in), .dev_dat(ps2_kbd_data_in)
    );

    // The PS/2 mouse port goes to the machine's serial mouse (COM1), which
    // is a PS/2 host itself; open-collector lines.
    assign ps2_mouse_clk_out  = PS2M_CLK_IN;
    assign ps2_mouse_data_out = PS2M_DAT_IN;
    assign PS2M_CLK_OUT = ps2_mouse_clk_in;
    assign PS2M_DAT_OUT = ps2_mouse_data_in;

    // The MiSTer management window (the IDE disks at F000-F0FF, the floppies
    // at F2xx) is driven by the IDE and floppy stores, which take it while
    // they serve a request. The IDE store goes first when both ask at once.
    wire [15:0] ide_mgmt_address, ide_mgmt_dout;
    wire        ide_mgmt_write, ide_mgmt_read;
    wire        ide_bus_req, ide_bus_use;
    wire [15:0] fdd_mgmt_address, fdd_mgmt_dout;
    wire        fdd_mgmt_write, fdd_mgmt_read;
    wire        fdd_bus_req, fdd_bus_use;
    assign mgmt_addr = ide_bus_use ? ide_mgmt_address : fdd_mgmt_address;
    assign mgmt_dout = ide_bus_use ? ide_mgmt_dout    : fdd_mgmt_dout;
    assign mgmt_wr   = ide_bus_use ? ide_mgmt_write   : (fdd_bus_use && fdd_mgmt_write);
    assign mgmt_rd   = ide_bus_use ? ide_mgmt_read    : (fdd_bus_use && fdd_mgmt_read);
    /* verilator lint_off PINCONNECTEMPTY */
    zxtres_ide_store u_ide_store (
        .clk(clk_chipset), .reset(RESET),
        .img_mounted(img_mounted[1:0]), .img_size(img_size),
        .sd_rd(ide_sd_rd), .sd_wr(ide_sd_wr), .sd_lba(ide_sd_lba),
        .sd_ack(sd_ack_x[1:0]), .sd_buff_addr(sd_buff_addr),
        .sd_dout(sd_dout), .sd_dout_strobe(sd_dout_strobe), .sd_din(ide_sd_din),
        .bus_req(ide_bus_req), .bus_grant(!fdd_bus_use), .bus_use(ide_bus_use),
        .mgmt_address(ide_mgmt_address), .mgmt_writedata(ide_mgmt_dout),
        .mgmt_write(ide_mgmt_write), .mgmt_read(ide_mgmt_read),
        .mgmt_readdata(mgmt_din), .ide_request(mgmt_req[2:0]),
        .command_count()
    );
    zxtres_fdd_store u_fdd_store (
        .clk(clk_chipset), .reset(RESET),
        .img_mounted(img_mounted[4:3]), .img_size(img_size),
        .sd_rd(fdd_sd_rd), .sd_wr(fdd_sd_wr), .sd_lba(fdd_sd_lba),
        .sd_ack(sd_ack_x[4:3]), .sd_buff_addr(sd_buff_addr),
        .sd_dout(sd_dout), .sd_dout_strobe(sd_dout_strobe), .sd_din(fdd_sd_din),
        .bus_req(fdd_bus_req), .bus_grant(!ide_bus_req), .bus_use(fdd_bus_use),
        .mgmt_address(fdd_mgmt_address), .mgmt_writedata(fdd_mgmt_dout),
        .mgmt_write(fdd_mgmt_write), .mgmt_read(fdd_mgmt_read),
        .mgmt_readdata(mgmt_din), .floppy_request(mgmt_req[7:6]),
        .sector_count()
    );
    zxtres_sd_arb u_sd_arb (
        .clk(clk_chipset), .reset(RESET),
        .a_rd(ide_sd_rd), .a_wr(ide_sd_wr), .a_lba(ide_sd_lba), .a_din(ide_sd_din),
        .b_rd(1'b0), .b_wr(1'b0), .b_din(8'h00),
        .c_rd(fdd_sd_rd), .c_wr(fdd_sd_wr), .c_lba(fdd_sd_lba), .c_din(fdd_sd_din),
        .sd_ack_x(sd_ack_x),
        .sd_rd(arb_sd_rd), .sd_wr(arb_sd_wr), .sd_lba(arb_sd_lba), .sd_din(arb_sd_din)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // No MT32-pi on the board; the MiSTer UART menu (MIDI on the HPS) neither.
    wire [16:0] mt32_l_snd = 17'd0;
    wire [16:0] mt32_r_snd = 17'd0;
    wire        mt32_available = 1'b0;
'''

MGMT_DECL = r'''
    wire [15:0] mgmt_din;
    wire [15:0] mgmt_dout;
    wire [15:0] mgmt_addr;
    wire        mgmt_rd;
    wire        mgmt_wr;
    wire  [7:0] mgmt_req;
    assign mgmt_req[5:3] = 3'b000;
'''

CLOCKS = r'''
    // Clocks as the MiSTer PLLs give them. The system MMCM makes the chipset
    // clock (50 MHz) and the 8088 core clock (100 MHz) from the board
    // oscillator; the video MMCM makes the CGA dot clock (28.636 MHz), the
    // video pipeline (57.27 MHz) and the SDRAM and Hercules clock (114.5 MHz)
    // from the same oscillator, 630 MHz VCO / 22, 11 and 5.5. The MiSTer
    // phase-shifted video output clock is not needed (no HDMI retiming).
    wire sys_feedback, sys_feedback_bufg, clk_100_mmcm, clk_chipset_mmcm;
    /* verilator lint_off PINCONNECTEMPTY */
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(20.0),          // VCO 1000 MHz
        .CLKOUT0_DIVIDE_F(10.0),         // 100 MHz
        .CLKOUT1_DIVIDE(20)              // 50 MHz
    ) u_sys_mmcm (
        .CLKIN1(CLK_50M), .CLKFBIN(sys_feedback_bufg), .CLKFBOUT(sys_feedback),
        .CLKOUT0(clk_100_mmcm), .CLKOUT1(clk_chipset_mmcm),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB(),
        .LOCKED(pll_locked), .PWRDWN(1'b0), .RST(1'b0)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    BUFG u_sys_fb_bufg (.I(sys_feedback), .O(sys_feedback_bufg));
    BUFG u_clk100_bufg (.I(clk_100_mmcm), .O(clk_100));
    BUFG u_chipset_bufg (.I(clk_chipset_mmcm), .O(clk_chipset));

    wire video_feedback, clk_28_mmcm, clk_57_mmcm, clk_114_mmcm;
    /* verilator lint_off PINCONNECTEMPTY */
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0),
        .DIVCLK_DIVIDE(5),
        .CLKFBOUT_MULT_F(63.0),          // VCO 630 MHz
        .CLKOUT0_DIVIDE_F(5.5),          // 114.545 MHz
        .CLKOUT1_DIVIDE(11),             // 57.273 MHz
        .CLKOUT2_DIVIDE(22)              // 28.636 MHz
    ) u_video_mmcm (
        .CLKIN1(CLK_50M), .CLKFBIN(video_feedback), .CLKFBOUT(video_feedback),
        .CLKOUT0(clk_114_mmcm), .CLKOUT1(clk_57_mmcm), .CLKOUT2(clk_28_mmcm),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB(),
        .LOCKED(pll_system_locked), .PWRDWN(1'b0), .RST(1'b0)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    BUFG u_clk114_bufg (.I(clk_114_mmcm), .O(clk_114_544));
    BUFG u_clk57_bufg (.I(clk_57_mmcm), .O(clk_57_272));
    BUFG u_clk28_bufg (.I(clk_28_mmcm), .O(clk_28_636));
    assign clk_video_out_ps = clk_57_272;
    assign clk_sdram_pin = clk_114_544;
    assign clk_sys = clk_chipset;
'''

ODDR = r'''    // The SDRAM clock leaves through an output DDR register, inverted: half a
    // period after the controller clock, as the MiSTer PLL output gives it.
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) sdram_clk_ddr (
        .Q(SDRAM_CLK), .C(sdram_clk_src), .CE(1'b1), .D1(1'b0), .D2(1'b1), .R(1'b0), .S(1'b0)
    );
'''

UART = r'''
    // No UART pins on the board: COM2 and the MIDI input idle.
    wire uart_tx, uart_rts, uart_dtr;
    wire uart_rx  = 1'b1;
    wire uart_cts = 1'b1;
    wire uart_dsr = 1'b1;
    wire uart_dcd = 1'b1;
    wire midi_tx;
    wire midi_rx  = 1'b1;
'''

AUDIO_STAGE = r'''
    wire [15:0] audio_pre_l = pause_core ? 16'd0 : status[37:36] ? cmp_l : out_l;
    wire [15:0] audio_pre_r = pause_core ? 16'd0 : status[37:36] ? cmp_r : out_r;

    // The stereo mix the MiSTer framework does after the core (AUDIO_MIX): a
    // share of the other channel, none, 1/8, 1/4 or 1/2 (mono).
    wire signed [16:0] audio_cross = $signed({audio_pre_r[15], audio_pre_r}) -
                                      $signed({audio_pre_l[15], audio_pre_l});
    logic signed [16:0] audio_share_q;
    always_ff @(posedge clk_chipset)
        case (status[39:38])
            2'd0:    audio_share_q <= 17'sd0;
            2'd1:    audio_share_q <= audio_cross >>> 3;
            2'd2:    audio_share_q <= audio_cross >>> 2;
            default: audio_share_q <= audio_cross >>> 1;
        endcase
    logic signed [15:0] audio_mix_l_q, audio_mix_r_q;
    always_ff @(posedge clk_chipset) begin
        audio_mix_l_q <= audio_pre_l + audio_share_q[15:0];
        audio_mix_r_q <= audio_pre_r - audio_share_q[15:0];
    end
'''

MMC = r'''    // No second SD card on the board.
    assign spi_miso = 1'b1;
'''

MAIN_SRC = r'''
    // ------------------------------------------------------------------
    // The picture of the card in use, on the 57.27 MHz clock: CGA (or the
    // Tandy/PCjr modes) and EGA through the splash fade, as the MiSTer main
    // mixer takes them, and the Hercules card, whose 114.5 MHz picture is
    // sampled at one event per dot (ce_pixel_hgc_fb, as the MiSTer framebuffer
    // capture does).
    wire [7:0] main_r_src = ega_active_vid ? raux_ega : raux_cga;
    wire [7:0] main_g_src = ega_active_vid ? gaux_ega : gaux_cga;
    wire [7:0] main_b_src = ega_active_vid ? baux_ega : baux_cga;
    wire       main_hs = ega_active_vid ? haux_ega : haux_cga;
    wire       main_vs = ega_active_vid ? vaux_ega : vaux_cga;
'''

VIDEO_OUT = r'''
    wire       main_hb = ega_active_vid ? hbaux_ega : hbaux_cga;
    wire       main_vb = ega_active_vid ? vbaux_ega : vbaux_cga;
    wire       ce_pixel_main = ega_active_vid ? ce_pixel_ega : ce_pixel_cga_vid;

    (* ASYNC_REG = "TRUE" *) logic hgc_sel_s1 = 1'b0, hgc_sel_q = 1'b0;
    always_ff @(posedge clk_57_272) begin
        hgc_sel_s1 <= swap_video_eff & ~ega_active_vid;
        hgc_sel_q  <= hgc_sel_s1;
    end

    wire [7:0] pic_r  = hgc_sel_q ? raux_hgc  : main_r;
    wire [7:0] pic_g  = hgc_sel_q ? gaux_hgc  : main_g;
    wire [7:0] pic_b  = hgc_sel_q ? baux_hgc  : main_b;
    wire       pic_hs = hgc_sel_q ? haux_hgc  : main_hs;
    wire       pic_vs = hgc_sel_q ? vaux_hgc  : main_vs;
    wire       pic_hb = hgc_sel_q ? hbaux_hgc : main_hb;
    wire       pic_vb = hgc_sel_q ? vbaux_hgc : main_vb;
    wire       pic_ce = hgc_sel_q ? ce_pixel_hgc_fb : ce_pixel_main;

    // ------------------------------------------------------------------
    // Video out. Two paths to the VGA connector, one of which is chosen per
    // frame (conv_active, see zxtres_scanconv.sv):
    //   - the picture as it is, doubled to 31.4 kHz if it has 200 lines
    //     (zxtres_linedouble.sv; status bit 60 turns that off), OSD over it,
    //     registered on the 57 MHz pipeline clock;
    //   - the 350-line pictures (EGA, Hercules/MDA), written into the SRAM
    //     and read out on a 27 MHz clock as 720x480 at 59.94 Hz, or at 15.7
    //     kHz as 480i or 240p (status bits 34-35; Native turns the conversion
    //     off), OSD over it, registered on that clock.
    //
    // The F12 credits scroll over the dimmed picture ahead of both paths, as
    // on MiSTer (jtframe_credits, text zxtres/credits/msg.bin): while the
    // splash is held by F12 and while F12 pauses the machine.
    wire video_pipe_reset = video_retime_reset_57;

    wire [23:0] cr_rgb;
    wire        cr_hb, cr_vb;
    /* verilator lint_off PINCONNECTEMPTY */
    jtframe_credits #(.PAGES(4), .COLW(8), .BLKPOL(1), .BORDER_X(64)) u_credits (
        .rst(video_pipe_reset), .clk(clk_57_272), .pxl_cen(pic_ce),
        .HB(pic_hb), .VB(pic_vb),
        .rgb_in({pic_r, pic_g, pic_b}),
        .vram_din(9'h000), .vram_addr(10'h000), .vram_we(1'b0), .vram_dout(),
        .enable(video_credits_show), .toggle(1'b0), .vram_ctrl(3'b000),
        .fast_scroll(1'b0), .rotate(2'd0), .border(1'b0),
        .HB_out(cr_hb), .VB_out(cr_vb), .rgb_out(cr_rgb)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    // The credits block registers colour and blanking once per pixel
    // enable, shown or not; give the syncs the same register.
    logic cr_hs, cr_vs;
    always_ff @(posedge clk_57_272)
        if (pic_ce) begin
            cr_hs <= pic_hs;
            cr_vs <= pic_vs;
        end

    wire [5:0] sd_r, sd_g, sd_b;
    wire       sd_hb, sd_vb, sd_hs, sd_vs, sd_ce, sd_double, sd_hs_pin, sd_vs_pin;
    zxtres_linedouble u_linedouble (
        .clk(clk_57_272), .reset(video_pipe_reset), .ce_in(pic_ce),
        .off(mist_status[60]),
        .r_in(cr_rgb[23:18]), .g_in(cr_rgb[15:10]), .b_in(cr_rgb[7:2]),
        .hb_in(cr_hb), .vb_in(cr_vb),
        .hs_in(cr_hs), .vs_in(cr_vs),
        .r_out(sd_r), .g_out(sd_g), .b_out(sd_b),
        .hb_out(sd_hb), .vb_out(sd_vb), .hs_out(sd_hs), .vs_out(sd_vs),
        .ce_out(sd_ce), .double(sd_double), .hs_pin(sd_hs_pin), .vs_pin(sd_vs_pin)
    );

    wire [5:0] osd_r, osd_g, osd_b;
    /* verilator lint_off PINCONNECTEMPTY */
    zxtres_osd #(.USE_BLANKS(1'b1), .OUT_COLOR_DEPTH(6), .TITLE_CHARS(11),
                 .TITLE("PCXT ZXTres")) u_osd (
        .clk_sys(clk_57_272), .ce(sd_ce),
        .SPI_SCK(SPI_SCK), .SPI_SS3(SPI_SS3), .SPI_DI(SPI_DI),
        .R_in(sd_r), .G_in(sd_g), .B_in(sd_b),
        .HBlank(sd_hb), .VBlank(sd_vb),
        .HSync(sd_hs), .VSync(sd_vs),
        .R_out(osd_r), .G_out(osd_g), .B_out(osd_b),
        .osd_enable()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // video_ce/video_de mark the dots of the picture for simulation capture.
    logic video_ce, video_de;
    logic [7:0] p57_r, p57_g, p57_b;
    logic       p57_hs, p57_vs;
    always_ff @(posedge clk_57_272) begin
        if (video_pipe_reset) begin
            {p57_r, p57_g, p57_b} <= '0;
            p57_hs <= 1'b1;
            p57_vs <= 1'b1;
            video_ce <= 1'b0;
            video_de <= 1'b0;
        end else begin
            p57_r <= sd_hb | sd_vb ? 8'h00 : {osd_r, osd_r[5:4]};
            p57_g <= sd_hb | sd_vb ? 8'h00 : {osd_g, osd_g[5:4]};
            p57_b <= sd_hb | sd_vb ? 8'h00 : {osd_b, osd_b[5:4]};
            p57_hs <= sd_hs_pin;
            p57_vs <= sd_vs_pin;
            video_ce <= sd_ce;
            video_de <= !(sd_hb | sd_vb);
        end
    end

    // 27 MHz for the 480p output: 50 MHz * 27 / 2 = 675 MHz VCO, / 25.
    wire clk27, scan_feedback, clk27_mmcm, scan_locked;
    /* verilator lint_off PINCONNECTEMPTY */
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0),
        .DIVCLK_DIVIDE(2),
        .CLKFBOUT_MULT_F(27.0),
        .CLKOUT0_DIVIDE_F(25.0),
        .CLKOUT1_DIVIDE(25)              // unused; keeps the simulation model slow
    ) u_scan_mmcm (
        .CLKIN1(CLK_50M), .CLKFBIN(scan_feedback), .CLKFBOUT(scan_feedback),
        .CLKOUT0(clk27_mmcm),
        .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB(),
        .LOCKED(scan_locked), .PWRDWN(1'b0), .RST(1'b0)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    BUFG u_scan_bufg (.I(clk27_mmcm), .O(clk27));

    logic reset27_q1, reset27_q2;
    wire  reset27_async = video_retime_reset || !scan_locked;
    always_ff @(posedge clk27 or posedge reset27_async) begin
        if (reset27_async) begin
            reset27_q1 <= 1'b1;
            reset27_q2 <= 1'b1;
        end else begin
            reset27_q1 <= 1'b0;
            reset27_q2 <= reset27_q1;
        end
    end

    wire        conv_active;
    wire [5:0]  c_r, c_g, c_b;
    wire        c_hb, c_vb, c_hs, c_vs, c_ce;
    wire        sc_wr_req, sc_wr_grant, sc_rd_req, sc_rd_grant, sc_rd_valid;
    wire [19:0] sc_wr_addr, sc_rd_addr;
    wire [15:0] sc_wr_data, sc_rd_data;
    wire [7:0]  sc_lost;
    zxtres_scanconv u_scanconv (
        .clk(clk_57_272), .reset(video_pipe_reset), .ce_in(pic_ce),
        .off(mist_status[35:34] == 2'd1), .mode(mist_status[35:34]),
        .crt_h(eff_crt_h), .crt_v(eff_crt_v),
        .r_in(cr_rgb[23:18]), .g_in(cr_rgb[15:10]), .b_in(cr_rgb[7:2]),
        .hb_in(cr_hb), .vb_in(cr_vb),
        .active(conv_active),
        .wr_req(sc_wr_req), .wr_addr(sc_wr_addr), .wr_data(sc_wr_data), .wr_grant(sc_wr_grant),
        .rd_req(sc_rd_req), .rd_addr(sc_rd_addr), .rd_grant(sc_rd_grant),
        .rd_valid(sc_rd_valid), .rd_data(sc_rd_data),
        .clk27(clk27), .reset27(reset27_q2),
        .r_out(c_r), .g_out(c_g), .b_out(c_b),
        .hb_out(c_hb), .vb_out(c_vb), .hs_out(c_hs), .vs_out(c_vs), .ce_out(c_ce),
        .lost(sc_lost)
    );
    zxtres_sram_ctrl u_sram (
        .clk(clk_57_272), .reset(video_pipe_reset),
        .wr_req(sc_wr_req), .wr_addr(sc_wr_addr), .wr_data(sc_wr_data), .wr_grant(sc_wr_grant),
        .rd_req(sc_rd_req), .rd_addr(sc_rd_addr), .rd_grant(sc_rd_grant),
        .rd_valid(sc_rd_valid), .rd_data(sc_rd_data),
        .SRAM_A(SRAM_A), .SRAM_Q(SRAM_Q), .SRAM_WE(SRAM_WE), .SRAM_OE(SRAM_OE),
        .SRAM_UB(SRAM_UB), .SRAM_LB(SRAM_LB)
    );

    wire [5:0] osd27_r, osd27_g, osd27_b;
    /* verilator lint_off PINCONNECTEMPTY */
    zxtres_osd #(.USE_BLANKS(1'b1), .OUT_COLOR_DEPTH(6), .TITLE_CHARS(11),
                 .TITLE("PCXT ZXTres")) u_osd27 (
        .clk_sys(clk27), .ce(c_ce),
        .SPI_SCK(SPI_SCK), .SPI_SS3(SPI_SS3), .SPI_DI(SPI_DI),
        .R_in(c_r), .G_in(c_g), .B_in(c_b),
        .HBlank(c_hb), .VBlank(c_vb),
        .HSync(c_hs), .VSync(c_vs),
        .R_out(osd27_r), .G_out(osd27_g), .B_out(osd27_b),
        .osd_enable()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    logic [7:0] p27_r, p27_g, p27_b;
    logic       p27_hs, p27_vs;
    always_ff @(posedge clk27) begin
        p27_r  <= c_hb | c_vb ? 8'h00 : {osd27_r, osd27_r[5:4]};
        p27_g  <= c_hb | c_vb ? 8'h00 : {osd27_g, osd27_g[5:4]};
        p27_b  <= c_hb | c_vb ? 8'h00 : {osd27_b, osd27_b[5:4]};
        p27_hs <= c_hs;
        p27_vs <= c_vs;
    end

    // The select changes at a frame boundary of the picture, and the
    // monitor sees a new mode then anyway.
    assign VGA_R  = conv_active ? p27_r  : p57_r;
    assign VGA_G  = conv_active ? p27_g  : p57_g;
    assign VGA_B  = conv_active ? p27_b  : p57_b;
    assign VGA_HS = conv_active ? p27_hs : p57_hs;
    assign VGA_VS = conv_active ? p27_vs : p57_vs;

    // Read-only measurement of the VGA pins and of the machine picture, for
    // the OSD Video info page (read back over the user_io LED byte).
    zxtres_vidinfo u_vidinfo (
        .clk(clk_chipset), .hs_pin(VGA_HS), .vs_pin(VGA_VS),
        .conv_active(conv_active), .doubled(sd_double),
        .vclk(clk_57_272), .vce(pic_ce), .vhb(cr_hb), .vvb(cr_vb),
        .spi_sck(SPI_SCK), .spi_ss(CONF_DATA0), .leds(vi_leds)
    );

    assign LED = pcxt_bios_loaded;
    // Status bit 69, set by the firmware after the confirmation of "Cold
    // Reboot": the board top reconfigures the FPGA from the flash through
    // ICAP (zxtres_pcxt_top.sv), which loads the Spectrum core again.
    assign REBOOT_FPGA = mist_status[69];
    // 16-bit signed audio; the board top turns it into the sigma-delta and
    // I2S outputs.
    assign DAC_L = audio_mix_l_q;
    assign DAC_R = audio_mix_r_q;
endmodule
'''


def hgc_sync_block(lines):
    """The 114.5 MHz always block that samples the Hercules picture into the
    converter's domain."""
    at = index_of(lines, '            hgc_r_meta  <= r;')
    start = at
    while 'always @(posedge clk_114_544)' not in lines[start]:
        start -= 1
    end = at
    while lines[end] != '    end':
        end += 1
    return lines[start:end + 1]


def generate():
    lines = SOURCE.read_text().splitlines()
    # The build options of the MiSTer top, with their defaults; the build
    # defines the profile's values (zxtres/scripts/build_pcxt.sh).
    defines = '\n'.join(span(lines, '`ifndef SYSTEM_VARIANT_TANDY', 'module emu'))
    header = HEADER.replace('@@CONF_STR@@', conf_str())
    header = replace(header, '`timescale 1ns/1ps\n', '`timescale 1ns/1ps\n\n' + defines + '\n')
    out = [header]

    # Build options, menu localparams and the option logic.
    options = '\n'.join(between(lines, '`include "build_id.v"', 'hps_io #(.CONF_STR(CONF_STR)'))
    options = drop(options, '    localparam CONF_STR = {\n', '\n    };\n')
    options = replace(options, '    wire forced_scandoubler;', "    wire forced_scandoubler = 1'b0;")
    options = replace(options, '    wire [1:0] buttons;', "    wire [1:0] buttons = 2'b00;")
    options = replace(options, '    wire [127:0] status;', '    wire [127:0] status = status_zx;')
    options = replace(options, '    wire [7:0]  uart_mode;', "    wire [7:0]  uart_mode = 8'd0;       // no MiSTer UART menu")
    options = drop(options, '    wire [15:0] status_menumask = L_EGA', "2'b00, status[5]};\n")
    out.append(options)
    out.append(MGMT_DECL)
    out.append(MIST_IO)

    # Clocks: the declarations of the MiSTer top, then the MMCMs.
    out += span(lines, '    wire clk_sys;', '    pll pll ')
    out.append(CLOCKS)

    # Resets, memory path, splash, chipset, CPU, audio sources and mixer.
    memory = '\n'.join(span(lines, '    // PCjr: a cartridge is seen by the BIOS', '    altddio_out'))
    out.append(memory)
    out.append(ODDR)
    out += span(lines, '    // Controller-side reset: asserted with reset_sdram', '    assign AUDIO_L   =')
    out.append(AUDIO_STAGE)

    # Baud enables of the serial ports; no UART pins.
    out += span(lines, '    logic clk_uart_ff_1;', '    wire uart_tx, uart_rts, uart_dtr;')
    out.append(UART)

    # The second SD card is not there.
    out += span(lines, '    logic [1:0]  use_mmc;', '    assign  SD_SCK      = spi_clk;')
    out.append(MMC)
    out.append(lines[index_of(lines, '    assign id_video_card')])

    # Video front ends up to the monochrome converters, and the Hercules
    # sampling and line measurement on the 57 MHz clock.
    video = '\n'.join(span(lines, '    wire HBlank;', '    wire fb_enable ='))
    video = replace(video, '    assign CLK_VIDEO = clk_video_out_ps;\n', '')
    # PCXT.sv assigns this wire in an always @* block: Quartus accepts it,
    # Vivado wants a variable.
    video = replace(video, '    wire HBlank_VGA;', '    reg HBlank_VGA;')
    # One event per CGA dot on the 57 MHz clock, which the line doubler takes
    # as a fourth of the clock (ce_pixel_cga is a 28 MHz level, two clocks).
    video = replace(video,
                    '    wire        ce_pixel_cga_vid = cga_scandouble_en ? ce_pixel_cga_2x : ce_pixel_cga;',
                    '    reg         ce_pixel_cga_57_d = 1\'b0;\n'
                    '    always @(posedge clk_57_272) ce_pixel_cga_57_d <= ce_pixel_cga;\n'
                    '    wire        ce_pixel_cga_vid = cga_scandouble_en ? ce_pixel_cga_2x\n'
                    '                                                     : (ce_pixel_cga & ~ce_pixel_cga_57_d);')
    out.append(video)
    out += hgc_sync_block(lines)
    out.append(MAIN_SRC)
    out += block(lines, '    reg splash_vid_sync1', '        .b_out    (main_b)')
    out += ['    );']
    out.append(VIDEO_OUT)
    return '\n'.join(out) + '\n'


def main():
    text = generate()
    if sys.argv[1:] == ['--check']:
        if not TARGET.exists() or TARGET.read_text() != text:
            sys.exit(f'{TARGET.relative_to(ROOT)} is stale: run zxtres/scripts/make_guest.py')
        print('GUEST_CHECK_PASS')
        return
    TARGET.write_text(text, newline=chr(10))   # LF on every host, as git keeps it
    print(f'wrote {TARGET.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
