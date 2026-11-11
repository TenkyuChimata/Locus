// SPDX-License-Identifier: GPL-3.0-only
// Synthetic loaded ARM64 images only. These tests never connect to a device.
import Foundation
var checks = 0
func expect(_ value: Bool, _ message: String = "") { checks += 1; precondition(value, message) }
func rejects(_ body: () throws -> Void) { do { try body(); fatalError("Expected rejection") } catch { checks += 1 } }
func encode(_ root: [String: Any]) -> Data { try! PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
func snapshot(_ name: String = "base") throws -> [String: Any] {
    try RegionPlist.parse(Data(contentsOf: directory.appendingPathComponent(name + ".plist"))).root
}
func edit(_ image: [String: Any], section: String, offset: Int, bytes: [UInt8], pointers: Bool = false) -> [String: Any] {
    var result = image, sections = image["sections"] as! [[String: Any]]
    let i = sections.firstIndex(where: { $0["name"] as? String == section })!
    let key = pointers ? "pointers" : "data"
    var data = sections[i][key] as! Data
    data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    sections[i][key] = data; result["sections"] = sections; return result
}
func resolve(_ image: [String: Any]) throws -> RegionLayoutResolution { .resolved(try MobileGestaltRuntimeLayout.scan(image)) }
let base = try snapshot()
let resolved = try resolve(base)
let dynamic = try MobileGestaltRuntimeLayout.scan(base)
let binding = try dynamic.binding(for: RegionCacheQuestion.allCases)
expect(binding.descriptors.map(\.slot) == [2,7,13])
expect(binding.descriptors.map(\.type) == [11,11,11])
expect(binding.descriptors.map(\.flags) == [25,25,28])
expect(binding.cacheUUID != binding.imageUUID, "Mach-O UUID is independent of CacheUUID")
for name in ["other", "negative"] {
    let image = try MobileGestaltRuntimeLayout.scan(snapshot(name))
    expect(try image.binding(for: [.wapi]).descriptors.first?.slot == 13)
    expect(image.slotCount == (name == "other" ? 32 : 16))
}
let build = "25D123", product = "iPad16,3-A"
let code = JapanRegionMutation.regionCodeKey, info = RegionModuleMutation.regionInfoKeys[0], model = JapanRegionMutation.regulatoryModelKey
var data = Data(repeating: 0, count: 16 * 9)
data[16] = 1; data[104] = 1
for slot in [2,7,13] { data[128 + slot] = 1 }
data[32] = 95
let plist: [String: Any] = ["CacheExtra": [code: "CH", info: "CH/A", model: "A3006", "untouched": true],
                          "CacheVersion": build, "CacheUUID": binding.cacheUUID, "CacheData": data]
let raw = encode(plist)
func plan(_ module: RegionModule, _ bytes: Data = raw, _ runtime: RegionLayoutResolution = resolved) throws -> RegionWritePlan {
    try RegionModuleMutation.plan(module: module, raw: bytes, productType: product, build: build, runtime: runtime)
}
let full = try plan(.fullJapan)
expect(full.scope.layoutBinding == binding)
expect(full.scope.byteOffsets == [16,56,104])
expect(full.comparison.contains(where: { $0.hasPrefix("wapi:") }))
let after = try RegionPlist.parse(full.after).root["CacheData"] as! Data
expect(data.indices.allSatisfy { [16,56,104].contains($0) || data[$0] == after[$0] })
expect(after[128..<144] == data[128..<144], "Validity never changes")
expect(try plan(.fullJapan, full.after).after == full.after)
expect(try full.scope.restoring(original: raw, applied: full.after, current: full.after) == raw)

// Each malformed descriptor disables its own module, preserving independent fields.
for (offset, bytes) in [(58, [UInt8(255),255]), (58, [16,0]), (60, [5,0,0,0]), (56, [24]), (57, [1])] {
    let malformed = try resolve(edit(base, section: "__const", offset: 0x30 + 128 + offset, bytes: bytes))
    rejects { _ = try plan(.wapi, raw, malformed) }
    rejects { _ = try plan(.fullJapan, raw, malformed) }
    _ = try plan(.greenTea, raw, malformed); _ = try plan(.notGreenTea, raw, malformed)
    _ = try plan(.regionCode, raw, malformed); checks += 3
}
let absentImage = edit(edit(base, section: "__const", offset: 0x30 + 128, bytes: [UInt8](repeating: 0, count: 64)),
                       section: "__const", offset: 0x30 + 128, bytes: [UInt8](repeating: 0, count: 64), pointers: true)
let absent = try resolve(absentImage)
rejects { _ = try plan(.wapi, raw, absent) }; rejects { _ = try plan(.fullJapan, raw, absent) }
_ = try plan(.greenTea, raw, absent); checks += 1
let duplicate = edit(edit(base, section: "__const", offset: 0x30 + 6 * 64,
    bytes: Array((base["sections"] as! [[String: Any]])[2]["data"] as! Data)[0x30..<(0x30 + 64)].map { $0 }),
    section: "__const", offset: 0x30 + 6 * 64,
    bytes: Array((base["sections"] as! [[String: Any]])[2]["pointers"] as! Data)[0x30..<(0x30 + 64)].map { $0 }, pointers: true)
let dup = try resolve(duplicate)
rejects { _ = try plan(.greenTea, raw, dup) }; _ = try plan(.wapi, raw, dup); checks += 1
let collision = try resolve(edit(base, section: "__const", offset: 0x30 + 128 + 58, bytes: [2,0]))
rejects { _ = try plan(.greenTea, raw, collision) }; rejects { _ = try plan(.wapi, raw, collision) }
_ = try plan(.notGreenTea, raw, collision); checks += 1

// UUID string alone, a slot table alone, or matching CacheData size never suffice.
for (section, offset, bytes) in [("__text",0x17C,[UInt8(0),0,0,0]), ("__text",0x88,[0,0,0,0]),
    ("__text",0x618,[0,0,0,0]), ("__text",0x428,[0,0,0,0]), ("__text",0x60C,[0,0,0,0]),
    ("__text",0xB0,[0,0,0,0])] {
    rejects { _ = try resolve(edit(base, section: section, offset: offset, bytes: bytes)) }
}
var bad = base; bad["header"] = Data([0,1,2]); rejects { _ = try resolve(bad) }
bad = base; var header = bad["header"] as! Data; header[0] = 0; bad["header"] = header; rejects { _ = try resolve(bad) }
bad = base; bad["slide"] = 4096; rejects { _ = try resolve(bad) }
bad = base; bad["writerAddress"] = UInt64.max; rejects { _ = try resolve(bad) }
bad = base; var entries = bad["sections"] as! [[String: Any]]; entries.append(entries[0]); bad["sections"] = entries; rejects { _ = try resolve(bad) }
bad = base; entries = bad["sections"] as! [[String: Any]]; entries[2]["data"] = Data([0]); bad["sections"] = entries; rejects { _ = try resolve(bad) }
// Overflow-sized CFString metadata is rejected before integer conversion.
rejects { _ = try resolve(edit(base, section: "__cfstring", offset: 24, bytes: [UInt8](repeating: 255, count: 8))) }
rejects { _ = try resolve(edit(base, section: "__text", offset: 0x800, bytes: [8,0,128,82])) } // zero records
bad = base; header = bad["header"] as! Data
for i in 40..<56 { header[i] = 0 }; bad["header"] = header; rejects { _ = try resolve(bad) }
bad = base; header = bad["header"] as! Data; header[36] = 16; bad["header"] = header; rejects { _ = try resolve(bad) }
bad = base; header = bad["header"] as! Data; header[16] = 4; bad["header"] = header; rejects { _ = try resolve(bad) }
rejects { _ = try resolve(edit(base, section: "__cstring", offset: 44, bytes: [88])) } // invalid UUID
// PAC bits left unresolved, or an offline chained-fixup word, must not pass.
rejects { _ = try resolve(edit(base, section: "__const", offset: 0x30 + 7, bytes: [0xAB], pointers: true)) }
rejects { _ = try resolve(edit(base, section: "__cfstring", offset: 16, bytes: [1,2,3,4,0,0,0,0], pointers: true)) }
for (key, value) in [("CacheUUID", UUID().uuidString), ("CacheVersion", "stale")] {
    var stale = plist; stale[key] = value; rejects { _ = try plan(.greenTea, encode(stale)) }
}
for offset in [16,17,130] {
    var badData = data; badData[offset] = 2; var badPlist = plist; badPlist["CacheData"] = badData
    rejects { _ = try plan(.greenTea, encode(badPlist)) }
}
var override = plist; override["CacheExtra"] = [code: "CH", "wapi": false]
rejects { _ = try plan(.wapi, encode(override)) }; _ = try plan(.greenTea, encode(override)); checks += 1
for product in ["unknown", "iPhone18,1", "iPad99,9"] {
    for version in ["23A123", "24C123", "25D123"] {
        var p = plist; p["CacheVersion"] = version
        _ = try RegionModuleMutation.plan(module: .regionCode, raw: encode(p), productType: product, build: version, runtime: .rejected("unrecognized"))
        _ = try RegionModuleMutation.plan(module: .regionInfo, raw: encode(p), productType: product, build: version, runtime: .rejected("unrecognized"))
        _ = try RegionModuleMutation.plan(module: .greenTea, raw: encode(p), productType: product, build: version, runtime: resolved); checks += 3
    }
}
rejects { _ = try RegionModuleMutation.plan(module: .fullJapan, raw: raw, productType: "unknown", build: build, runtime: resolved) }

// Matching size is not enough; no validated runtime means no new layout.
rejects { _ = try plan(.greenTea, raw, .unavailable("missing image")) }
rejects { _ = try plan(.greenTea, raw, .rejected("unknown descriptor format")) }
var wrongLength = plist; wrongLength["CacheData"] = Data(repeating: 0, count: data.count + 9)
rejects { _ = try plan(.greenTea, encode(wrongLength)) }
var invalidSlot = plist, invalidBytes = data; invalidBytes[130] = 0; invalidSlot["CacheData"] = invalidBytes
rejects { _ = try plan(.greenTea, encode(invalidSlot)) }; _ = try plan(.wapi, encode(invalidSlot)); checks += 1
var wrongDevice = plist, deviceExtra = plist["CacheExtra"] as! [String: Any]
deviceExtra["0+nc/Udy4WNG8S+Q7a/s1A"] = "iPhone99,1"; wrongDevice["CacheExtra"] = deviceExtra
rejects { _ = try plan(.regionCode, encode(wrongDevice)) }
for key in ["CacheUUID", "CacheVersion", "other"] {
    var unrelated = try RegionPlist.parse(full.after).root; unrelated[key] = "modified"
    rejects { try full.scope.validate(before: raw, after: encode(unrelated)) }
}
var validityChanged = try RegionPlist.parse(full.after).root, changedData = after
changedData[128] = 1; validityChanged["CacheData"] = changedData
rejects { try full.scope.validate(before: raw, after: encode(validityChanged)) }
for (identifier, target) in [("iPhone14,6", "A2782"), ("iPhone15,4", "A3089"), ("iPhone19,2", "A3713"),
                              ("iPad13,5", "A2377"), ("iPad13,6", "A2459"), ("iPad15,7", "A3354"), ("iPad15,8", "A3355")] {
    expect(JapanRegionProfile.verified(for: identifier)?.regulatoryModel == target)
}
expect(JapanRegionProfile.verified(for: product)?.productType == product)
expect(JapanRegionProfile.verified(for: "iPhone19,7")?.productType == nil)
// Original static profile must not conceal a conflicting parsed result.
var old = plist; old["CacheVersion"] = "24B119"; old["CacheUUID"] = RegionCacheMapping.cacheUUID
old["CacheData"] = Data(repeating: 0, count: 6480)
rejects { _ = try RegionModuleMutation.plan(module: .greenTea, raw: encode(old), productType: "iPhone18,3", build: "24B119", runtime: resolved) }

let originalImage = try snapshot("original")
let originalRuntime = try resolve(originalImage)
var originalData = Data(repeating: 0, count: 6480)
for slot in [383,506,694] { originalData[5760 + slot] = 1 }
old["CacheData"] = originalData
let originalFull = try RegionModuleMutation.plan(module: .fullJapan, raw: encode(old), productType: "iPhone18,3", build: "24B119", runtime: originalRuntime)
expect(originalFull.scope.byteOffsets == [3064,4048,5552])
expect(originalFull.scope.layoutBinding != nil)
let originalConflict = try resolve(edit(originalImage, section: "__const", offset: 0x30 + 128 + 60, bytes: [5,0,0,0]))
// A present-but-invalid wapi descriptor is a conflict with this exact static
// profile; it cannot be silently ignored while authorizing another cache byte.
rejects { _ = try RegionModuleMutation.plan(module: .greenTea, raw: encode(old), productType: "iPhone18,3", build: "24B119", runtime: originalConflict) }

final class Memory: RegionFileAccess {
    var bytes = raw, writes = 0
    func read(_ file: RegionFile) throws -> Data { bytes }
    func replace(_ file: RegionFile, expected: Data, replacement: Data) throws {
        guard bytes == expected else { throw RegionOperationError("CAS mismatch") }
        bytes = replacement; writes += 1
    }
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LocusDynamic-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: temporary) }
// Older legal static journals retain UUID case-insensitive matching.
var lower = old; lower["CacheUUID"] = RegionCacheMapping.cacheUUID.lowercased()
let lowerRaw = encode(lower), lowerIO = Memory(); lowerIO.bytes = lowerRaw
let lowerStore = RegionTransactionCoordinator(root: temporary.appendingPathComponent("lowercase-legacy"), access: lowerIO,
    productType: "iPhone18,3", build: "24B119", layoutProvider: { .unavailable("static fallback") })
let lowerPlan = try RegionModuleMutation.plan(module: .fullJapan, raw: lowerRaw, productType: "iPhone18,3", build: "24B119", runtime: .unavailable("static fallback"))
_ = try lowerStore.apply(module: .fullJapan, plans: [lowerPlan]); _ = try lowerStore.restore(module: .fullJapan)
expect(lowerIO.bytes == lowerRaw && lowerIO.writes == 2)
let io = Memory()
var live = resolved
func store(_ product: String = product, _ build: String = build, _ id: String = "device-A") -> RegionTransactionCoordinator {
    .init(root: temporary, access: io, productType: product, build: build, deviceID: id, layoutProvider: { live })
}
let coordinator = store()
let noDevice = RegionTransactionCoordinator(root: temporary.appendingPathComponent("no-device"), access: io,
    productType: product, build: build, layoutProvider: { resolved })
rejects { _ = try noDevice.prepare(module: .fullJapan, plans: [full]) }
_ = try coordinator.apply(module: .fullJapan, plans: [full])
expect(io.writes == 1)
let pointer = try Data(contentsOf: temporary.appendingPathComponent("originals/fullJapan-v2.plist"))
_ = try coordinator.apply(module: .fullJapan, plans: [plan(.fullJapan, io.bytes)])
expect(io.writes == 1)
expect(try Data(contentsOf: temporary.appendingPathComponent("originals/fullJapan-v2.plist")) == pointer)
let changedIdentity = try resolve({ () -> [String: Any] in
    var image = base, identity = base["header"] as! Data; identity[40] ^= 1; image["header"] = identity; return image
}())
live = changedIdentity
rejects { _ = try coordinator.restore(module: .fullJapan) }
live = absent
rejects { _ = try coordinator.restore(module: .fullJapan) }; expect(io.writes == 1)
live = resolved
for other in [store("iPad16,4"), store(product, "25D124"), store(product, build, "device-B")] {
    rejects { _ = try other.restore(module: .fullJapan) }
}
_ = try coordinator.restore(module: .fullJapan); expect(io.bytes == raw)
let prepared = try coordinator.prepare(module: .fullJapan, plans: [full])!
live = absent
rejects { _ = try coordinator.commitPrepared(prepared.id) }; expect(io.bytes == raw)
live = resolved
try coordinator.cancelPrepared(prepared.id)
// Forging offsets or dropping metadata cannot authorize a dynamic write.
var forged = full.scope; forged.layoutBinding = nil
rejects { _ = try coordinator.apply(module: .fullJapan, plans: [.init(file: .mobileGestalt, before: raw, after: full.after, scope: forged)]) }
forged = full.scope; forged.byteOffsets = [24,56,104]
rejects { _ = try coordinator.apply(module: .fullJapan, plans: [.init(file: .mobileGestalt, before: raw, after: full.after, scope: forged)]) }
let alternate = try resolve(edit(base, section: "__const", offset: 0x30 + 58, bytes: [3,0]))
live = alternate
rejects { _ = try coordinator.restore(module: .fullJapan) }
live = resolved
var external = plist; external["CacheVersion"] = "external"; io.bytes = encode(external)
rejects { _ = try coordinator.apply(module: .fullJapan, plans: [full]) }
expect(io.writes == 2)
print("PASS: \(checks) dynamic descriptor, UUID/consumer binding, ASLR, independent capability and transaction checks (synthetic images only)")
