// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

nonisolated enum RegionalBehaviorRead {
    case notRead
    case failed(String)
    case values([String: Any])
}

nonisolated struct RegionalBehaviorCheck: Identifiable {
    enum Result: String { case equal = "Equal", mismatch = "Mismatch", missing = "Missing", typeError = "Type Error", extra = "Extra Field" }
    let id: String
    let result: Result
    let detail: String
}

nonisolated struct RegionalBehaviorComparison {
    enum Status: String {
        case notRead = "Not Read"
        case readFailed = "Read Failed"
        case incomplete = "RegionalBehavior Not Verified"
        case mismatch = "RegionalBehavior Mismatch"
        case referenceConsistent = "Reference Consistent — Scope Not Verified"
        case match = "Match"
    }
    let status: Status
    let checks: [RegionalBehaviorCheck]
    let detail: String
}

nonisolated struct RegionalBehaviorReferenceScope {
    let productType: String
    let build: String
    let initializationEnvironment: String

    func applies(to productType: String, build: String) -> Bool {
        !self.productType.isEmpty && !self.build.isEmpty && !initializationEnvironment.isEmpty
            && self.productType == productType && self.build == build
    }
}

/// ユーザーの日本向け実機観測。機種・Build・初期化条件は未確認であり、全機種共通の規則ではない。
nonisolated struct JapanRegionalBehaviorReference {
    static let observed = JapanRegionalBehaviorReference(scope: nil)
    let scope: RegionalBehaviorReferenceScope?

    static let softwareBehavior = Data([0x19] + [UInt8](repeating: 0, count: 15))
    static let booleans: [String: Bool] = [
        "RegionalBehaviorChinaBrick": false,
        "RegionalBehaviorEUVolumeLimit": false,
        "RegionalBehaviorGB18030": false,
        "RegionalBehaviorGoogleMail": false,
        "RegionalBehaviorNTSC": true,
        "RegionalBehaviorNoPasscodeLocationTiles": false,
        "RegionalBehaviorNoVOIP": false,
        "RegionalBehaviorNoWiFi": false,
        "RegionalBehaviorShutterClick": true,
        "RegionalBehaviorValid": true,
        "RegionalBehaviorVolumeLimit": false,
        "SwBHValid": true
    ]
    // SwBHValid は All 辞書のキーであり、独立した MG 質問とは確認されていない。
    static let booleanQueries = booleans.keys.filter { $0 != "SwBHValid" }.sorted()
    static let queries = ["RegionalBehaviorsFromActivation", "RegionalBehaviorAll", "SoftwareBehavior"] + booleanQueries
    static let persistenceBlock = "No verified persistent RegionalBehavior modification mechanism. Full Japan Apply is disabled."

    var scopeDescription: String {
        guard let scope else {
            return "User-observed Japan reference; ProductType, iOS Build and initialization environment are unconfirmed. Equal values are reference consistency only."
        }
        return "Reference: \(scope.productType) / \(scope.build); initialization: \(scope.initializationEnvironment). Current-process comparison only."
    }

    func compare(_ read: RegionalBehaviorRead, productType: String, build: String) -> RegionalBehaviorComparison {
        let answers: [String: Any]
        switch read {
        case .notRead: return .init(status: .notRead, checks: [], detail: "RegionalBehavior has not been queried.")
        case .failed(let error): return .init(status: .readFailed, checks: [], detail: error)
        case .values(let values): answers = values
        }
        var checks: [RegionalBehaviorCheck] = []
        func check(_ name: String, _ actual: Any?, expected: Any) {
            let result: RegionalBehaviorCheck.Result
            if actual == nil || actual is NSNull { result = .missing }
            else if let expected = expected as? Data {
                if let actual = actual as? Data { result = actual == expected ? .equal : .mismatch }
                else { result = .typeError }
            } else if let expected = Self.boolean(expected) {
                if let actual = Self.boolean(actual) { result = actual == expected ? .equal : .mismatch }
                else { result = .typeError }
            } else { result = .typeError }
            checks.append(.init(id: name, result: result,
                detail: "Actual: \(Self.describe(actual)); expected: \(Self.describe(expected))"))
        }
        if let all = answers["RegionalBehaviorAll"] as? [String: Any] {
            for name in Self.booleans.keys.sorted() { check("All.\(name)", all[name], expected: Self.booleans[name]!) }
            check("All.SoftwareBehavior", all["SoftwareBehavior"], expected: Self.softwareBehavior)
            let required = Set(Self.booleans.keys).union(["SoftwareBehavior"])
            for name in all.keys.sorted() where !required.contains(name) {
                checks.append(.init(id: "All.\(name)", result: .extra, detail: Self.describe(all[name])))
            }
        } else {
            let value = answers["RegionalBehaviorAll"]
            checks.append(.init(id: "RegionalBehaviorAll", result: value == nil || value is NSNull ? .missing : .typeError,
                                detail: "Expected CFDictionary; actual: \(Self.describe(value))"))
        }
        // 単独質問と辞書内の値を別々に比較し、不一致を隠さない。
        check("MG.SoftwareBehavior", answers["SoftwareBehavior"], expected: Self.softwareBehavior)
        for name in Self.booleanQueries { check("MG.\(name)", answers[name], expected: Self.booleans[name]!) }
        let status: RegionalBehaviorComparison.Status
        if checks.contains(where: { $0.result != .equal && $0.result != .mismatch }) { status = .incomplete }
        else if checks.contains(where: { $0.result == .mismatch }) { status = .mismatch }
        else if scope?.applies(to: productType, build: build) == true { status = .match }
        else { status = .referenceConsistent }
        return .init(status: status, checks: checks, detail: scopeDescription)
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// CFData の生データを保持したまま、先頭 word を明示的な LE として読む。
    static func firstUInt32LE(_ data: Data) -> UInt32? {
        let bytes = Array(data.prefix(4))
        guard bytes.count == 4 else { return nil }
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "<nil>" }
        if let data = value as? Data {
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            var result = "CFData (\(data.count) bytes)\nHex: \(hex)\nBase64: \(data.base64EncodedString())"
            if let word = firstUInt32LE(data) { result += String(format: "\nUInt32 LE: 0x%08X (%u)", word, word) }
            return result
        }
        if let bool = boolean(value) { return "CFBoolean: \(bool)" }
        if let all = value as? [String: Any] {
            return "CFDictionary {\n" + all.keys.sorted().map { "\($0): \(describe(all[$0]))" }.joined(separator: "\n") + "\n}"
        }
        if value is String { return "CFString: \(value)" }
        if value is NSNumber { return "CFNumber: \(value)" }
        return "\(type(of: value)): \(value)"
    }
}

nonisolated enum FullJapanAcceptance: String {
    case identityNotVerified = "Japan Region Identity Not Verified"
    case regionalMismatch = "RegionalBehavior Mismatch"
    case regionalNotVerified = "RegionalBehavior Not Verified"
    case restartPending = "Reference Match — Restart Not Verified"
    case functionsPending = "Restart Verified — System Functions Not Verified"
    case verified = "Full Japan Verified"

    /// 読み取り一致から再起動・他プロセス・実機機能の成功を推定しない。
    static func assess(identityMatches: Bool, behavior: RegionalBehaviorComparison,
                       restartVerified: Bool = false, systemFunctionsVerified: Bool = false) -> Self {
        if behavior.status == .mismatch { return .regionalMismatch }
        guard behavior.status == .match else { return .regionalNotVerified }
        guard identityMatches else { return .identityNotVerified }
        guard restartVerified else { return .restartPending }
        guard systemFunctionsVerified else { return .functionsPending }
        return .verified
    }

    static func identityMatches(runtime: [String: Any], persistent: [String: Any], regulatoryModel: String?) -> Bool {
        guard let regulatoryModel else { return false }
        let strings = ["RegionCode": "J", "RegionInfo": "J/A", "RegulatoryModelNumber": regulatoryModel]
        let flags = ["green-tea": false, "not-green-tea": true, "wapi": false]
        return [runtime, persistent].allSatisfy { values in
            strings.allSatisfy { values[$0.key] as? String == $0.value }
                && flags.allSatisfy { JapanRegionalBehaviorReference.boolean(values[$0.key]) == $0.value }
        }
    }
}
