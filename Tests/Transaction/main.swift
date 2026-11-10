// SPDX-License-Identifier: GPL-3.0-only
import Foundation

MainActor.assumeIsolated {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let service = RegionIdentityService(backupRoot: temporary, deviceContext: { ("iPhone18,3", "fixture-build") })
    @MainActor func status(_ module: RegionModule) -> RegionModuleStatus {
        service.modules.first { $0.module == module }!
    }
    service.refresh()
    assert(status(.regionCode).canApply && status(.regionInfo).canApply && status(.regulatoryModel).canApply)
    assert(status(.intelligence).canApply)
    assert(!status(.greenTea).canApply && !status(.wapi).canApply && !status(.mobileActivation).canApply && !status(.fullJapan).canApply)
    service.applyJapanRegion()
    assert(service.errorMessage != nil && !Fixture.events.contains("writeMG") && !Fixture.events.contains("writeMA"))
    assert(Fixture.events.contains("diagnoseMA")) // Composite preflight is explicit.
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
    print("PASS: actual service isolation, independent Apply/Restore, no activation I/O, full gate, read-only/unknown-device diagnostics (simulated native APIs)")
}
