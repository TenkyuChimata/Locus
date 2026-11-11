// SPDX-License-Identifier: GPL-3.0-only
import Foundation

MainActor.assumeIsolated {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let service = RegionIdentityService(backupRoot: temporary, deviceContext: { ("iPhone18,3", "fixture-build") })
    @MainActor func status(_ module: RegionModule) -> RegionModuleStatus {
        service.modules.first { $0.module == module }!
    }
    @MainActor func diagnostic(_ title: String) -> String {
        service.activationDiagnostics.first { $0.title == title }!.value
    }
    service.refresh()
    assert(!Fixture.events.contains("diagnoseMA"))
    assert(service.activationDiagnostics.allSatisfy { $0.value == "Not Tested" })
    assert(status(.regionCode).canApply && status(.regionInfo).canApply && status(.regulatoryModel).canApply)
    assert(status(.intelligence).canApply)
    assert(!status(.greenTea).canApply && !status(.wapi).canApply && !status(.mobileActivation).canApply && !status(.fullJapan).canApply)
    service.applyJapanRegion()
    assert(service.errorMessage != nil && !Fixture.events.contains("writeMG") && !Fixture.events.contains("writeMA"))
    assert(!Fixture.events.contains("diagnoseMA")) // A blocked action does not refresh research.
    service.refreshResearch()
    assert(Fixture.events.filter { $0 == "diagnoseMA" }.count == 1)
    assert(diagnostic("SystemGroup Resolution") == "Failed" && diagnostic("Resolver Status").contains("55"))
    assert(diagnostic("Container Query").contains("POSIX=1"))
    for title in ["Backing Read", "Schema Valid", "Write Access", "Write Error"] {
        assert(diagnostic(title) == "Not Tested")
    }
    assert(diagnostic("MobileActivation API") == "Succeeded")
    assert(diagnostic("CountryCode") == "JP" && diagnostic("RegionInfo") == "J/A" && diagnostic("SoftwareBehaviors") == "25")
    assert(diagnostic("Binary Gate") == "Unreviewed (writes blocked)" && diagnostic("Mutation Schema") == "Blocked")
    let successObservation = service.activationDiagnostics.map(\.value)
    Fixture.activationDiagnostics["effectiveCallSucceeded"] = false
    Fixture.activationDiagnostics["effectiveStage"] = "api-error"
    Fixture.activationDiagnostics["effectiveErrorDomain"] = "com.apple.MobileActivation.ErrorDomain"
    Fixture.activationDiagnostics["effectiveErrorCode"] = -28
    Fixture.activationDiagnostics["effectiveErrorDescription"] = "Device region is unsupported."
    service.refresh()
    assert(service.activationDiagnostics.map(\.value) == successObservation) // Cached until explicit refresh.
    service.refreshResearch()
    assert(diagnostic("MobileActivation API") == "Failed" && diagnostic("API Stage") == "api-error")
    assert(diagnostic("API Error").contains("com.apple.MobileActivation.ErrorDomain / -28 / Device region is unsupported."))
    assert(!service.activationDiagnostics.contains { $0.title == "CountryCode" })
    Fixture.activationDiagnostics["effectiveCallSucceeded"] = true
    service.refreshResearch()
    assert(diagnostic("MobileActivation API") == "Succeeded with error" && diagnostic("CountryCode") == "JP")
    Fixture.activationDiagnostics["effectiveCallSucceeded"] = false
    Fixture.activationDiagnostics["backingPathState"] = ["state": "stat-failed; existence unknown", "domain": "NSPOSIXErrorDomain", "code": 13]
    service.refreshResearch()
    assert(diagnostic("Backing File State").contains("existence unknown") && diagnostic("Backing File State").contains(":13"))
    Fixture.activationDiagnostics["backingPathState"] = ["state": "stat-failed; existence unknown", "domain": "NSPOSIXErrorDomain", "code": 2]
    service.refreshResearch()
    assert(diagnostic("Backing File State") == "Not found at candidate path (NSPOSIXErrorDomain:2)")
    Fixture.activationDiagnostics["backingReadSucceeded"] = false
    Fixture.activationDiagnostics["backingStage"] = "plist-parse"
    Fixture.activationDiagnostics["backingReadError"] = "Malformed plist"
    service.refreshResearch()
    assert(diagnostic("Backing Read") == "Failed" && diagnostic("Backing Stage") == "plist-parse")
    assert(diagnostic("Read Error") == "Malformed plist" && diagnostic("Schema Valid") == "Not Tested")
    Fixture.activationDiagnostics["backingReadSucceeded"] = true
    Fixture.activationDiagnostics["backingSchemaValid"] = false
    Fixture.activationDiagnostics["backingWriteAccessAvailable"] = false
    Fixture.activationDiagnostics["backingWriteAccessError"] = "errno=13"
    service.refreshResearch()
    assert(diagnostic("Backing Read") == "Succeeded" && diagnostic("Schema Valid") == "Unsupported")
    assert(diagnostic("Write Access") == "Failed (writes unavailable)" && diagnostic("Write Error") == "errno=13")
    assert(!status(.mobileActivation).canApply && !status(.mobileActivation).canRestore && !status(.fullJapan).canApply)
    Fixture.events = []
    service.apply(.regionCode)
    assert(service.errorMessage == nil && service.operationResult != nil)
    assert(status(.regionCode).originalAvailable && status(.regionCode).canRestore)
    assert(!Fixture.events.contains("readMA") && !Fixture.events.contains("writeMA"))
    assert(!Fixture.events.contains("diagnoseMA")) // No unrelated framework query/container scan.
    service.apply(.intelligence)
    assert(service.errorMessage == nil && status(.intelligence).originalAvailable)
    service.restore(.regionCode)
    assert(service.errorMessage == nil && service.operationResult != nil)
    let extra = try! RegionPlist.parse(Fixture.gestalt).root["CacheExtra"] as! [String:Any]
    assert(extra[JapanRegionMutation.regionCodeKey] as? String == "CH")
    assert((extra[RegionModuleMutation.intelligenceKey] as? NSNumber)?.intValue == 1)
    service.restore(.intelligence)
    assert(service.errorMessage == nil)
    assert(RegionPlist.equal(try! RegionPlist.parse(Fixture.gestalt).root, try! RegionPlist.parse(Fixture.baseline).root))
    assert(!service.shouldRespring) // A file write never claims restart/function success.
    Fixture.writable = false
    service.refresh()
    assert(!status(.regionCode).canApply && !status(.intelligence).canApply)
    assert(!status(.regionCode).cache.isEmpty && !status(.wapi).detail.isEmpty)
    Fixture.writable = true
    let unsupported = RegionIdentityService(backupRoot: temporary.appendingPathComponent("unknown"),
        deviceContext: { ("unknown-model", "fixture-build") })
    unsupported.refresh()
    assert(unsupported.modules.first { $0.module == .regulatoryModel }!.canApply == false)
    assert(unsupported.modules.first { $0.module == .regionCode }!.canApply)
    assert(unsupported.modules.first { $0.module == .intelligence }!.canApply)
    assert(unsupported.modules.count == RegionModule.allCases.count)
    // Known layout enables only the three cache modules; the real service's
    // confirmation path prepares verified backups before any write.
    var known = try! RegionPlist.parse(Fixture.baseline).root
    var bytes = Data(repeating: 0, count: 6480)
    for slot in [383, 506, 694] { bytes[5760 + slot] = 1 }
    bytes[3064] = 1; bytes[5552] = 1
    known["CacheData"] = bytes; known["CacheVersion"] = "24B119"
    known["CacheUUID"] = "48CB1FAC-755B-435F-9A01-A20E5D810EA9"
    Fixture.gestalt = try! PropertyListSerialization.data(fromPropertyList: known, format: .binary, options: 0)
    let cacheService = RegionIdentityService(backupRoot: temporary.appendingPathComponent("known"),
        deviceContext: { ("iPhone18,3", "24B119") }, deviceID: "simulated-device")
    cacheService.refresh()
    for module in [RegionModule.greenTea, .notGreenTea, .wapi] {
        assert(cacheService.modules.first { $0.module == module }!.canApply)
    }
    assert(!cacheService.modules.first { $0.module == .mobileActivation }!.canApply)
    assert(!cacheService.modules.first { $0.module == .fullJapan }!.canApply)
    Fixture.events = []
    assert(cacheService.prepare(.greenTea))
    assert(cacheService.prepared?.phase == .prepared)
    assert(cacheService.comparisons.contains("green-tea: true → false"))
    assert(!Fixture.events.contains("writeMG") && !Fixture.events.contains("diagnoseMA"))
    cacheService.cancelPrepared()
    assert(cacheService.prepared == nil && !Fixture.events.contains("writeMG"))
    assert(!cacheService.modules.first { $0.module == .greenTea }!.originalAvailable)
    assert(cacheService.prepare(.wapi))
    cacheService.confirmPrepared()
    assert(cacheService.errorMessage == nil && cacheService.modules.first { $0.module == .wapi }!.canRestore)
    cacheService.restore(.wapi)
    assert(cacheService.errorMessage == nil && (try! RegionPlist.parse(Fixture.gestalt).root["CacheData"] as! Data)[5552] == 1)
    assert(cacheService.prepare(.greenTea))
    var drift = try! RegionPlist.parse(Fixture.gestalt).root
    drift["external"] = true
    Fixture.gestalt = try! PropertyListSerialization.data(fromPropertyList: drift, format: .binary, options: 0)
    let writes = Fixture.events.filter { $0 == "writeMG" }.count
    cacheService.confirmPrepared()
    assert(cacheService.errorMessage?.contains("Source changed") == true)
    assert(Fixture.events.filter { $0 == "writeMG" }.count == writes)
    Fixture.writable = false
    cacheService.refresh()
    assert(!cacheService.modules.first { $0.module == .wapi }!.canApply)
    assert(!cacheService.modules.first { $0.module == .wapi }!.canRestore)
    print("PASS: actual service preview/cancel/confirm, known-layout Apply/Restore, external drift, independent activation/full gates and read-only diagnostics (simulated native APIs)")
}
