// SPDX-License-Identifier: GPL-3.0-only
// Synthetic data exercises the actual pure mutation/layout implementation.
// It does not register a production fingerprint or validate any Apple binary.
import Foundation

func refuses(_ body: () throws -> Void) {
    do { try body(); fatalError("Expected rejection") } catch {}
}

let layout = JapanRegionCacheLayout.known1947
var original = Data(repeating: 0, count: 0x1947)
original[42] = 0x8A // an unrelated non-boolean slot must survive
original[0x0BF0] = 1
original[0x0FC8] = 0
original[0x15A8] = 1
try layout.validate(original)
let changed = try layout.applying(to: original)
assert(layout.isApplied(to: changed))
assert(changed.count == original.count && changed[42] == 0x8A)
let expectedChanges: Set<Int> = [0x0BF0, 0x0FC8, 0x15A8, 0x17F6, 0x1871, 0x192D]
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

// Synthetic 720-slot structural candidate. It is never a reviewed schema.
var current = Data(repeating: 0, count: 6480)
current[0x2B5 * 8] = 100
let currentPlist: [String: Any] = [
    "CacheUUID": "00000000-0000-4000-8000-000000000001",
    "CacheVersion": "24B119", "CacheData": current, "CacheExtra": [:] as [String: Any]
]
let observation = JapanRegionCacheLayout.diagnostics(plist: currentPlist, build: "24B119")
assert(observation["cacheUUIDType"] as? String == "String")
assert(observation["cacheUUIDValid"] as? Bool == true)
assert(observation["cacheVersionMatchesBuild"] as? Bool == true)
assert(observation["candidateSlotCount"] as? Int == 720)
assert(observation["candidateValidityOffset"] as? Int == 5760)
assert(observation["candidateValidityCanonical"] as? Bool == true)
assert(observation["layoutSupported"] as? Bool == false)
refuses { _ = try JapanRegionCacheLayout.resolve(plist: currentPlist, build: "24B119") }
current[5760] = 2
let invalidFlags = JapanRegionCacheLayout.diagnostics(plist: ["CacheData": current], build: "24B119")
assert(invalidFlags["candidateValidityCanonical"] as? Bool == false)
for wrong in [Data(), Data(repeating: 0, count: 8)] {
    let info = JapanRegionCacheLayout.diagnostics(plist: ["CacheData": wrong], build: "")
    assert(info["candidateSlotCount"] == nil && info["layoutSupported"] as? Bool == false)
}
let wrongTypes = JapanRegionCacheLayout.diagnostics(
    plist: ["CacheUUID": Data(repeating: 1, count: 16), "CacheVersion": 24, "CacheData": "text"], build: "24B119")
assert(wrongTypes["cacheUUIDType"] as? String == "Data")
assert(wrongTypes["cacheUUIDValid"] as? Bool == false)
assert(wrongTypes["cacheVersionMatchesBuild"] as? Bool == false)

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
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let backups = RegionTransactionBackup(directory: directory)
let raw = Data([0, 0xFF, 3, 0, 27, 10])
try backups.saveMobileGestalt(raw)
try backups.saveMobileActivation(raw.reversedData)
let restoredGestalt = try Data(contentsOf: directory.appendingPathComponent("MobileGestalt.plist"))
assert(restoredGestalt == raw)
let restoredActivation = try Data(contentsOf: directory.appendingPathComponent("MobileActivation-region_info.plist"))
assert(restoredActivation == raw.reversedData)
print("PASS: actual layout bounds/write set/corruption checks, unknown-build rejection, profiles and exact backup files")

extension Data {
    var reversedData: Data { Data(reversed()) }
}
