// SPDX-License-Identifier: GPL-3.0-only
// Synthetic data exercises the actual pure mutation/layout implementation.
// It does not validate any Apple binary or access a device.
import Foundation

func refuses(_ body: () throws -> Void) {
    do { try body(); fatalError("Expected rejection") } catch {}
}

let layout = JapanRegionCacheLayout(size: 0x1947, slotCount: 0x2CF, fields: [
    .init(question: "green-tea", slot: 0x17E, value: false),
    .init(question: "not-green-tea", slot: 0x1F9, value: true),
    .init(question: "wapi", slot: 0x2B5, value: false)
])
var original = Data(repeating: 0, count: 0x1947)
original[42] = 0x8A // an unrelated non-boolean slot must survive
original[0x0BF0] = 1
original[0x0FC8] = 0
original[0x15A8] = 1
for offset in [0x17F6, 0x1871, 0x192D] { original[offset] = 1 }
try layout.validate(original)
let changed = try layout.applying(to: original)
assert(layout.isApplied(to: changed))
assert(changed.count == original.count && changed[42] == 0x8A)
let expectedChanges: Set<Int> = [0x0BF0, 0x0FC8, 0x15A8]
assert(Set(original.indices.filter { original[$0] != changed[$0] }) == expectedChanges)
let repeated = try layout.applying(to: changed)
assert(repeated == changed)
for size in [0, 0x1946, 0x1948] {
    refuses { try layout.validate(Data(repeating: 0, count: size)) }
}
for offset in [0x0BF0, 0x0BF1, 0x0FC8, 0x0FCF, 0x15A8, 0x17F6, 0x1871, 0x192D, 0x1946] {
    var corrupted = original; corrupted[offset] = 2
    refuses { try layout.validate(corrupted) }
    assert(!layout.isApplied(to: corrupted))
}
let impossible = JapanRegionCacheLayout(size: 0x1947, slotCount: Int.max, fields: layout.fields)
refuses { try impossible.validate(original) }
let duplicate = JapanRegionCacheLayout(size: layout.size, slotCount: layout.slotCount,
                                      fields: [layout.fields[0], layout.fields[0]])
refuses { try duplicate.validate(original) }

// Size alone cannot select a layout.
var current = Data(repeating: 0, count: 6480)
current[0x2B5 * 8] = 100
let currentPlist: [String: Any] = [
    "CacheUUID": "00000000-0000-4000-8000-000000000001",
    "CacheVersion": "24B119", "CacheData": current, "CacheExtra": [:] as [String: Any]
]
refuses { _ = try JapanRegionCacheLayout.resolve(plist: currentPlist, build: "24B119") }

let profile = JapanRegionProfile.verified(for: "iPhone17,3")!
assert(profile.regulatoryModel == "A3286")
assert(JapanRegionProfile.verified(for: "iPhone999,1")?.productType == nil)
assert(JapanRegionProfile.verified(for: "iPad17,4")?.regulatoryModel == "A3361")
let extra: [String: Any] = [
    JapanRegionMutation.regionCodeKey: "CH",
    JapanRegionMutation.regionInfoKey: "CH/A",
    JapanRegionMutation.regulatoryModelKey: "A9999",
    "h9jDsbgj7xIVeIQ8S3/X3Q": "real hardware must survive"
]
for build in ["24A5390f", "24A446", "24C5037i", "future-build", ""] {
    // Matching size and canonical boolean bytes alone never enable mutation,
    // including on the formerly allowlisted build.
    let plist: [String: Any] = ["CacheExtra": extra, "CacheData": original,
                              "CacheUUID": "00000000-0000-4000-8000-000000000001",
                              "CacheVersion": build]
    refuses { try JapanRegionMutation.validate(plist: plist, profile: profile, build: build) }
    refuses { _ = try JapanRegionMutation.applying(to: plist, profile: profile, build: build) }
    assert(!JapanRegionMutation.isApplied(to: plist, profile: profile, build: build))
}
refuses { try JapanRegionMutation.validate(plist: [:], profile: profile, build: "future") }
print("PASS: actual layout bounds/write set/corruption checks, unknown-build rejection and profiles")
