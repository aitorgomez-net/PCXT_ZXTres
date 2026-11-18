#!/usr/bin/env python3
"""Run the XT-IDE Universal BIOS ROM against a model of the PCXT ZXTRES hard
disk path (XT2IDE + rtl/common/ide.v + zxtres_ide_store.sv), on the unicorn
CPU emulator with a minimal fake PC BIOS, to see what the XT-IDE BIOS does
with the disk: the port accesses, the ATA commands, and whether it reaches
the boot sector at 0000:7C00.

  xub_emu.py <xtide rom> <disk image> [--mister] [--trace]

--mister makes the device model write the task file back after each command
the way MiSTer's Main (ide.cpp) does; without it the model does what
zxtres_ide_store.sv does.
"""
import struct
import sys
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_INSN, UC_HOOK_CODE, UC_HOOK_BLOCK
from unicorn.x86_const import *

ROM_SEG = 0xEC00
STUB_SEG = 0xF000
STUB_OFF = 0x1000           # vector n -> F000:1000+n, an IRET serviced in Python
STOP_SEG, STOP_OFF = 0xF000, 0x2000

rom = open(sys.argv[1], 'rb').read()
disk = open(sys.argv[2], 'rb').read()
MISTER = '--mister' in sys.argv
ABORT_C6 = '--abort-c6' in sys.argv     # the fix: no block mode (IDENTIFY word 47 is 0)
TRACE = '--trace' in sys.argv

# --------------------------------------------------------------- device
class Ide:
    """ide.v registers as the XT side sees them, and the store's answers."""
    def __init__(self, img):
        self.img = img
        self.total = len(img) // 512
        self.cyl, self.heads, self.spt = self.total // 1008, 16, 63
        self.cheads, self.cspt = self.heads, self.spt
        self.present = 0b01
        self.features = 0
        self.sector_count = 1
        self.sector = 1
        self.cylinder = 0xFFFFFFFF
        self.drv = 0
        self.cmd = 0
        self.status = 0x80
        self.error = 0
        self.buf = []
        self.last = False
        self.pending = None      # what the store does next: ('reset',) ('cmd',) ('next',)
        self.pending = ('reset',)
        self.remain = 0
        self.lba = 0
        self.log = []

    def name(self):
        return 'slave' if self.drv & 0x10 else 'master'

    def sel_present(self):
        return bool(self.present & (2 if self.drv & 0x10 else 1))

    def ident(self):
        w = [0] * 256
        w[0] = 0x0040; w[1] = self.cyl; w[3] = self.heads; w[6] = self.spt
        w[49] = 0x0200; w[53] = 1; w[54] = self.cyl; w[55] = self.cheads; w[56] = self.cspt
        cap = self.cyl * self.cheads * self.cspt
        w[57] = cap & 0xFFFF; w[58] = cap >> 16
        w[60] = self.total & 0xFFFF; w[61] = self.total >> 16; w[80] = 4
        def text(s, first):
            for i in range(0, len(s), 2):
                w[first + i // 2] = (ord(s[i]) << 8) | ord(s[i + 1])
        text('PCAT286ZXTRES0000001', 10); text('1.00    ', 23)
        text('PCAT-286 ZXTRES HARD DISK'.ljust(40), 27)
        return w

    def mgmt_status(self, stat):
        # status <= {wd[15:14], 0, wd[12:11], 00, wd[8]}; last_read <= wd[9]
        self.status = (stat & 0xC0) | (stat & 0x18) | (stat & 0x01)
        self.last = bool(stat & 0x02)

    def chs_or_lba(self):
        if self.drv & 0x40:
            return ((self.drv & 0x0F) << 24) | ((self.cylinder & 0xFFFF) << 8) | (self.sector & 0xFF)
        s = self.sector & 0xFF
        h = self.drv & 0x0F
        c = self.cylinder & 0xFFFF
        if s == 0 or s > self.cspt or h >= self.cheads:
            return None
        return (c * self.cheads + h) * self.cspt + s - 1

    def put_taskfile(self, lba):
        # MiSTer put_lba(): the registers name the last sector done
        lba -= 1
        if self.drv & 0x40:
            self.sector = (self.sector & 0xFF00) | (lba & 0xFF)
            self.cylinder = (self.cylinder & 0xFFFF0000) | ((lba >> 8) & 0xFFFF)
            self.drv = (self.drv & 0xF0) | ((lba >> 24) & 0x0F)
        else:
            hspt = self.cheads * self.cspt
            c, r = divmod(lba, hspt)
            h, s = divmod(r, self.cspt)
            self.cylinder = (self.cylinder & 0xFFFF0000) | c
            self.drv = (self.drv & 0xF0) | h
            self.sector = (self.sector & 0xFF00) | (s + 1)

    def service(self):
        """The store, run when ide.v has a request for it."""
        p, self.pending = self.pending, None
        if p == ('reset',):
            self.error = 1 if not MISTER else 0
            self.sector_count = (self.sector_count & 0xFF00) | 1
            self.sector = (self.sector & 0xFF00) | 1
            self.cylinder &= 0xFFFF0000
            self.drv = 0xA0
            self.mgmt_status(0x50)
            self.log.append('reset served')
            return
        if p == ('next',):
            self.lba += 1
            self.remain -= 1
            self.push_sector()
            return
        cmd = self.cmd
        self.log.append(f'command {cmd:02X} {self.name()} count {self.sector_count & 0xFF} '
                        f'sector {self.sector & 0xFF} cyl {self.cylinder & 0xFFFF} drv {self.drv:02X}')
        self.error = 0
        if not self.sel_present():
            self.mgmt_status(0x00)
            return
        if cmd in (0x20, 0x21):
            lba = self.chs_or_lba()
            n = self.sector_count & 0xFF or 256
            if lba is None or lba + 0 >= self.total:
                self.error = 0x10; self.mgmt_status(0x55)
                self.log.append(f'  -> IDNF (lba {lba})')
                return
            self.lba, self.remain = lba, n
            self.log.append(f'  -> read lba {lba} x{n}')
            self.push_sector()
        elif cmd == 0xEC:
            self.buf = self.ident()
            if MISTER:
                self.sector_count &= 0xFF00; self.sector &= 0xFF00; self.cylinder &= 0xFFFF0000
                self.drv = (self.drv & 0x10) | 0xA0
            self.mgmt_status(0x5E)
        elif cmd == 0x91:
            self.cspt = self.sector_count & 0xFF
            self.cheads = (self.drv & 0x0F) + 1
            self.mgmt_status(0x54)
        elif cmd == 0x90:
            self.error = 1; self.mgmt_status(0x54)
        elif cmd == 0xC6 and ABORT_C6:
            self.error = 0x04; self.mgmt_status(0x55)
            self.log.append('  -> aborted (no block mode)')
        elif cmd in (0x40, 0x41, 0xEF, 0xC6, 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7) \
                or cmd >> 4 in (1, 7):
            self.mgmt_status(0x54)
        else:
            self.error = 0x04; self.mgmt_status(0x55)
            self.log.append('  -> aborted')

    def push_sector(self):
        if self.lba >= self.total:
            self.error = 0x10; self.mgmt_status(0x55); return
        d = self.img[self.lba * 512:(self.lba + 1) * 512]
        self.buf = list(struct.unpack('<256H', d))
        if MISTER:
            self.sector_count = (self.sector_count & 0xFF00) | ((self.sector_count - 1) & 0xFF)
            self.put_taskfile(self.lba + 1)
        self.mgmt_status(0x5E if self.remain == 1 else 0x5C)

    # ---- XT side, through XT2IDE (A3 picks the control block, +8 the latch)
    def io_read(self, reg):
        if self.pending:
            self.service()
        if not self.present:
            return 0xFFFF
        if reg == 0:
            if not (self.status & 0x08):
                return 0
            v = self.buf.pop(0)
            if not self.buf:
                if self.last:
                    self.status = 0x40
                else:
                    self.status = 0x80
                    self.pending = ('next',)
            return v
        return {1: self.error, 2: self.sector_count & 0xFF, 3: self.sector & 0xFF,
                4: self.cylinder & 0xFF, 5: (self.cylinder >> 8) & 0xFF, 6: self.drv,
                7: self.status, 14: self.status,
                15: 0x80 | ((~self.drv & 0x0F) << 2) | (0 if self.drv & 0x10 else 1) << 1 | ((self.drv >> 4) & 1)
                }.get(reg, 0)

    def io_write(self, reg, v):
        if self.pending and self.pending != ('reset',):
            self.service()
        if not self.present:
            return
        if reg == 1: self.features = v
        elif reg == 2: self.sector_count = ((self.sector_count << 8) | v) & 0xFFFF
        elif reg == 3: self.sector = ((self.sector << 8) | v) & 0xFFFF
        elif reg == 4:
            lo = self.cylinder & 0xFF
            self.cylinder = (self.cylinder & 0xFF00FF00) | (lo << 16) | v
        elif reg == 5:
            hi = (self.cylinder >> 8) & 0xFF
            self.cylinder = (self.cylinder & 0x00FF00FF) | (hi << 24) | (v << 8)
        elif reg == 6: self.drv = v
        elif reg == 7:
            self.cmd = v; self.status = 0x80; self.pending = ('cmd',)
        elif reg == 14:
            if v & 0x04:
                self.status = 0x80; self.pending = ('reset',)
                self.log.append('SRST')

ide = Ide(disk)
latch = 0xFF
wlatch = 0xFF

# ------------------------------------------------------------------ cpu
mu = Uc(UC_ARCH_X86, UC_MODE_16)
mu.mem_map(0, 0x100000)
mu.mem_write(ROM_SEG * 16, rom)
mu.mem_write(STUB_SEG * 16 + STUB_OFF, b'\xCF' * 256)
mu.mem_write(STOP_SEG * 16 + STOP_OFF, b'\xF4')
for n in range(256):
    mu.mem_write(n * 4, struct.pack('<HH', STUB_OFF + n, STUB_SEG))
# BIOS data area
bda = 0x400
mu.mem_write(bda + 0x10, struct.pack('<H', 0x0061))     # equipment: 1 floppy, CGA 80
mu.mem_write(bda + 0x13, struct.pack('<H', 640))
mu.mem_write(bda + 0x49, bytes([3]))
mu.mem_write(bda + 0x4A, struct.pack('<H', 80))
mu.mem_write(bda + 0x63, struct.pack('<H', 0x3D4))
mu.mem_write(bda + 0x4C, struct.pack('<H', 0x1000))   # page size
mu.mem_write(bda + 0x60, struct.pack('<H', 0x0607))
mu.mem_write(bda + 0x84, bytes([24]))
mu.mem_write(bda + 0x75, bytes([0]))
ticks = 0
screen = []

def set_ticks():
    mu.mem_write(bda + 0x6C, struct.pack('<I', ticks))

def flags_frame():
    ss = mu.reg_read(UC_X86_REG_SS); sp = mu.reg_read(UC_X86_REG_SP)
    return ss * 16 + sp + 4

def set_cf(v):
    a = flags_frame()
    f = struct.unpack('<H', mu.mem_read(a, 2))[0]
    f = (f | 1) if v else (f & ~1)
    mu.mem_write(a, struct.pack('<H', f))

def set_zf(v):
    a = flags_frame()
    f = struct.unpack('<H', mu.mem_read(a, 2))[0]
    f = (f | 0x40) if v else (f & ~0x40)
    mu.mem_write(a, struct.pack('<H', f))

def r(reg): return mu.reg_read(reg)
def w(reg, v): mu.reg_write(reg, v & 0xFFFF)

def bios_service(n):
    global ticks
    ah = r(UC_X86_REG_AX) >> 8
    al = r(UC_X86_REG_AX) & 0xFF
    if n == 0x10:
        if ah in (0x0E, 0x09, 0x0A):
            screen.append(chr(al) if 32 <= al < 127 or al in (10, 13) else '.')
        elif ah == 0x03:
            w(UC_X86_REG_DX, 0); w(UC_X86_REG_CX, 0x0607)
        elif ah == 0x0F:
            w(UC_X86_REG_AX, 0x5003); w(UC_X86_REG_BX, 0)
    elif n == 0x11:
        w(UC_X86_REG_AX, 0x0061)
    elif n == 0x12:
        w(UC_X86_REG_AX, 640)
    elif n == 0x13:
        log(f'INT 13h (system BIOS, floppy) AH={ah:02X} DL={r(UC_X86_REG_DX) & 0xFF:02X}')
        w(UC_X86_REG_AX, 0x8000 | al); set_cf(True)
    elif n == 0x15:
        w(UC_X86_REG_AX, 0x8600 | al); set_cf(True)
    elif n == 0x16:
        ticks += 1; set_ticks()
        if ah in (0x01, 0x11):
            set_zf(True)
        elif ah in (0x00, 0x10):
            w(UC_X86_REG_AX, 0x1C0D)
    elif n == 0x1A:
        ticks += 1; set_ticks()
        if ah == 0:
            w(UC_X86_REG_CX, ticks >> 16); w(UC_X86_REG_DX, ticks)
            w(UC_X86_REG_AX, 0)
    elif n == 0x18:
        raise Stop('INT 18h: no bootable disk (ROM BASIC)')
    elif n == 0x19:
        raise Stop('system INT 19h reached')

class Stop(Exception):
    pass

def log(s):
    print(s)

def hook_intr(uc, intno, user):
    if intno == 0:
        stop_reason[0] = f'divide error at {r(UC_X86_REG_CS):04X}:{r(UC_X86_REG_IP):04X}'; uc.emu_stop(); return
    # deliver through the vector table, as a real CPU does
    ip = r(UC_X86_REG_IP); cs = r(UC_X86_REG_CS)
    fl = r(UC_X86_REG_EFLAGS) & 0xFFFF
    ss = r(UC_X86_REG_SS); sp = (r(UC_X86_REG_SP) - 6) & 0xFFFF
    uc.mem_write(ss * 16 + sp, struct.pack('<HHH', ip, cs, fl))
    w(UC_X86_REG_SP, sp)
    uc.reg_write(UC_X86_REG_EFLAGS, fl & ~0x0300)
    off, seg = struct.unpack('<HH', uc.mem_read(intno * 4, 4))
    if TRACE and intno == 0x13:
        log(f'  int 13h AX={r(UC_X86_REG_AX):04X} CX={r(UC_X86_REG_CX):04X} DX={r(UC_X86_REG_DX):04X} -> {seg:04X}:{off:04X}')
    uc.reg_write(UC_X86_REG_CS, seg)
    uc.reg_write(UC_X86_REG_IP, off)

stop_reason = [None]

def hook_code(uc, addr, size, user):
    if STUB_SEG * 16 + STUB_OFF <= addr < STUB_SEG * 16 + STUB_OFF + 256:
        try:
            bios_service(addr - STUB_SEG * 16 - STUB_OFF)
        except Stop as e:
            stop_reason[0] = str(e); uc.emu_stop()
    elif addr == STOP_SEG * 16 + STOP_OFF:
        stop_reason[0] = 'returned'; uc.emu_stop()
    elif addr == 0x7C00:
        stop_reason[0] = 'jumped to the boot sector at 0000:7C00'; uc.emu_stop()

blocks = [0]
recent = []
def hook_block(uc, addr, size, user):
    global ticks
    blocks[0] += 1
    recent.append(addr)
    if len(recent) > 400: recent.pop(0)
    if blocks[0] % 3000 == 0:
        ticks += 1; set_ticks()
    if blocks[0] > 60_000_000:
        stop_reason[0] = 'instruction budget'; uc.emu_stop()

def port_reg(port):
    off = port - 0x300
    a3, a0 = (off >> 3) & 1, off & 1
    reg = (off & 6) | a0
    return a3, reg

def hook_in(uc, port, size, user):
    global latch, ticks
    if size == 2:
        lo = hook_in(uc, port, 1, user); hi = hook_in(uc, port + 1, 1, user)
        return lo | (hi << 8)
    if 0x300 <= port < 0x310:
        a3, reg = port_reg(port)
        if not a3:
            v = ide.io_read(reg)
            if reg == 0:
                latch = v >> 8
            v &= 0xFF
        elif reg == 0:
            v = latch
        elif reg in (6, 7):
            v = ide.io_read(8 + reg) & 0xFF
        else:
            v = 0xFF
        if TRACE: log(f'    in  {port:03X} -> {v:02X}')
        return v
    if port == 0x60: return 0
    if port == 0x64: return 0x14
    return 0xFF

def hook_out(uc, port, size, value, user):
    global wlatch
    if size == 2:
        hook_out(uc, port, 1, value & 0xFF, user); hook_out(uc, port + 1, 1, value >> 8, user); return
    if 0x300 <= port < 0x310:
        a3, reg = port_reg(port)
        if TRACE: log(f'    out {port:03X} <- {value:02X}')
        if not a3:
            ide.io_write(reg, value)
        elif reg == 0:
            wlatch = value
        elif reg in (6, 7):
            ide.io_write(8 + reg, value)

mu.hook_add(UC_HOOK_INTR, hook_intr)
mu.hook_add(UC_HOOK_CODE, hook_code, begin=STUB_SEG * 16 + STUB_OFF, end=STUB_SEG * 16 + STOP_OFF + 1)
mu.hook_add(UC_HOOK_CODE, hook_code, begin=0x7C00, end=0x7C00)
mu.hook_add(UC_HOOK_BLOCK, hook_block)
mu.hook_add(UC_HOOK_INSN, hook_in, None, 1, 0, UC_X86_INS_IN)
mu.hook_add(UC_HOOK_INSN, hook_out, None, 1, 0, UC_X86_INS_OUT)

def run(cs, ip, what):
    stop_reason[0] = None
    mu.reg_write(UC_X86_REG_SS, 0x0030); mu.reg_write(UC_X86_REG_SP, 0x0100)
    mu.reg_write(UC_X86_REG_DS, 0x0040); mu.reg_write(UC_X86_REG_ES, 0)
    mu.reg_write(UC_X86_REG_EFLAGS, 0x0202)
    # return address: a far return frame (init) or an iret frame (int 19h)
    sp = 0x0100 - 6
    mu.mem_write(0x300 + sp, struct.pack('<HHH', STOP_OFF, STOP_SEG, 0x0202))
    mu.reg_write(UC_X86_REG_SP, sp)
    start = cs * 16 + ip
    mu.reg_write(UC_X86_REG_CS, cs)   # unicorn takes begin as linear, IP = begin - CS base
    try:
        mu.emu_start(start, STOP_SEG * 16 + STOP_OFF, count=0)
        if stop_reason[0] is None: stop_reason[0] = 'returned'
    except Exception as e:
        stop_reason[0] = f'CPU exception {e} at {r(UC_X86_REG_CS):04X}:{r(UC_X86_REG_IP):04X}'
    print(f'== {what}: {stop_reason[0]}')
    if TRACE or 'exception' in (stop_reason[0] or ''):
        print('  last blocks:', ' '.join(f'{a >> 4:05X}' if False else f'{a:05X}' for a in recent[-int(sys.argv[-1][6:]) if sys.argv[-1].startswith('--last') else -25:]))

def flush_log():
    for l in ide.log:
        print('  ide:', l)
    ide.log.clear()
    if screen:
        print('  screen:', ''.join(screen).replace('\r', '').replace('\n', ' | '))
        screen.clear()

print(f'model: {"MiSTer Main" if MISTER else "zxtres_ide_store"}; disk {ide.total} sectors, '
      f'{ide.cyl}/{ide.heads}/{ide.spt}')
mu.reg_write(UC_X86_REG_CS, ROM_SEG)
run(ROM_SEG, 3, 'option ROM init')
flush_log()
print('  BDA hard disks:', mu.mem_read(bda + 0x75, 1)[0])
off, seg = struct.unpack('<HH', mu.mem_read(0x19 * 4, 4))
print(f'  INT 13h -> {struct.unpack("<HH", mu.mem_read(0x13*4,4))[1]:04X}:{struct.unpack("<HH", mu.mem_read(0x13*4,4))[0]:04X}, '
      f'INT 19h -> {seg:04X}:{off:04X}')
run(seg, off, 'INT 19h boot')
flush_log()
if stop_reason[0] and '7C00' in stop_reason[0]:
    got = bytes(mu.mem_read(0x7C00, 512))
    print('  boot sector matches LBA 0:', got == disk[:512], got[:8].hex(), got[510:].hex())
