#!/usr/bin/env python3
"""Read-only plist analysis. Emit only schema, aggregate differences and safe keys.

No device identifier blobs, raw CacheData, or arbitrary CacheExtra values are
exported. Structural candidates do not establish descriptor semantics.
SPDX-License-Identifier: GPL-3.0-only
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import uuid

SAFE_KEYS = {
    "ProductType": "h9jDsbgj7xIVeIQ8S3/X3Q",
    "HardwarePlatform": "5pYKlGnYYBzGvAlIU8RjEQ",
    "HWModelStr": "/YYygAofPDbhrwToVsXdeA",
    "BuildVersion": "mZfUC7qo4pURNhyMHZ62RQ",
    "ProductVersion": "qNNddlUK+B/YlooNoymwgA",
    "RegionCode": "h63QSdBCiT/z0WU6rdQv6Q",
    "RegionInfo": "yK+xavymRGZ3xWc1tb8XDg",
    "RegulatoryModelNumber": "97JDvERpVwO+GHtthIh7hA",
}
HISTORICAL_SLOTS = {"green-tea": 0x17E, "not-green-tea": 0x1F9, "wapi": 0x2B5}


def candidate(data):
    if not isinstance(data, bytes) or not data or len(data) % 9:
        return None
    count = len(data) // 9
    return struct.unpack("<" + "Q" * count, data[:count * 8]), data[count * 8:]


def summarize(raw):
    plist = plistlib.loads(raw)
    if not isinstance(plist, dict):
        raise ValueError("Top-level plist must be a dictionary")
    result = {
        "format": "binary" if raw.startswith(b"bplist00") else "XML",
        "file_length": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
        "top_schema": {key: type(value).__name__ for key, value in plist.items()},
    }
    identifier = plist.get("CacheUUID")
    try:
        result["cache_uuid"] = str(uuid.UUID(identifier)).upper() if isinstance(identifier, str) else None
    except ValueError:
        result["cache_uuid"] = None
    version = plist.get("CacheVersion")
    result["cache_version"] = version if isinstance(version, str) and version.isalnum() else None
    extra = plist.get("CacheExtra")
    if isinstance(extra, dict):
        result["extra_count"] = len(extra)
        result["extra_type_counts"] = dict(Counter(type(v).__name__ for v in extra.values()))
        result["identity_region"] = {
            name: {"type": type(extra.get(key)).__name__,
                   "value": extra.get(key) if isinstance(extra.get(key), str) else None}
            for name, key in SAFE_KEYS.items()
        }
    data = plist.get("CacheData")
    result["cache_data_length"] = len(data) if isinstance(data, bytes) else None
    layout = candidate(data)
    if layout is not None:
        values, flags = layout
        count = len(values)
        result["structural_candidate"] = {
            "slot_count": count, "validity_offset": count * 8,
            "validity_counts": dict(Counter(flags)),
            "canonical_validity": all(f <= 1 for f in flags),
            "nonzero_invalid_slots": sum(v != 0 and f == 0 for v, f in zip(values, flags)),
            "historical_slots_not_mappings": {
                name: {"slot": slot, "in_bounds": slot < count,
                       "value": values[slot] if slot < count else None,
                       "valid": flags[slot] if slot < count else None,
                       "validity_offset": count * 8 + slot if slot < count else None}
                for name, slot in HISTORICAL_SLOTS.items()
            },
        }
    return result


def compare(left, right):
    a, b = (plistlib.loads(raw) for raw in (left, right))
    if not isinstance(a, dict) or not isinstance(b, dict):
        raise ValueError("Top-level plist must be a dictionary")
    result = {"same_uuid": a.get("CacheUUID") is not None and a.get("CacheUUID") == b.get("CacheUUID"),
              "same_version": a.get("CacheVersion") is not None and a.get("CacheVersion") == b.get("CacheVersion")}
    ea, eb = a.get("CacheExtra"), b.get("CacheExtra")
    if isinstance(ea, dict) and isinstance(eb, dict):
        common = ea.keys() & eb.keys()
        result["extra"] = {"common": len(common), "only_left": len(ea.keys() - eb.keys()),
                           "only_right": len(eb.keys() - ea.keys()),
                           "type_differences": sum(type(ea[k]) is not type(eb[k]) for k in common),
                           "value_differences": sum(ea[k] != eb[k] for k in common)}
    da, db = a.get("CacheData"), b.get("CacheData")
    ca, cb = candidate(da), candidate(db)
    if ca is not None and cb is not None and len(da) == len(db):
        va, fa = ca
        vb, fb = cb
        vd = {i for i in range(len(va)) if va[i] != vb[i]}
        fd = {i for i in range(len(fa)) if fa[i] != fb[i]}
        result["candidate_diff"] = {
            "bytes": sum(x != y for x, y in zip(da, db)),
            "value_slots": len(vd), "validity_slots": len(fd), "union_slots": len(vd | fd),
            "value_differences_both_valid": sum(fa[i] == fb[i] == 1 for i in vd),
            "validity_transitions": dict(Counter(f"{fa[i]}->{fb[i]}" for i in fd)),
            "value_diff_buckets": {f"0x{base:03X}-0x{min(base + 127, len(va) - 1):03X}":
                                   sum(base <= i < base + 128 for i in vd)
                                   for base in range(0, len(va), 128)},
        }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    if not 1 <= len(args.paths) <= 2:
        parser.error("Provide one or two plist paths")
    raw = [path.read_bytes() for path in args.paths]
    output = {"samples": [summarize(data) for data in raw]}
    if len(raw) == 2:
        output["comparison"] = compare(*raw)
    print(json.dumps(output, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
