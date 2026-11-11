// SPDX-License-Identifier: GPL-3.0-only
// ユーザー提供の観測値を固定。未確認の参照機種を製品用 scope に登録しない。
import Foundation

var checks = 0
func expect(_ value: Bool) { checks += 1; precondition(value) }
let japanData = Data(base64Encoded: "GQAAAAAAAAAAAAAAAAAAAA==")!
let chinaData = Data(base64Encoded: "QQEAAAAAAAAAAAAAAAAAAA==")!
let japan: [String: Any] = [
    "RegionalBehaviorChinaBrick": false, "RegionalBehaviorEUVolumeLimit": false,
    "RegionalBehaviorGB18030": false, "RegionalBehaviorGoogleMail": false,
    "RegionalBehaviorNTSC": true, "RegionalBehaviorNoPasscodeLocationTiles": false,
    "RegionalBehaviorNoVOIP": false, "RegionalBehaviorNoWiFi": false,
    "RegionalBehaviorShutterClick": true, "RegionalBehaviorValid": true,
    "RegionalBehaviorVolumeLimit": false, "SwBHValid": true, "SoftwareBehavior": japanData
]
let china: [String: Any] = [
    "RegionalBehaviorChinaBrick": true, "RegionalBehaviorEUVolumeLimit": false,
    "RegionalBehaviorGB18030": true, "RegionalBehaviorGoogleMail": false,
    "RegionalBehaviorNTSC": false, "RegionalBehaviorNoPasscodeLocationTiles": false,
    "RegionalBehaviorNoVOIP": false, "RegionalBehaviorNoWiFi": false,
    "RegionalBehaviorShutterClick": false, "RegionalBehaviorValid": true,
    "RegionalBehaviorVolumeLimit": false, "SwBHValid": true, "SoftwareBehavior": chinaData
]
func answers(_ all: [String: Any]) -> [String: Any] {
    var result = all
    result.removeValue(forKey: "SwBHValid")
    result["RegionalBehaviorAll"] = all
    return result
}
let observed = JapanRegionalBehaviorReference.observed
// この scope はテスト専用の仮定。実機の適用範囲を確認したという証拠ではない。
let scoped = JapanRegionalBehaviorReference(scope: .init(productType: "fixture-phone", build: "fixture-build", initializationEnvironment: "synthetic test"))
func compare(_ values: [String: Any]) -> RegionalBehaviorComparison {
    scoped.compare(.values(values), productType: "fixture-phone", build: "fixture-build")
}
expect(japanData.count == 16 && chinaData.count == 16)
expect(JapanRegionalBehaviorReference.firstUInt32LE(chinaData) == 0x141)
expect(JapanRegionalBehaviorReference.firstUInt32LE(japanData) == 0x19)
expect(JapanRegionalBehaviorReference.firstUInt32LE(Data([0x12, 0x34, 0x56, 0x78])) == 0x78563412)
expect(JapanRegionalBehaviorReference.firstUInt32LE(Data([1, 2, 3])) == nil)
expect(JapanRegionalBehaviorReference.softwareBehavior == japanData)
let match = compare(answers(japan))
expect(match.status == .match && match.checks.count == 25)
expect(match.checks.allSatisfy { $0.result == .equal })
let mismatch = compare(answers(china))
expect(mismatch.status == .mismatch)
for name in ["ChinaBrick", "GB18030", "NTSC", "ShutterClick"] {
    expect(mismatch.checks.contains { $0.id == "All.RegionalBehavior\(name)" && $0.result == .mismatch })
}
for name in ["RegionalBehaviorValid", "SwBHValid"] {
    expect(mismatch.checks.contains { $0.id == "All.\(name)" && $0.result == .equal })
    var all = japan; all[name] = false
    let different = compare(answers(all))
    expect(different.status == .mismatch)
    expect(different.checks.contains { $0.id == "All.\(name)" && $0.result == .mismatch })
    let other = name == "SwBHValid" ? "RegionalBehaviorValid" : "SwBHValid"
    expect(different.checks.contains { $0.id == "All.\(other)" && $0.result == .equal })
}
for name in japan.keys {
    var all = japan; all.removeValue(forKey: name)
    let result = compare(answers(all))
    expect(result.status == .incomplete)
    expect(result.checks.contains { $0.id == "All.\(name)" && $0.result == .missing })
}
for bad in [NSNumber(value: 1), "true", Data([1]), NSNull()] as [Any] {
    var all = japan; all["SwBHValid"] = bad
    expect(compare(answers(all)).status == .incomplete)
}
for bad in [NSNumber(value: 25), "25", "0x19", [UInt8](japanData)] as [Any] {
    var all = japan; all["SoftwareBehavior"] = bad
    let result = compare(answers(all))
    expect(result.status == .incomplete && result.checks.contains { $0.id == "All.SoftwareBehavior" && $0.result == .typeError })
}
for data in [Data(japanData.prefix(4)), japanData + Data([0]), Data([0x19, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 11))] {
    var all = japan; all["SoftwareBehavior"] = data
    expect(compare(answers(all)).status == .mismatch)
}
var extra = japan; extra["UnreviewedFlag"] = false
expect(compare(answers(extra)).status == .incomplete)
expect(compare(answers(extra)).checks.contains { $0.id == "All.UnreviewedFlag" && $0.result == .extra })
var values = answers(japan); values["RegionalBehaviorAll"] = 25
expect(compare(values).status == .incomplete)
values["RegionalBehaviorAll"] = NSNull()
expect(compare(values).status == .incomplete)
values = answers(china); values["RegionalBehaviorAll"] = NSNull()
let partial = compare(values)
expect(partial.status == .incomplete && partial.checks.contains { $0.result == .mismatch })
expect(FullJapanAcceptance.assess(identityMatches: true, behavior: partial) == .regionalNotVerified)
values = answers(japan); values["RegionalBehaviorValid"] = false
expect(compare(values).status == .mismatch) // 単独質問が All と異なる。
values = answers(japan); values["SoftwareBehavior"] = chinaData
expect(compare(values).status == .mismatch)
values = answers(japan); values.removeValue(forKey: "RegionalBehaviorValid")
expect(compare(values).status == .incomplete)
expect(observed.compare(.notRead, productType: "", build: "").status == .notRead)
let failed = observed.compare(.failed("denied"), productType: "", build: "")
expect(failed.status == .readFailed && failed.detail == "denied")
let unscoped = observed.compare(.values(answers(japan)), productType: "iPhone18,3", build: "24B119")
expect(unscoped.status == .referenceConsistent)
expect(scoped.compare(.values(answers(japan)), productType: "other", build: "fixture-build").status == .referenceConsistent)
expect(scoped.compare(.values(answers(japan)), productType: "fixture-phone", build: "other-build").status == .referenceConsistent)
let unknownEnvironment = JapanRegionalBehaviorReference(scope: .init(productType: "fixture-phone", build: "fixture-build", initializationEnvironment: ""))
expect(unknownEnvironment.compare(.values(answers(japan)), productType: "fixture-phone", build: "fixture-build").status == .referenceConsistent)
let identity: [String: Any] = ["RegionCode": "J", "RegionInfo": "J/A", "RegulatoryModelNumber": "A3519",
    "green-tea": false, "not-green-tea": true, "wapi": false]
expect(FullJapanAcceptance.identityMatches(runtime: identity, persistent: identity, regulatoryModel: "A3519"))
var badIdentity = identity; badIdentity["wapi"] = NSNumber(value: 0)
expect(!FullJapanAcceptance.identityMatches(runtime: badIdentity, persistent: identity, regulatoryModel: "A3519"))
badIdentity = identity; badIdentity["RegionCode"] = "CH"
expect(!FullJapanAcceptance.identityMatches(runtime: identity, persistent: badIdentity, regulatoryModel: "A3519"))
expect(!FullJapanAcceptance.identityMatches(runtime: identity, persistent: identity, regulatoryModel: nil))
expect(FullJapanAcceptance.assess(identityMatches: true, behavior: mismatch) == .regionalMismatch)
expect(FullJapanAcceptance.assess(identityMatches: true, behavior: failed) == .regionalNotVerified)
expect(FullJapanAcceptance.assess(identityMatches: true, behavior: unscoped, restartVerified: true, systemFunctionsVerified: true) == .regionalNotVerified)
expect(FullJapanAcceptance.assess(identityMatches: false, behavior: match) == .identityNotVerified)
expect(FullJapanAcceptance.assess(identityMatches: true, behavior: match) == .restartPending)
expect(FullJapanAcceptance.assess(identityMatches: true, behavior: match, restartVerified: true) == .functionsPending)
expect(FullJapanAcceptance.assess(identityMatches: true, behavior: match, restartVerified: true, systemFunctionsVerified: true) == .verified)
print("PASS: \(checks) RegionalBehavior parsing, complete observed dictionaries, independent validity, scope and Full Japan acceptance checks (synthetic runtime)")
