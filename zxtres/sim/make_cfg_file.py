#!/usr/bin/env python3
"""Write a PCXT.CFG for the ZXTRES+ firmware (zxtres/firmware/overrides.c).

  make_cfg_file.py OUT [--disk0 PATH] [--disk1 PATH] [--floppy-a PATH]
                       [--floppy-b PATH] [--pcxt PATH] [--tandy PATH]
                       [--ec00 PATH] [--ega PATH] [--pcjr PATH]
                       [--low HEX] [--high HEX] [--blank]

PATH is the file's path from the root of the card, NAME.EXT separated by
'/' ("DISKS/BOOT.VHD"). The ROM paths left empty load the default files
(PCXT.ROM, TANDY.ROM, EC00.ROM, EGA.ROM, PCJR.ROM, in the folder PCXT or
else the root). The status word halves default to 0, the OSD's defaults.
--blank writes the zeroed sector a new card starts with, which is all
PCXT.CFG needs to be before the first Save settings.

Layout (one sector): "PCXT", version 1, the low and high status words at 8
and 12, then from byte 32 nine paths of 52 bytes ending in a zero: hard disk
0, hard disk 1, floppy A, floppy B, then the PCXT, Tandy, EC00, EGA and PCjr
ROM files.
"""
import argparse
import struct
from pathlib import Path

PATHS = 32
PATH_SIZE = 52
UNITS = ('disk0', 'disk1', 'floppy-a', 'floppy-b', 'pcxt', 'tandy', 'ec00', 'ega', 'pcjr')


def main():
    parser = argparse.ArgumentParser(usage=__doc__)
    parser.add_argument('out')
    for name in UNITS:
        parser.add_argument('--' + name, default='')
    parser.add_argument('--low', default='0')
    parser.add_argument('--high', default='0')
    parser.add_argument('--blank', action='store_true')
    args = parser.parse_args()

    sector = bytearray(512)
    if not args.blank:
        sector[0:16] = struct.pack('<4sB3xII', b'PCXT', 1, int(args.low, 16), int(args.high, 16))
        for index, name in enumerate(UNITS):
            data = getattr(args, name.replace('-', '_')).upper().encode()
            if len(data) >= PATH_SIZE:
                raise SystemExit(f'{data.decode()}: longer than {PATH_SIZE - 1} characters')
            start = PATHS + index * PATH_SIZE
            sector[start:start + len(data)] = data
    Path(args.out).write_bytes(sector)


if __name__ == '__main__':
    main()
