// SPDX-License-Identifier: GPL-3.0-only
import Foundation

typealias Collector = MobileGestaltEvidenceCollector
struct Fixture {
    var device: [String: Any] = ["productType": "iPhone18,3", "systemVersion": "27.2", "build": "24B119", "pid": 8675309]
    var strings = Data(), constants = Data(repeating: 0, count: Collector.tableOffset + Collector.tableCount * 64)
    var cache = Data(repeating: 0, count: 6480)
    var image: [String: Any] = ["binaryUUID": Collector.binaryUUID, "cpuType": 0x0100000C, "cpuSubtype": 2,
        "source": "current process loaded image", "pointerRepresentation": "dyld-resolved key addresses",
        "path": "/usr/lib/libMobileGestalt.dylib", "slide": 123456789]
    var plist: [String: Any] = ["CacheUUID": Collector.cacheUUID, "CacheVersion": "24B119",
        "CacheExtra": ["unrelated": "PRIVATE-CACHE-EXTRA"]]
    var stable = true, error = 0
    var firstOverride: Data?, secondOverride: Data?
    var sectionsOverride: [[String: Any]]?
    var metadataSnapshot = "after"
    var metadataChanges: [String: Any] = [:]
    init() {
        for target in Collector.targets {
            let pointer = UInt64(0x1000000 + strings.count)
            strings.append(contentsOf: target.hash.utf8); strings.append(0)
            set(target.offset, pointer, 8)
            set(target.offset + 0x3A, UInt64(target.slot), 2)
            set(target.offset + 0x3C, 11, 4)
            constants[target.offset + 0x38] = target.flags
            cache[target.slot * 8] = 1 // Includes wapi=true; never compare to mutation target.
        }
        for i in 5760..<6480 { cache[i] = 1 }
    }
    mutating func set(_ offset: Int, _ value: UInt64, _ width: Int) {
        for i in 0..<width { constants[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    func report() -> [String: Any] {
        var p = plist; p["CacheData"] = cache
        let raw = try! PropertyListSerialization.data(fromPropertyList: p, format: .binary, options: 0)
        let metadata: [String: Any] = ["device": 1, "inode": 2, "size": raw.count, "mode": 0o100600,
            "uid": 501, "gid": 20, "links": 1, "mtimeSeconds": 1, "mtimeNanoseconds": 2,
            "ctimeSeconds": 3, "ctimeNanoseconds": 4]
        var observedImage = image
        observedImage["sections"] = sectionsOverride ?? [
            ["name": "__TEXT.__cstring", "address": 0x1000000, "data": strings],
            ["name": Collector.descriptorSection, "address": 0x2000000, "data": constants]]
        var file: [String: Any] = ["first": firstOverride ?? raw, "second": secondOverride ?? firstOverride ?? raw,
            "stable": stable, "errno": error, "stage": "synthetic-double-read",
            "before": metadata, "between": metadata, "after": metadata, "namedAfter": metadata]
        file[metadataSnapshot] = metadata.merging(metadataChanges) { _, changed in changed }
        return Collector.assemble(device: device, image: observedImage, file: file,
            started: Date(timeIntervalSince1970: 1000.123), ended: Date(timeIntervalSince1970: 1000.456))
    }
}
func status(_ report: [String: Any], _ id: String) -> String {
    (report["checks"] as! [[String: Any]]).first { $0["id"] as? String == id }!["status"] as! String
}
func binding(_ report: [String: Any]) -> String { (report["assessment"] as! [String: Any])["runtimeBinding"] as! String }
func diagnose(_ report: [String: Any], _ label: String) {
    let cache = report["cacheInstance"] as! [String: Any]
    var lines = ["Runtime evidence diagnostic: \(label); binding=\(binding(report)); metadataEqual=\(cache["metadataEqual"] ?? "missing"); stable=\(cache["stableAcrossObservedReads"] ?? "missing"); errno=\(cache["errno"] ?? "missing")"]
    for check in report["checks"] as! [[String: Any]] where check["status"] as? String != "PASS" {
        lines.append("  \(check["id"] ?? "missing"): \(check["status"] ?? "missing") — \(check["detail"] ?? "missing")")
    }
    // stderr is flushed by the write before assertion aborts; fixture data only.
    FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
}
let good = Fixture().report()
if binding(good) != "PASS" { diagnose(good, "normal fixture") }
assert(binding(good) == "PASS")
assert((good["assessment"] as! [String: Any])["safeMutationAuthorization"] as? String == "NO-GO")
assert((good["assessment"] as! [String: Any])["callbackPACAuthentication"] as? String == "Not Verified")
assert((good["collectedAt"] as! String).contains(".123"))
var cases = 0
func rejects(_ id: String, expected: String = "FAIL", _ mutate: (inout Fixture) -> Void) {
    var f = Fixture(); mutate(&f)
    let report = f.report()
    if status(report, id) != expected || binding(report) == "PASS" { diagnose(report, id) }
    assert(status(report, id) == expected, "\(id): \(status(report, id)) != \(expected)")
    assert(binding(report) != "PASS", id)
    assert((report["assessment"] as! [String: Any])["safeMutationAuthorization"] as? String == "NO-GO")
    cases += 1
}
// Preserve all eleven stat fields and compare their full NSNumber values.
let metadataKeys = ["device", "inode", "size", "mode", "uid", "gid", "links", "mtimeSeconds", "mtimeNanoseconds", "ctimeSeconds", "ctimeNanoseconds"]
assert(Collector.metadataKeys == metadataKeys)
let swiftMetadata: [String: Any] = Dictionary(uniqueKeysWithValues: metadataKeys.map { ($0, 1 as Any) })
let boxedMetadata: [String: Any] = Dictionary(uniqueKeysWithValues: metadataKeys.map { ($0, NSNumber(value: UInt64(1)) as Any) })
assert(Collector.equalFileMetadata(swiftMetadata, swiftMetadata))
assert(Collector.equalFileMetadata(swiftMetadata, boxedMetadata))
assert(Collector.equalFileMetadata(boxedMetadata, swiftMetadata))
for snapshot in ["before", "between", "after", "namedAfter"] {
    for field in metadataKeys {
        rejects("cache.stableFile") {
            $0.metadataSnapshot = snapshot
            $0.metadataChanges = [field: NSNumber(value: UInt64.max)]
        }
    }
}
rejects("cache.stableFile", expected: "INCOMPLETE") { $0.metadataChanges = ["inode": NSNull()] }
rejects("cache.stableFile", expected: "INCOMPLETE") { $0.metadataChanges = ["mtimeNanoseconds": "invalid"] }
rejects("cache.stableFile") { $0.metadataChanges = ["futureNumericField": 1] }
var extended = swiftMetadata; extended["futureNumericField"] = NSNumber(value: UInt64.max)
assert(Collector.equalFileMetadata(extended, extended))
var changed = extended; changed["futureNumericField"] = NSNumber(value: UInt64.max - 1)
assert(!Collector.equalFileMetadata(extended, changed))
assert(!Collector.equalFileMetadata(extended, swiftMetadata))
var missing = swiftMetadata; missing.removeValue(forKey: "inode")
assert(!Collector.equalFileMetadata(missing, missing))
rejects("image.uuid") { $0.image["binaryUUID"] = UUID().uuidString }
rejects("device.productType") { $0.device["productType"] = "iPhone17,1" }
rejects("device.systemVersion") { $0.device["systemVersion"] = "27.1" }
rejects("device.build") { $0.device["build"] = "24B120" }
rejects("image.architecture") { $0.image["cpuSubtype"] = 0 }
rejects("device.productType", expected: "INCOMPLETE") { $0.device.removeValue(forKey: "productType") }
rejects("image.uuid", expected: "INCOMPLETE") { $0.image = ["error": "not loaded"] }
rejects("descriptors.sections", expected: "INCOMPLETE") { $0.sectionsOverride = [] }
rejects("descriptors.sections") { f in
    f.sectionsOverride = [["name": "__TEXT.__cstring", "address": 0x1000000, "data": f.strings],
        ["name": "__TEXT.__cstring", "address": 0x3000000, "data": f.strings]]
}
rejects("descriptors.sections") { f in
    f.sectionsOverride = [["name": "__TEXT.__cstring", "address": NSNumber(value: UInt64.max - 1), "data": f.strings]]
}
rejects("descriptors.green-tea.read", expected: "INCOMPLETE") { $0.constants = Data(repeating: 0, count: 64) }
rejects("descriptors.green-tea.pointer", expected: "INCOMPLETE") { $0.set(0xDCB0, 0xABCD000001000000, 8) }
rejects("descriptors.green-tea.pointer") { $0.set(0xDCB0, 0x1000000 + 23, 8) }
rejects("descriptors.green-tea.uniqueHash") { $0.strings.append(contentsOf: (Collector.targets[0].hash + "\0").utf8) }
rejects("descriptors.green-tea.uniqueDescriptor") { f in
    let duplicate = f.constants[0xDCB0..<(0xDCB0 + 64)]
    f.constants.replaceSubrange(Collector.tableOffset..<(Collector.tableOffset + 64), with: duplicate)
}
rejects("descriptors.green-tea.fields") { $0.set(0xDCB0 + 0x3A, 382, 2) }
rejects("descriptors.green-tea.fields") { $0.set(0xDCB0 + 0x3A, 720, 2) }
rejects("descriptors.green-tea.fields") { $0.set(0xDCB0 + 0x3A, 0xFFFF, 2) }
rejects("descriptors.green-tea.fields") { $0.set(0xDCB0 + 0x3C, 1, 4) }
rejects("descriptors.green-tea.fields") { $0.constants[0xDCB0 + 0x38] = 0x18 }
rejects("descriptors.green-tea.slotOwnership") { $0.set(0x71F0 + 0x3A, 383, 2) }
rejects("cache.uuid") { $0.plist["CacheUUID"] = UUID().uuidString }
rejects("cache.version") { $0.plist["CacheVersion"] = "24B120" }
rejects("cache.layout") { $0.cache.removeLast() }
rejects("cache.green-tea.boolean") { $0.cache[0xBF8] = 2 }
rejects("cache.green-tea.boolean") { $0.cache[0xBF9] = 1 }
rejects("cache.validityBytes") { $0.cache[5760] = 2 }
rejects("cache.green-tea.valid", expected: "INCOMPLETE") { $0.cache[0x17FF] = 0 }
rejects("cache.green-tea.noOverride") { $0.plist["CacheExtra"] = [Collector.targets[0].hash: false] }
rejects("cache.green-tea.noOverride") { $0.plist["CacheExtra"] = ["green-tea": true] }
rejects("cache.extraType") { $0.plist["CacheExtra"] = "wrong-type" }
rejects("cache.stableFile") { $0.secondOverride = Data([0, 1]); $0.stable = false; $0.error = Int(POSIXErrorCode.EBUSY.rawValue) }
rejects("cache.stableFile", expected: "INCOMPLETE") { $0.stable = false; $0.error = Int(POSIXErrorCode.EACCES.rawValue) }
rejects("cache.plist") { $0.firstOverride = Data("not a plist".utf8) }
var f = Fixture(); for target in Collector.targets { f.cache[target.slot * 8] = 0 }
let allFalse = f.report()
if binding(allFalse) != "PASS" { diagnose(allFalse, "all-false fixture") }
assert(binding(allFalse) == "PASS") // Values need not match a target or past device observation.
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("LocusEvidenceTest-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temp) }
let url = try Collector.export(good, directory: temp)
let json = try Data(contentsOf: url)
let decodedJSON = try JSONSerialization.jsonObject(with: json)
assert(JSONSerialization.isValidJSONObject(decodedJSON))
let text = String(decoding: json, as: UTF8.self)
for sensitive in ["PRIVATE-CACHE-EXTRA", "8675309", "123456789", "16777216", "33554432"] { assert(!text.contains(sensitive)) }
do {
    _ = try Collector.export(["invalid": Double.nan], directory: temp)
    assertionFailure("Serialization failure was swallowed")
} catch {}
do {
    _ = try Collector.export(good, directory: temp) { _, _ in throw NSError(domain: "SyntheticWriter", code: 1) }
    assertionFailure("Write failure was swallowed")
} catch { assert((error as NSError).domain == "SyntheticWriter") }
let remaining = try FileManager.default.contentsOfDirectory(atPath: temp.path)
assert(remaining.count == 1) // Failed export directory cleaned.
print("PASS: actual evidence assembly, \(cases) mismatch/unavailable paths, redaction, JSON export and injected serialization/write failures; synthetic observations only")
