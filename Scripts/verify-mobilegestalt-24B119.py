#!/usr/bin/env python3
"""Read-only verification of one extracted Mach-O, never mutation authority.

Uses only the Python standard library. The adjacent JSON pins reviewed code
ranges; semantic checks independently resolve table/CFString references and
exercise the actual perfect-hash lookup. No Apple binary is redistributed.
SPDX-License-Identifier: GPL-3.0-only
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import uuid

MANIFEST = Path(__file__).resolve().parents[1] / "docs/evidence/mobilegestalt-24B119.json"


def require(condition, message):
    # Do not use assert: python -O must retain every validation gate.
    if not condition:
        raise ValueError(message)


class MachO:
    def __init__(self, raw):
        self.raw = raw = bytes(raw)
        require(len(raw) >= 32, "Truncated Mach-O header")
        magic, self.cpu, self.subtype, kind, count, size, _, _ = struct.unpack_from("<8I", raw)
        require(magic == 0xFEEDFACF and kind == 6, "Expected little-endian 64-bit dylib")
        require(0 < count <= size // 8 and size <= len(raw) - 32, "Invalid load commands")
        self.sections, self.commands, uuids, builds, ids = [], [], [], [], []
        p, end = 32, 32 + size
        for _ in range(count):
            require(p + 8 <= end, "Truncated load command")
            cmd, length = struct.unpack_from("<II", raw, p)
            require(length >= 8 and length % 8 == 0 and p + length <= end, "Invalid command size")
            self.commands.append(cmd)
            if cmd == 0x19:
                require(length >= 72, "Truncated segment")
                segment = struct.unpack_from("<16sQQQQIIII", raw, p + 8)
                name, va, vm_size, offset, file_size, _, _, nsects, _ = segment
                require(nsects <= (length - 72) // 80 and file_size <= len(raw) - offset,
                        "Invalid segment bounds")
                for i in range(nsects):
                    item = struct.unpack_from("<16s16sQQIIIIIIII", raw, p + 72 + 80 * i)
                    sec, seg, addr, sec_size, fileoff = item[:5]
                    require(seg == name and va <= addr and addr + sec_size <= va + vm_size,
                            "Section escapes segment")
                    if item[8] & 0xFF in (1, 12, 18):  # zerofill sections have no file bytes
                        continue
                    if sec_size:
                        require(offset <= fileoff and fileoff + sec_size <= offset + file_size,
                                "Section escapes file-backed segment")
                        require(not any(addr < s[2] + s[3] and s[2] < addr + sec_size
                                        for s in self.sections), "Overlapping sections")
                        self.sections.append((seg.rstrip(b"\0").decode(), sec.rstrip(b"\0").decode(),
                                              addr, sec_size, fileoff))
            elif cmd == 0x1B:
                require(length == 24, "Invalid LC_UUID")
                uuids.append(str(uuid.UUID(bytes=raw[p + 8:p + 24])).upper())
            elif cmd == 0x32:
                require(length >= 24, "Invalid LC_BUILD_VERSION")
                builds.append(struct.unpack_from("<III", raw, p + 8))
            elif cmd == 0xD:
                require(length >= 24, "Invalid LC_ID_DYLIB")
                off = struct.unpack_from("<I", raw, p + 8)[0]
                require(24 <= off < length and b"\0" in raw[p + off:p + length], "Invalid dylib name")
                ids.append(raw[p + off:p + length].split(b"\0")[0].decode())
            p += length
        require(p == end and len(uuids) == len(builds) == len(ids) == 1, "Ambiguous image identity")
        self.uuid, self.build, self.install_name = uuids[0], builds[0], ids[0]

    def section(self, segment, name):
        hits = [s for s in self.sections if s[:2] == (segment, name)]
        require(len(hits) == 1, "Missing or ambiguous section")
        return hits[0]

    def read(self, address, size):
        hits = [s for s in self.sections if s[2] <= address and address + size <= s[2] + s[3]]
        require(size > 0 and len(hits) == 1, f"Unmapped/ambiguous address {address:#x}")
        s = hits[0]
        p = s[4] + address - s[2]
        return self.raw[p:p + size]

    def word(self, address):
        return struct.unpack("<I", self.read(address, 4))[0]

    def cstring(self, address):
        s = self.section("__TEXT", "__cstring")
        require(s[2] <= address < s[2] + s[3], "Pointer target is not a cstring")
        data = self.read(address, s[2] + s[3] - address)
        require(b"\0" in data, "Unterminated cstring")
        return data.split(b"\0", 1)[0].decode("ascii")


def decode_v5(raw, base, authenticated=False):
    """Decode shared-cache v5 fields; this does NOT authenticate a runtime PAC.

    The extracted artifact has no LC_DYLD_CHAINED_FIXUPS command. Its cache
    pointer representation is independently corroborated by all table strings
    and the code's perfect hash. Slide metadata/page chains were not supplied
    with the extracted file, so this is not a full shared-cache loader.
    """
    require(raw != 0 and bool(raw >> 63) == authenticated, "Unexpected v5 pointer auth form")
    offset = raw & ((1 << 34) - 1)
    if not authenticated:
        require((raw >> 42) & 0x3FF == 0, "Nonzero reserved v5 pointer bits")
        high8 = (raw >> 34) & 0xFF
        return (base + offset) | (high8 << 56)
    return base + offset


def adrp_add(image, address, register):
    a, b = image.word(address), image.word(address + 4)
    require(a & 0x9F00001F == 0x90000000 | register, "Expected ADRP register")
    require(b & 0xFFC003FF == 0x91000000 | (register << 5) | register, "Expected ADD same register")
    imm = ((a >> 5) & 0x7FFFF) << 2 | ((a >> 29) & 3)
    if imm & (1 << 20):
        imm -= 1 << 21
    return (address & ~0xFFF) + (imm << 12) + ((b >> 10) & 0xFFF)


def mov_w(image, address, register):
    word = image.word(address)
    require(word & 0xFFE0001F == 0x52800000 | register, "Expected MOVZ W register")
    return (word >> 5) & 0xFFFF


def load_offset(image, address, opcode, base, target, scale):
    word = image.word(address)
    require(word & 0xFFC003FF == opcode | (base << 5) | target, "Unexpected load addressing")
    return ((word >> 10) & 0xFFF) * scale


def cfstring(image, address, base):
    data = image.read(address, 32)
    target = decode_v5(struct.unpack_from("<Q", data, 16)[0], base)
    value = image.cstring(target)
    require(len(value) == struct.unpack_from("<Q", data, 24)[0], "CFString length mismatch")
    return value


def scan_table(image, table, count, base):
    records, owners, names = [], {}, {}
    for i in range(count):
        address = table + i * 64
        data = image.read(address, 64)
        pointer = struct.unpack_from("<Q", data)[0]
        if not pointer:
            continue
        target = decode_v5(pointer, base)
        key = image.cstring(target)
        require(len(key) == 22 and all(c.isalnum() or c in "+/" for c in key), "Non-key table entry")
        require(key not in names, "Duplicate descriptor key")
        slot = struct.unpack_from("<h", data, 0x3A)[0]
        dtype = struct.unpack_from("<I", data, 0x3C)[0]
        require(-1 <= slot < 720, "Descriptor index outside audited bounds")
        if slot >= 0:
            require(slot not in owners, "Conflicting descriptor slot")
            owners[slot] = key
        record = dict(key=key, string_va=target, descriptor_va=address, ordinal=i,
                      slot=slot, type=dtype, flags=data[0x38])
        names[key] = record
        records.append(record)
    return records, names, owners


def perfect_hash(image, key, association):
    require(len(key) == 22, "Wrong question length")
    def entry(index):
        return struct.unpack("<H", image.read(association + index * 2, 2))[0]
    return entry(ord(key[0])) + entry(ord(key[4]) + 23) + entry(ord(key[9])) + 22


def verify(image, evidence):
    require(len(image.raw) == evidence["size"], "File size mismatch")
    require(hashlib.sha256(image.raw).hexdigest() == evidence["sha256"], "SHA-256 mismatch")
    require(image.uuid == evidence["lc_uuid"], "LC_UUID mismatch")
    require(image.cpu == 0x100000C and image.subtype & 0xFFFFFF == 2, "Expected arm64e")
    version = (27 << 16) | (2 << 8)
    require(image.build == (2, version, version), "Unexpected iOS/minimum/SDK")
    require(image.install_name == "/usr/lib/libMobileGestalt.dylib", "Wrong LC_ID_DYLIB")
    require(0x80000034 not in image.commands, "Unexpected chained-fixups command; review format")
    for block in evidence["code_ranges"]:
        raw = image.read(int(block["start"], 16), int(block["end"], 16) - int(block["start"], 16))
        require(hashlib.sha256(raw).hexdigest() == block["sha256"], "Reviewed control flow changed: " + block["name"])

    # Decode references from the actual instructions, not section-relative guesses.
    table = adrp_add(image, 0x1AFEB0AEC, 0)
    require(table == adrp_add(image, 0x1AFEAFC9C, 10), "Lookup/table getter disagree")
    count = mov_w(image, 0x1AFEB0AE4, 8)
    require(count == 2323, "Wrong descriptor record count")
    section = image.section("__AUTH_CONST", "__const")
    require(table - section[2] == 0x830, "Wrong descriptor table boundary")
    records, names, owners = scan_table(image, table, count, int(evidence["shared_cache_base"], 16))
    association = adrp_add(image, 0x1AFEAFC64, 9)
    for record in records:
        require(perfect_hash(image, record["key"], association) == record["ordinal"],
                "Actual perfect-hash lookup does not select descriptor")

    rows = []
    strings = image.section("__TEXT", "__cstring")
    cstrings = image.read(strings[2], strings[3]).split(b"\0")
    for expected in evidence["questions"]:
        key = base64.b64encode(hashlib.md5(("MGCopyAnswer" + expected["name"]).encode(),
                                          usedforsecurity=False).digest()).decode().rstrip("=")
        require(key == expected["hash"] and cstrings.count(key.encode()) == 1, "Question/hash ambiguity")
        require(cstrings.count(expected["name"].encode()) == 1, "Question name is missing or duplicated")
        name_va = int(expected["name_va"], 16)
        require(image.cstring(name_va) == expected["name"] and image.read(name_va - 1, 1) == b"\0",
                "Question name address mismatch")
        getter = int(expected["getter_va"], 16)
        require(cfstring(image, adrp_add(image, getter, 0), int(evidence["shared_cache_base"], 16)) == expected["name"],
                "Exported getter/question-name mismatch")
        branch = image.word(getter + 8)
        displacement = branch & 0x3FFFFFF
        if displacement & (1 << 25):
            displacement -= 1 << 26
        require(branch & 0xFC000000 == 0x14000000 and getter + 8 + displacement * 4 == 0x1AFEAFE70,
                "Question getter does not call MGGetBoolAnswer")
        require(key in names, "Missing descriptor")
        actual = names[key]
        require(actual["string_va"] == int(expected["hash_va"], 16), "Question hash address mismatch")
        require(all(actual[k] == expected[k] for k in ("slot", "type", "flags", "ordinal")), "Mapping mismatch")
        require(actual["descriptor_va"] == int(expected["descriptor_va"], 16) and
                actual["descriptor_va"] - section[2] == int(expected["section_offset"], 16),
                "Descriptor offset mismatch")
        handler = struct.unpack("<Q", image.read(actual["descriptor_va"] + 8, 8))[0]
        require(decode_v5(handler, int(evidence["shared_cache_base"], 16), authenticated=True) == int(expected["handler_va"], 16),
                "Descriptor callback target mismatch (offline decoding, no PAC authentication)")
        rows.append(dict(name=expected["name"], **actual,
                         value_offset=actual["slot"] * 8, validity_offset=5760 + actual["slot"]))

    # Derive field widths and offsets from the two consumers.
    require(load_offset(image, 0x1AFEAFD50, 0x79400000, 20, 8, 2) == 0x3A, "Read index field")
    require(load_offset(image, 0x1AFEAFD70, 0x79800000, 20, 9, 2) == 0x3A, "Signed read index")
    require(load_offset(image, 0x1AFEAFD8C, 0xB9400000, 20, 10, 4) == 0x3C, "Read type field")
    require(load_offset(image, 0x1AFEB1B24, 0x79400000, 1, 8, 2) == 0x3A, "Write index field")
    require(load_offset(image, 0x1AFEB1B58, 0x79800000, 20, 9, 2) == 0x3A, "Signed write index")
    require(mov_w(image, 0x1AFEAFD78, 11) == mov_w(image, 0x1AFEB1C2C, 9) == 5760,
            "Read/write validity bases disagree")
    require(mov_w(image, 0x1AFEF4868, 1) == 6480 and mov_w(image, 0x1AFEB0A00, 8) == 6480,
            "Allocation/load size disagree")

    # Follow both writer and loader ADRP+ADD pairs to actual CFString objects.
    base = int(evidence["shared_cache_base"], 16)
    require(image.cstring(adrp_add(image, 0x1AFEAF614, 8)) == "MGCopyAnswer" and
            image.cstring(adrp_add(image, 0x1AFEAF620, 2)) == "%s%s", "Question hash prefix/format changed")
    pairs = [(0x1AFEF489C, 0x1AFEB027C, "CacheVersion"),
             (0x1AFEF48B0, 0x1AFEB02CC, "CacheData"),
             (0x1AFEF48C4, None, "CacheExtra"),
             (0x1AFEF48D8, 0x1AFEB02A0, "CacheUUID")]
    for writer, loader, name in pairs:
        address = adrp_add(image, writer, 1)
        require(cfstring(image, address, base) == name, "Wrong dictionary key reference")
        if loader:
            require(adrp_add(image, loader, 1) == address, "Loader/writer dictionary keys disagree")
    cache_uuid_address = adrp_add(image, 0x1AFEF48E0, 2)
    require(cache_uuid_address == adrp_add(image, 0x1AFEB02B8, 26), "CacheUUID producer/validator disagree")
    require(cfstring(image, cache_uuid_address, base) == evidence["cache_uuid"], "CacheUUID constant mismatch")
    require(cfstring(image, adrp_add(image, 0x1AFEF4888, 0), base) ==
            base64.b64encode(hashlib.md5(b"MGCopyAnswerBuildVersion", usedforsecurity=False).digest()).decode().rstrip("="),
            "CacheVersion producer is not BuildVersion")
    return dict(offline_binary_mapping="PASS", runtime_binding="INCOMPLETE",
                safe_mutation_authorization="NO-GO", lc_uuid=image.uuid, cache_uuid=evidence["cache_uuid"],
                table_va=hex(table), table_records=count, populated_records=len(records),
                occupied_slots=len(owners), code_ranges_checked=len(evidence["code_ranges"]), questions=rows,
                limitations=["No current device plist or loaded image", "No runtime PAC authentication",
                             "No original shared-cache slide page chains in extracted Mach-O",
                             "Device/build provenance supplied by research context, not encoded in LC_UUID"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    try:
        result = verify(MachO(args.binary.read_bytes()), json.loads(MANIFEST.read_text()))
    except (ValueError, OSError, struct.error, UnicodeError) as error:
        parser.exit(1, f"FAIL: {error}\n")
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
