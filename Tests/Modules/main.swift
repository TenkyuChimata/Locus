// SPDX-License-Identifier: GPL-3.0-only
// Synthetic fixtures only. These reviews never enter the production registry.
import Foundation

var checks = 0
func expect(_ condition: Bool, _ message: String = "") {
    checks += 1
    precondition(condition, message)
}
func rejects(_ body: () throws -> Void) {
    do { try body(); fatalError("Expected rejection") } catch { checks += 1 }
}
func encode(_ root: [String: Any], format: PropertyListSerialization.PropertyListFormat = .binary) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
}
func root(_ bytes: Data) -> [String: Any] { try! RegionPlist.parse(bytes).root }
func extra(_ bytes: Data) -> [String: Any] { root(bytes)["CacheExtra"] as! [String: Any] }
let uuid = "00000000-0000-4000-8000-000000000001"
let binary = "00000000-0000-4000-8000-000000000002"
let build = "fixture-build"
let profile = "iPhone18,3"
let code = JapanRegionMutation.regionCodeKey, info = RegionModuleMutation.regionInfoKeys[0]
let modernInfo = RegionModuleMutation.regionInfoKeys[1], ai = RegionModuleMutation.intelligenceKey
let model = JapanRegionMutation.regulatoryModelKey
var baseline: [String: Any] = ["CacheExtra": [code: "CH", info: "CH/A", model: "A9999", "hardware": "preserve", "number": 512] as [String: Any],
    "CacheUUID": uuid, "CacheVersion": build, "CacheData": Data(repeating: 0, count: 72), "other": [1, 2, 3]]
let baselineBytes = encode(baseline)

for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
    for module in [RegionModule.regionCode, .regionInfo, .regulatoryModel, .intelligence] {
        let original = encode(baseline, format: format)
        let plan = try RegionModuleMutation.plan(module: module, raw: original, productType: profile)
        try plan.scope.validate(before: original, after: plan.after)
        let restored = try plan.scope.restoring(original: original, applied: plan.after, current: plan.after)
        expect(restored == original, "Exact source bytes restored")
        expect(try RegionPlist.parse(plan.after).format == format)
        expect(RegionPlist.equal(root(original)["CacheData"], root(plan.after)["CacheData"]))
        expect(extra(plan.after)["hardware"] as? String == "preserve")
    }
}
for key in [info, modernInfo] {
    var fixture = baseline
    fixture["CacheExtra"] = [code: "CH", key: "CH/A"]
    let plan = try RegionModuleMutation.plan(module: .regionInfo, raw: encode(fixture), productType: "unknown")
    expect(extra(plan.after)[key] as? String == "J/A")
    expect(extra(plan.after)[code] as? String == "CH")
    expect(extra(plan.after)[key == info ? modernInfo : info] == nil)
}
for suffixes in [[:], [info: "CH/A", modernInfo: "CH/A"], [info: "CH/A", modernInfo: "J/A"]] {
    var fixture = baseline; fixture["CacheExtra"] = suffixes
    rejects { _ = try RegionModuleMutation.plan(module: .regionInfo, raw: encode(fixture), productType: profile) }
}
for malformed in [0, true, Data([1])] as [Any] {
    var fixture = baseline; fixture["CacheExtra"] = [code: malformed]
    rejects { _ = try RegionModuleMutation.plan(module: .regionCode, raw: encode(fixture), productType: profile) }
}
expect(JapanRegionProfile.verified(for: profile)?.regulatoryModel == "A3519")
// Inspect an Optional<String> so a nil check does not require the profile's
// actor-isolated Equatable conformance in this top-level test context.
expect(JapanRegionProfile.verified(for: "unknown")?.productType == nil)
rejects { _ = try RegionModuleMutation.plan(module: .regulatoryModel, raw: baselineBytes, productType: "unknown") }
var identityOnly = baseline
identityOnly.removeValue(forKey: "CacheData"); identityOnly.removeValue(forKey: "CacheUUID"); identityOnly.removeValue(forKey: "CacheVersion")
_ = try RegionModuleMutation.plan(module: .regionCode, raw: encode(identityOnly), productType: "unknown")
checks += 1
for originalValue in [nil, NSNumber(value: false), NSNumber(value: true), NSNumber(value: 0), NSNumber(value: 1)] as [Any?] {
    var fixture = baseline, fields = fixture["CacheExtra"] as! [String: Any]
    fields[ai] = originalValue; fixture["CacheExtra"] = fields
    let original = encode(fixture)
    let plan = try RegionModuleMutation.plan(module: .intelligence, raw: original, productType: "unknown")
    expect((extra(plan.after)[ai] as? NSNumber)?.intValue == 1)
    expect(try plan.scope.restoring(original: original, applied: plan.after, current: plan.after) == original)
}
for bad in [NSNumber(value: 2), NSNumber(value: -1), NSNumber(value: 0.5), NSNumber(value: 1.0), "false", Data([0])] as [Any] {
    var fixture = baseline, fields = fixture["CacheExtra"] as! [String: Any]
    fields[ai] = bad; fixture["CacheExtra"] = fields
    rejects { _ = try RegionModuleMutation.plan(module: .intelligence, raw: encode(fixture), productType: profile) }
}

func put(_ value: UInt64, into data: inout Data, at offset: Int, size: Int) {
    for i in 0..<size { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
}
let keys = RegionCacheQuestion.allCases.map(\.key) + ["AAAAAAAAAAAAAAAAAAAAAA"]
var strings = Data(), addresses: [UInt64] = []
for key in keys { addresses.append(0x1000 + UInt64(strings.count)); strings.append(Data((key + "\0").utf8)) }
strings.append(Data((uuid + "\0").utf8))
var descriptors = Data(repeating: 0, count: 256)
let slots = [1, 3, 5, 7]
for i in 0..<4 {
    put(addresses[i] | 0xABCD_0000_0000_0000, into: &descriptors, at: i * 64, size: 8)
    put(UInt64(slots[i]), into: &descriptors, at: i * 64 + 0x3A, size: 2)
    put(i == 3 ? 4 : 11, into: &descriptors, at: i * 64 + 0x3C, size: 4)
}
func image(_ data: Data = descriptors, _ text: Data = strings) -> [String: Any] {
    ["binaryUUID": binary, "sections": [["name": "__TEXT.__cstring", "address": NSNumber(value: 0x1000), "data": text],
        ["name": "__AUTH_CONST.__const", "address": NSNumber(value: 0x8000), "data": data]]]
}
let review = ReviewedCacheSchema(binaryUUID: binary, cacheUUID: uuid, build: build, byteCount: 72,
    descriptors: Dictionary(uniqueKeysWithValues: RegionCacheQuestion.allCases.enumerated().map {
        ($0.element, CacheDescriptor(section: "__AUTH_CONST.__const", offset: $0.offset * 64, slot: slots[$0.offset], type: 11))
    }), evidence: "SYNTHETIC TEST ONLY")
func assess(_ fixture: [String: Any] = baseline, _ snapshot: [String: Any] = image(), reviewed: Bool = false, writable: Bool = true) -> [CacheMappingAssessment] {
    RegionCacheMapping.assess(plist: fixture, build: build, image: snapshot, writeAccess: writable, reviews: reviewed ? [review] : [])
}
expect(assess().allSatisfy { $0.status == .structurallyValid && !$0.permitsMutation })
expect(assess(reviewed: true, writable: false).allSatisfy { $0.status == .binaryVerified })
let authorized = assess(reviewed: true)
expect(authorized.allSatisfy(\.permitsMutation))
expect(RegionCacheMapping.reviewed.isEmpty)
for (key, value) in [("CacheUUID", binary), ("CacheVersion", "stale")] {
    var mismatched = baseline; mismatched[key] = value
    rejects { _ = try RegionModuleMutation.plan(module: .greenTea, raw: encode(mismatched), productType: profile, assessments: authorized) }
}
var rebound = baseline; rebound["CacheData"] = Data(repeating: 0, count: 81)
rejects { _ = try RegionModuleMutation.plan(module: .greenTea, raw: encode(rebound), productType: profile, assessments: authorized) }
rebound = baseline; rebound["CacheExtra"] = [RegionCacheQuestion.greenTea.key: true]
rejects { _ = try RegionModuleMutation.plan(module: .greenTea, raw: encode(rebound), productType: profile, assessments: authorized) }
rejects { _ = try RegionModuleMutation.plan(module: .greenTea, raw: baselineBytes, productType: profile, assessments: authorized + authorized) }
let booleanPlan = try RegionModuleMutation.plan(module: .notGreenTea, raw: baselineBytes, productType: profile, assessments: authorized)
for byte in [3 * 8, 3 * 8 + 1, 64 + 3] {
    var wrong = root(booleanPlan.after), bytes = wrong["CacheData"] as! Data
    bytes[byte] = 2; wrong["CacheData"] = bytes
    rejects { try booleanPlan.scope.validate(before: booleanPlan.before, after: encode(wrong)) }
}
for module in [RegionModule.greenTea, .notGreenTea, .wapi] {
    var fixture = baseline, data = fixture["CacheData"] as! Data
    let index = slots[RegionCacheQuestion.allCases.firstIndex(of: module.question!)!]
    data[index * 8] = 1 // Same green-tea/wapi values do not determine the mapping.
    data[56] = 99 // Unrelated non-Boolean slot.
    fixture["CacheData"] = data
    let raw = encode(fixture)
    let plan = try RegionModuleMutation.plan(module: module, raw: raw, productType: profile, assessments: assess(fixture, reviewed: true))
    expect(plan.scope.byteOffsets.count == 9)
    expect(try plan.scope.restoring(original: raw, applied: plan.after, current: plan.after) == raw)
    expect((root(plan.after)["CacheData"] as! Data)[56] == 99)
    var unrelated = root(plan.after), corrupt = unrelated["CacheData"] as! Data
    corrupt[40] ^= 1; unrelated["CacheData"] = corrupt
    if index != 5 { rejects { try plan.scope.validate(before: raw, after: encode(unrelated)) } }
    rejects { _ = try RegionModuleMutation.plan(module: module, raw: raw, productType: profile, assessments: assess(fixture)) }
}
var changed = baseline; changed["CacheUUID"] = binary
expect(assess(changed, reviewed: true).allSatisfy { !$0.permitsMutation })
changed = baseline; changed["CacheVersion"] = "stale"
expect(assess(changed, reviewed: true).allSatisfy { !$0.permitsMutation })
var wrongImage = image(); wrongImage["binaryUUID"] = uuid
expect(assess(baseline, wrongImage, reviewed: true).allSatisfy { $0.status == .structurallyValid })
for offset in [8, 9, 8 * 8 + 1, 71] {
    changed = baseline; var bytes = changed["CacheData"] as! Data
    bytes[offset] = 2; changed["CacheData"] = bytes
    expect(!assess(changed, reviewed: true)[0].permitsMutation)
}
for size in [0, 8, 71, 73] {
    changed = baseline; changed["CacheData"] = Data(repeating: 0, count: size)
    expect(assess(changed, reviewed: true).allSatisfy { !$0.permitsMutation })
}
for type in [0, 1, 12] {
    var data = descriptors; put(UInt64(type), into: &data, at: 128 + 0x3C, size: 4)
    let results = assess(baseline, image(data))
    expect(results[0].status == .structurallyValid && results[2].status == .candidate)
}
for index in [8, 32767, 65535] {
    var data = descriptors; put(UInt64(index), into: &data, at: 128 + 0x3A, size: 2)
    expect(assess(baseline, image(data), reviewed: true)[2].status == .candidate)
}
var collision = descriptors; put(1, into: &collision, at: 128 + 0x3A, size: 2)
expect(assess(baseline, image(collision))[0].status == .candidate)
expect(assess(baseline, image(collision))[1].status == .structurallyValid)
var duplicate = descriptors; duplicate.append(descriptors.prefix(64))
expect(assess(baseline, image(duplicate))[0].status == .candidate)
expect(assess(baseline, image(descriptors, strings + Data((binary + "\0").utf8))).allSatisfy { $0.status == .candidate })
expect(assess(baseline, image(descriptors, strings + Data((uuid + "\0").utf8))).allSatisfy { $0.status == .candidate })
expect(assess(baseline, image(Data(repeating: 0, count: 63))).allSatisfy { $0.status == .unavailable })
changed = baseline; changed["CacheExtra"] = [RegionCacheQuestion.wapi.key: true]
expect(assess(changed, reviewed: true)[2].status == .candidate)
expect(assess(changed, reviewed: true)[0].permitsMutation)
var overlap = image(); var overlapping = overlap["sections"] as! [[String: Any]]
overlapping[1]["address"] = NSNumber(value: 0x1000); overlap["sections"] = overlapping
expect(assess(baseline, overlap).allSatisfy { $0.status == .unavailable })
var overflow = image(); var overflowing = overflow["sections"] as! [[String: Any]]
overflowing[0]["address"] = NSNumber(value: UInt64.max); overflow["sections"] = overflowing
expect(assess(baseline, overflow).allSatisfy { $0.status == .unavailable })
var withSmallSection = image(), smallSections = withSmallSection["sections"] as! [[String:Any]]
smallSections.append(["name": "__DATA.__const", "address": NSNumber(value: 0x9000), "data": Data(repeating: 0, count: 8)])
withSmallSection["sections"] = smallSections
expect(assess(baseline, withSmallSection).allSatisfy { $0.status == .structurallyValid })

final class MemoryAccess: RegionFileAccess {
    var data: [RegionFile: Data]
    var events: [RegionFile] = []
    var callback: ((RegionFile, Data, Data, MemoryAccess) throws -> Void)?
    var readFault: ((RegionFile, MemoryAccess) throws -> Void)?
    init(_ initial: [RegionFile: Data]) { data = initial }
    func read(_ file: RegionFile) throws -> Data {
        try readFault?(file, self)
        return data[file]!
    }
    func replace(_ file: RegionFile, expected: Data, replacement: Data) throws {
        guard data[file] == expected else { throw RegionOperationError("CAS mismatch") }
        events.append(file)
        if let callback { try callback(file, expected, replacement, self) }
        else { data[file] = replacement }
    }
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LocusModuleTests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
func store(_ access: MemoryAccess, _ name: String) -> RegionTransactionCoordinator {
    .init(root: temporary.appendingPathComponent(name), access: access, productType: profile, build: build)
}
func plan(_ module: RegionModule, _ bytes: Data) throws -> RegionWritePlan {
    try RegionModuleMutation.plan(module: module, raw: bytes, productType: profile)
}
let access = MemoryAccess([.mobileGestalt: baselineBytes])
let coordinator = store(access, "independence")
for module in [RegionModule.regionCode, .regionInfo, .intelligence] {
    _ = try coordinator.apply(module: module, plans: [plan(module, access.data[.mobileGestalt]!)])
}
let originalPointer = coordinator.root.appendingPathComponent("originals/regionCode.plist")
let pointer = try Data(contentsOf: originalPointer)
let writes = access.events.count
_ = try coordinator.apply(module: .regionCode, plans: [plan(.regionCode, access.data[.mobileGestalt]!)])
expect(access.events.count == writes)
expect(try Data(contentsOf: originalPointer) == pointer)
_ = try coordinator.restore(module: .regionCode)
expect(extra(access.data[.mobileGestalt]!)[code] as? String == "CH")
expect(extra(access.data[.mobileGestalt]!)[info] as? String == "J/A")
expect((extra(access.data[.mobileGestalt]!)[ai] as? NSNumber)?.intValue == 1)
_ = try coordinator.restore(module: .intelligence)
expect(extra(access.data[.mobileGestalt]!)[ai] == nil)
_ = try coordinator.restore(module: .regionInfo)
expect(RegionPlist.equal(root(access.data[.mobileGestalt]!), baseline))
_ = try coordinator.apply(module: .regionCode, plans: [plan(.regionCode, access.data[.mobileGestalt]!)])
expect(try Data(contentsOf: originalPointer) == pointer)
expect(try coordinator.pending().isEmpty)

// A currently hand-edited J value is not made into an invented original.
let manual = try plan(.regionCode, baselineBytes).after
let handEdited = MemoryAccess([.mobileGestalt: manual])
let manualStore = store(handEdited, "manual")
_ = try manualStore.apply(module: .regionCode, plans: [plan(.regionCode, manual)])
expect(!(try manualStore.originalAvailable(for: .regionCode)))

let maOriginal = encode(["CountryCode": "CN", "RegionInfo": "CH/A", "SoftwareBehaviors": "321", "other": "keep"])
let maPlan = try RegionModuleMutation.activationPlan(raw: maOriginal)
let mgPlan = try plan(.regionCode, baselineBytes)
// The coordinator only permits complete fixed-whitelist full plans.
var fullOffsets: [Int] = []
for slot in [1, 3, 5] { fullOffsets += Array((slot * 8)..<(slot * 8 + 8)) + [64 + slot] }
let fullScope = RegionPatchScope(extraKeys: [code, info, model], byteOffsets: fullOffsets,
    cacheUUID: uuid, cacheVersion: build, cacheLength: 72)
var fullRoot = baseline
for module in [RegionModule.regionCode, .regionInfo, .regulatoryModel] { fullRoot = root(try plan(module, encode(fullRoot)).after) }
for module in [RegionModule.greenTea, .notGreenTea, .wapi] {
    fullRoot = root(try RegionModuleMutation.plan(module: module, raw: encode(fullRoot), productType: profile,
        assessments: assess(fullRoot, reviewed: true)).after)
}
let fullMG = RegionWritePlan(file: .mobileGestalt, before: baselineBytes, after: encode(fullRoot), scope: fullScope)
let incompleteIO = MemoryAccess([.mobileGestalt: baselineBytes, .mobileActivation: maOriginal])
let incompleteStore = store(incompleteIO, "incomplete-full")
rejects { _ = try incompleteStore.apply(module: .fullJapan, plans: [maPlan]) }
rejects { _ = try incompleteStore.apply(module: .fullJapan, plans: [fullMG]) }
rejects { _ = try incompleteStore.apply(module: .regionCode, plans: [maPlan]) }
expect(incompleteIO.events.isEmpty)
let noContextStore = RegionTransactionCoordinator(root: incompleteStore.root, access: incompleteIO, productType: "", build: "")
rejects { _ = try noContextStore.apply(module: .regionCode, plans: [mgPlan]) }
for fault in 0..<4 {
    let memory = MemoryAccess([.mobileGestalt: baselineBytes, .mobileActivation: maOriginal])
    let transaction = store(memory, "fault\(fault)")
    var injected = false
    memory.callback = { file, _, replacement, io in
        let pending = try transaction.pending().first!
        expect(pending.phase == .writing || injected)
        for entry in pending.entries {
            let directory = transaction.root.appendingPathComponent(pending.id)
            let before = try Data(contentsOf: directory.appendingPathComponent(entry.file.rawValue + ".before.plist"))
            expect(RegionBackupDigest.sha256(before) == entry.beforeSHA256)
        }
        // Both original files and their checksums exist before any write.
        if !injected && fault != 0 && file == (fault == 1 ? .mobileActivation : .mobileGestalt) {
            injected = true
            if fault == 3 { io.data[file] = Data([1,2,3]) } // Unrecognized torn bytes: refuse forced recovery.
            else { io.data[file] = replacement }
            throw RegionOperationError("injected write failure")
        }
        io.data[file] = replacement
    }
    if fault == 0 {
        _ = try transaction.apply(module: .fullJapan, plans: [maPlan, fullMG])
        expect(memory.events == [.mobileActivation, .mobileGestalt])
        expect(try transaction.pending().isEmpty)
        _ = try transaction.restore(module: .fullJapan)
        expect(memory.data[.mobileGestalt] == baselineBytes && memory.data[.mobileActivation] == maOriginal)
    } else {
        rejects { _ = try transaction.apply(module: .fullJapan, plans: [maPlan, fullMG]) }
        expect(memory.data[.mobileActivation] == maOriginal)
        if fault == 3 {
            expect(try transaction.pending().first?.phase == .recoveryRequired)
            rejects { _ = try transaction.apply(module: .regionCode, plans: [mgPlan]) }
            rejects { _ = try store(memory, "fault\(fault)").recoverPending() }
        } else {
            expect(memory.data[.mobileGestalt] == baselineBytes)
            expect(try transaction.pending().isEmpty)
            expect(memory.events == (fault == 1 ? [.mobileActivation,.mobileActivation] : [.mobileActivation,.mobileGestalt,.mobileGestalt,.mobileActivation]))
        }
    }
}

for finalRead in [false, true] {
    let memory = MemoryAccess([.mobileGestalt: baselineBytes, .mobileActivation: maOriginal])
    let transaction = store(memory, "read-fault-\(finalRead)")
    var injected = false
    memory.readFault = { file, io in
        if !injected && io.events.count == (finalRead ? 2 : 1) && file == .mobileActivation {
            injected = true
            throw RegionOperationError("injected verification read failure")
        }
    }
    rejects { _ = try transaction.apply(module: .fullJapan, plans: [maPlan, fullMG]) }
    expect(memory.data[.mobileGestalt] == baselineBytes && memory.data[.mobileActivation] == maOriginal)
    expect(try transaction.pending().isEmpty)
}
let failedRollbackIO = MemoryAccess([.mobileGestalt: baselineBytes, .mobileActivation: maOriginal])
let failedRollbackStore = store(failedRollbackIO, "rollback-failure")
failedRollbackIO.callback = { file, _, replacement, io in
    if io.events.count == 3 { throw RegionOperationError("injected rollback failure") }
    io.data[file] = replacement
    if io.events.count == 2 { throw RegionOperationError("injected failure after second write") }
}
rejects { _ = try failedRollbackStore.apply(module: .fullJapan, plans: [maPlan, fullMG]) }
expect(try failedRollbackStore.pending().first?.phase == .recoveryRequired)
expect(failedRollbackIO.data[.mobileActivation] == maOriginal)
failedRollbackIO.callback = nil
_ = try store(failedRollbackIO, "rollback-failure").recoverPending()
expect(failedRollbackIO.data[.mobileGestalt] == baselineBytes)

// If commit/rollback-intent metadata becomes unwritable after both sources are
// verified, preserve the complete intended state instead of starting an
// unjournaled partial rollback. Corrupt metadata then blocks further writes.
let metadataIO = MemoryAccess([.mobileGestalt: baselineBytes, .mobileActivation: maOriginal])
let metadataStore = store(metadataIO, "metadata-failure")
metadataIO.callback = { file, _, replacement, io in
    io.data[file] = replacement
    if io.events.count == 2 {
        let pending = try metadataStore.pending().first!
        let path = metadataStore.root.appendingPathComponent(pending.id).appendingPathComponent("journal.plist")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    }
}
rejects { _ = try metadataStore.apply(module: .fullJapan, plans: [maPlan, fullMG]) }
expect(metadataIO.events == [.mobileActivation, .mobileGestalt])
expect(metadataIO.data[.mobileGestalt] == fullMG.after && metadataIO.data[.mobileActivation] == maPlan.after)
rejects { _ = try metadataStore.pending() }
rejects { _ = try metadataStore.apply(module: .regionCode, plans: [plan(.regionCode, metadataIO.data[.mobileGestalt]!)]) }

// An unfinished standalone MA transaction cannot hold unrelated MG modules hostage.
let isolatedIO = MemoryAccess([.mobileGestalt: baselineBytes, .mobileActivation: maOriginal])
let isolatedStore = store(isolatedIO, "isolated-pending")
isolatedIO.callback = { file, _, _, io in
    io.data[file] = Data([9,9]); throw RegionOperationError("injected torn MA write")
}
rejects { _ = try isolatedStore.apply(module: .mobileActivation, plans: [maPlan]) }
isolatedIO.callback = nil
_ = try isolatedStore.apply(module: .regionCode, plans: [mgPlan])
expect(isolatedIO.data[.mobileGestalt] == mgPlan.after)
expect(try isolatedStore.pending().count == 1)

let driftIO = MemoryAccess([.mobileGestalt: baselineBytes])
let driftStore = store(driftIO, "target-drift")
_ = try driftStore.apply(module: .regionCode, plans: [mgPlan])
var externalRoot = root(driftIO.data[.mobileGestalt]!), externalExtra = extra(driftIO.data[.mobileGestalt]!)
externalExtra[code] = "LL"; externalRoot["CacheExtra"] = externalExtra
driftIO.data[.mobileGestalt] = encode(externalRoot)
let driftWrites = driftIO.events.count
rejects { _ = try driftStore.apply(module: .regionCode, plans: [plan(.regionCode, driftIO.data[.mobileGestalt]!)]) }
rejects { _ = try driftStore.restore(module: .regionCode) }
expect(driftIO.events.count == driftWrites)
let wrongBuild = RegionTransactionCoordinator(root: driftStore.root, access: driftIO, productType: profile, build: "other-build")
rejects { _ = try wrongBuild.originalAvailable(for: .regionCode) }

// Relaunch after termination between system write and durable commit.
let crashIO = MemoryAccess([.mobileGestalt: baselineBytes])
let crashStore = store(crashIO, "crash")
_ = try crashStore.apply(module: .regionCode, plans: [mgPlan])
let originalRecord = try PropertyListDecoder().decode([String:String].self,
    from: Data(contentsOf: crashStore.root.appendingPathComponent("originals/regionCode.plist")))
let journalURL = crashStore.root.appendingPathComponent(originalRecord["transaction"]!).appendingPathComponent("journal.plist")
var journal = try PropertyListDecoder().decode(RegionJournal.self, from: Data(contentsOf: journalURL))
journal.phase = .writing
try PropertyListEncoder().encode(journal).write(to: journalURL)
let relaunched = store(crashIO, "crash")
expect(try relaunched.pending().count == 1)
_ = try relaunched.recoverPending()
expect(crashIO.data[.mobileGestalt] == baselineBytes)
expect(try relaunched.pending().isEmpty)

// A prepared journal has complete backups but no system writes yet.
journal.phase = .prepared
try PropertyListEncoder().encode(journal).write(to: journalURL)
let unrelatedExternal = encode(["CacheExtra": [code: "LL"]])
crashIO.data[.mobileGestalt] = unrelatedExternal
_ = try relaunched.recoverPending()
expect(crashIO.data[.mobileGestalt] == unrelatedExternal) // No system write in prepared phase; preserve external edits.
crashIO.data[.mobileGestalt] = baselineBytes
// Interrupting backup creation is recognizable even if raw backup files are incomplete.
journal.phase = .preparing
try PropertyListEncoder().encode(journal).write(to: journalURL)
_ = try relaunched.recoverPending()
expect(try relaunched.pending().isEmpty)

// Backup corruption, external edits, unauthorized keys/bytes and backup failure.
try Data([9]).write(to: journalURL.deletingLastPathComponent().appendingPathComponent("mobileGestalt.before.plist"))
rejects { _ = try relaunched.apply(module: .regionCode, plans: [mgPlan]) }
let external = MemoryAccess([.mobileGestalt: manual])
rejects { _ = try store(external, "stale").apply(module: .regionCode, plans: [mgPlan]) }
expect(external.events.isEmpty)
var wrongRoot = root(mgPlan.after); wrongRoot["other"] = "damage"
rejects { try mgPlan.scope.validate(before: baselineBytes, after: encode(wrongRoot)) }
let forbidden = RegionWritePlan(file: .mobileGestalt, before: baselineBytes, after: encode(wrongRoot), scope: .init(rootKeys: ["other"]))
let forbiddenIO = MemoryAccess([.mobileGestalt: baselineBytes])
rejects { _ = try store(forbiddenIO, "forbidden").apply(module: .regionCode, plans: [forbidden]) }
let unavailableRoot = temporary.appendingPathComponent("not-a-directory")
try Data([1]).write(to: unavailableRoot)
let failedBackup = RegionTransactionCoordinator(root: unavailableRoot, access: forbiddenIO, productType: profile, build: build)
rejects { _ = try failedBackup.apply(module: .regionCode, plans: [mgPlan]) }
expect(forbiddenIO.events.isEmpty)
expect(RegionBackupDigest.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
expect(RegionBackupDigest.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
print("PASS: \(checks) actual Swift module, descriptor, whitelist, backup, restore, rollback and interruption checks (synthetic host data only)")
