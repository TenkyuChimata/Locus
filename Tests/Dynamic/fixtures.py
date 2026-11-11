"""Synthetic loaded-image snapshots; no Apple binary or device data.

Instruction operands are independently assembled here to test the production
parser's address relationships, including ASLR and negative ADRP displacements.
"""
import pathlib
import plistlib
import struct
import sys


def snapshot(slots=16, slide=0, cache_uuid="5E9DE961-58CA-4602-BB9A-576AC561936B", target_slots=None):
    target_slots = target_slots or [2, 7, 13]
    base = 0x100000000
    text_addr, strings_addr, table_addr, cf_addr = [base + x + slide for x in (0x1000, 0x5000, 0x8000, 0x9000)]
    text = bytearray(0x1000)
    strings = bytearray()
    cf = bytearray(5 * 32)
    table = bytearray(0x30 + 7 * 64)

    def put(data, offset, value, size=4):
        data[offset:offset + size] = value.to_bytes(size, 'little')

    def string(value):
        address = strings_addr + len(strings)
        strings.extend(value.encode() + b'\0')
        return address

    def pair(offset, address, register):
        pc = text_addr + offset
        delta = ((address & ~4095) - (pc & ~4095)) // 4096 & ((1 << 21) - 1)
        put(text, offset, 0x90000000 | register | (delta & 3) << 29 | (delta >> 2) << 5)
        put(text, offset + 4, 0x91000000 | register | register << 5 | (address & 4095) << 10)

    def branch(offset, target):
        put(text, offset, 0x94000000 | (((target - text_addr - offset) // 4) & 0x3FFFFFF))

    def mov(offset, immediate, register):
        put(text, offset, 0x52800000 | register | immediate << 5)

    keys = ["CacheVersion", "CacheData", "CacheExtra", "CacheUUID", cache_uuid]
    for i, key in enumerate(keys):
        put(cf, i * 32 + 8, 0x7C8, 8)
        put(cf, i * 32 + 16, string(key), 8)
        put(cf, i * 32 + 24, len(key), 8)
    for offset, word in {
        0x84: 0xD2800000, 0x90: 0xAA0003F4, 0x9C: 0xAA1403E0, 0xA4: 0xF9001BE0,
        0x130: 0x12800008, 0x134: 0xB81943A8, 0x138: 0xD101B3A0, 0x140: 0xAA0003F7,
        0x17C: 0x8B1C1AF8, 0x180: 0xF9400301, 0x18C: 0x79C07709, 0x198: 0x3940E309,
    }.items():
        put(text, offset, word)
    mov(0x88, slots * 9, 1)
    mov(0x94, slots * 9, 1)
    for offset in (0x8C, 0x98, 0xA0):
        branch(offset, text_addr + 0xA00 + offset)
    pair(0xA8, strings_addr, 0)
    put(text, 0xB0, 0xD2800001)
    branch(0xB4, text_addr + 0xE00)
    put(text, 0xB8, 0xAA0003F5)
    for i in range(3):
        p = 0xBC + i * 20
        pair(p, cf_addr + i * 32, 1)
        put(text, p + 8, 0xAA1303E0)
        put(text, p + 12, (0xAA1503E2, 0xAA1403E2, 0xAA1603E2)[i])
        branch(p + 16, text_addr + 0xC00)
    pair(0xF8, cf_addr + 96, 1)
    pair(0x100, cf_addr + 128, 2)
    put(text, 0x108, 0xF90023F3)
    put(text, 0x10C, 0xAA1303E0)
    branch(0x110, text_addr + 0xC00)
    branch(0x13C, text_addr + 0x800)
    mov(0x800, 7, 8)
    put(text, 0x804, 0xB9000008)
    pair(0x808, table_addr + 0x30, 0)
    put(text, 0x810, 0xD65F03C0)
    for offset, word in {
        0: 0x79407688, 4: 0x7100011F | (slots - 1) << 10, 8: 0x54000069,
        0x20: 0x79807689, 0x24: 0x8B09010A, 0x2C: 0x8B0B014A,
        0x30: 0x3940014A, 0x34: 0x7100055F, 0x38: 0x54000161, 0x3C: 0xB9403E8A,
        0xAC: 0x71002D5F, 0xB0: 0x54000361, 0xB4: 0xD37DF129, 0xB8: 0x38696908,
    }.items():
        put(text, 0x400 + offset, word)
    mov(0x428, slots * 8, 11)
    pair(0x600, cf_addr + 96, 1)
    pair(0x618, cf_addr + 128, 26)
    pair(0x62C, cf_addr + 32, 1)
    for offset, word in {8: 0xAA1303E0, 16: 0xB4000040, 20: 0xAA0003F9,
                         32: 0xAA1A03E1, 40: 0x34000040}.items():
        put(text, 0x600 + offset, word)
    for offset in (0x60C, 0x624, 0x638):
        branch(offset, text_addr + 0xD00)
    mov(0x668, slots * 9, 2)
    # Three real question hashes plus three nontarget placeholders and a null.
    hashes = ['iyfxmLogGVIaH7aEgqwcIA', '4snMZS8LJkSctKypt2m+xA', 'hiHut/WR+B9Lx/vd0WyeNg',
              'A' * 22, 'B' * 22, 'C' * 22]
    for i, key in enumerate(hashes):
        p = 0x30 + i * 64
        put(table, p, string(key), 8)
        put(table, p + 56, 0x1C if i == 2 else 0x19, 1)
        put(table, p + 58, (target_slots + [0, 1, slots - 1])[i], 2)
        put(table, p + 60, 11)
    sections = [('__TEXT', '__text', text_addr, text), ('__TEXT', '__cstring', strings_addr, strings),
                ('__AUTH_CONST', '__const', table_addr, table), ('__AUTH_CONST', '__cfstring', cf_addr, cf)]
    commands = bytearray(struct.pack('<II16s', 0x1B, 24, bytes(range(16))))
    for segment in ('__TEXT', '__AUTH_CONST'):
        group = [s for s in sections if s[0] == segment]
        low = min(s[2] for s in group) - slide
        high = max(s[2] + len(s[3]) for s in group) - slide
        commands += struct.pack('<II16sQQQQIIII', 0x19, 72 + len(group) * 80, segment.encode(),
                                low, high - low, 0, high - low, 7, 5, len(group), 0)
        for seg, name, address, data in group:
            commands += struct.pack('<16s16sQQIIIIIIII', name.encode(), seg.encode(), address - slide,
                                    len(data), 0, 3, 0, 0, 0, 0, 0, 0)
    header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 2, 6, 3, len(commands), 0, 0) + commands
    return dict(header=header, slide=slide, writerAddress=text_addr,
                sections=[dict(segment=seg, name=name, address=addr, data=bytes(data), pointers=bytes(data))
                          for seg, name, addr, data in sections])


if __name__ == '__main__':
    dest = pathlib.Path(sys.argv[1])
    for name, slots, slide in [('base', 16, 0), ('other', 32, 0x234000), ('negative', 16, -0x2000)]:
        (dest / (name + '.plist')).write_bytes(plistlib.dumps(snapshot(slots, slide), fmt=plistlib.FMT_BINARY))
    (dest / 'original.plist').write_bytes(plistlib.dumps(
        snapshot(720, 0x1000, '48CB1FAC-755B-435F-9A01-A20E5D810EA9', [383, 506, 694]),
        fmt=plistlib.FMT_BINARY))
