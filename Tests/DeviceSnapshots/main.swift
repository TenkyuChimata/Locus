// SPDX-License-Identifier: GPL-3.0-only
// Optional, read-only checks against user-supplied snapshots; never app resources.
import Foundation
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let original = try Data(contentsOf: url)
    let parsed = try RegionPlist.parse(original).root
    let product = (parsed["CacheExtra"] as? [String:Any])?["h9jDsbgj7xIVeIQ8S3/X3Q"] as? String ?? ""
    for module in [RegionModule.regionCode, .regionInfo] + (JapanRegionProfile.verified(for: product)?.productType == nil ? [] : [.regulatoryModel]) {
        let plan = try RegionModuleMutation.plan(module: module, raw: original, productType: product)
        try plan.scope.validate(before: original, after: plan.after)
        let restored = try plan.scope.restoring(original: original, applied: plan.after, current: plan.after)
        precondition(restored == original)
        let after = try RegionPlist.parse(plan.after).root
        precondition(RegionPlist.equal(parsed["CacheData"], after["CacheData"]))
    }
    let unchanged = try Data(contentsOf: url)
    precondition(unchanged == original)
    print("PASS: read-only real snapshot \(url.lastPathComponent): independent in-memory edits, exact restore and CacheData preservation; no binary/device validation")
}
