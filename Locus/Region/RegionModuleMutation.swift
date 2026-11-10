// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

nonisolated enum RegionModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case regionCode, regionInfo, regulatoryModel, greenTea, notGreenTea, wapi, intelligence, mobileActivation, fullJapan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .regionCode: return "RegionCode"
        case .regionInfo: return "RegionInfo"
        case .regulatoryModel: return "RegulatoryModelNumber"
        case .greenTea: return "green-tea"
        case .notGreenTea: return "not-green-tea"
        case .wapi: return "wapi"
        case .intelligence: return "Apple Intelligence Capability"
        case .mobileActivation: return "MobileActivation Region Identity"
        case .fullJapan: return "Full Japan Region"
        }
    }
    var question: RegionCacheQuestion? {
        switch self {
        case .greenTea: return .greenTea
        case .notGreenTea: return .notGreenTea
        case .wapi: return .wapi
        default: return nil
        }
    }
    var runtimeQuery: String {
        if let question { return question.rawValue }
        if self == .intelligence { return RegionModuleMutation.intelligenceKey }
        return title
    }
}

nonisolated struct RegionOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

nonisolated enum RegionPlist {
    static func parse(_ raw: Data) throws -> (root: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let root = try PropertyListSerialization.propertyList(from: raw, options: [], format: &format) as? [String: Any],
              format == .binary || format == .xml else { throw JapanRegionError.invalidMobileGestalt }
        return (root, format)
    }
    static func equal(_ left: Any?, _ right: Any?) -> Bool {
        if left == nil || right == nil { return left == nil && right == nil }
        if let a = left as? NSNumber, let b = right as? NSNumber {
            return CFGetTypeID(a) == CFGetTypeID(b)
                && ["f", "d"].contains(String(cString: a.objCType)) == ["f", "d"].contains(String(cString: b.objCType))
                && a == b
        }
        if let a = left as? [String: Any], let b = right as? [String: Any] {
            return Set(a.keys) == Set(b.keys) && a.allSatisfy { equal($0.value, b[$0.key]) }
        }
        if let a = left as? [Any], let b = right as? [Any] {
            return a.count == b.count && zip(a, b).allSatisfy { equal($0.0, $0.1) }
        }
        if let a = left as? String, let b = right as? String { return a == b }
        if let a = left as? Data, let b = right as? Data { return a == b }
        if let a = left as? Date, let b = right as? Date { return a == b }
        return false
    }
}

nonisolated enum RegionFile: String, Codable, Sendable { case mobileGestalt, mobileActivation }

nonisolated struct RegionPatchScope: Codable, Equatable, Sendable {
    var extraKeys: [String] = []
    var rootKeys: [String] = []
    var byteOffsets: [Int] = []
    var cacheUUID: String?
    var cacheVersion: String?
    var cacheLength: Int?

    func validate(before: Data, after: Data) throws {
        let a = try RegionPlist.parse(before).root
        let b = try RegionPlist.parse(after).root
        let allowedRoots = Set(rootKeys + (extraKeys.isEmpty ? [] : ["CacheExtra"]) + (byteOffsets.isEmpty ? [] : ["CacheData"]))
        guard Set(a.keys) == Set(b.keys), Set(a.keys).allSatisfy({ allowedRoots.contains($0) || RegionPlist.equal(a[$0], b[$0]) }) else {
            throw RegionOperationError("Replacement changes an unrelated root key.")
        }
        if !extraKeys.isEmpty {
            guard let ea = a["CacheExtra"] as? [String: Any], let eb = b["CacheExtra"] as? [String: Any],
                  Set(ea.keys).union(eb.keys).allSatisfy({ extraKeys.contains($0) || RegionPlist.equal(ea[$0], eb[$0]) }) else {
                throw RegionOperationError("Replacement changes an unrelated CacheExtra key.")
            }
        }
        if !byteOffsets.isEmpty {
            guard let da = a["CacheData"] as? Data, let db = b["CacheData"] as? Data,
                  da.count == db.count, da.count == cacheLength, da.count > 0,
                  a["CacheUUID"] as? String == cacheUUID, a["CacheVersion"] as? String == cacheVersion,
                  Set(byteOffsets).count == byteOffsets.count,
                  byteOffsets.allSatisfy({ da.indices.contains($0) }),
                  da.indices.allSatisfy({ byteOffsets.contains($0) || da[$0] == db[$0] }) else {
                throw RegionOperationError("Replacement changes unrelated CacheData bytes or layout identity.")
            }
            let slots = da.count / 9
            let targetSlots = Set(byteOffsets.filter { $0 < slots * 8 }.map { $0 / 8 })
            guard da.count.isMultiple(of: 9), slots <= 16384 else { throw JapanRegionError.invalidCachePatchLayout }
            for bytes in [da, db] {
                guard bytes.dropFirst(slots * 8).allSatisfy({ $0 <= 1 }) else { throw JapanRegionError.invalidCachePatchLayout }
                for slot in targetSlots {
                    let offset = slot * 8
                    guard bytes[offset] <= 1, bytes[(offset + 1)..<(offset + 8)].allSatisfy({ $0 == 0 }) else {
                        throw RegionOperationError("Noncanonical Boolean in a cache patch.")
                    }
                }
            }
        }
    }

    /// Restore only this module's exact original values, retaining unrelated
    /// subsequent edits. The full original bytes are used when possible.
    func restoring(original: Data, applied: Data, current: Data) throws -> Data {
        try validate(before: original, after: applied)
        if current == original { return current }
        if current == applied { return original }
        let before = try RegionPlist.parse(original).root
        let expected = try RegionPlist.parse(applied).root
        let parsed = try RegionPlist.parse(current)
        var root = parsed.root
        if !extraKeys.isEmpty {
            guard var extra = root["CacheExtra"] as? [String: Any],
                  let oldExtra = before["CacheExtra"] as? [String: Any],
                  let appliedExtra = expected["CacheExtra"] as? [String: Any] else { throw JapanRegionError.invalidMobileGestalt }
            for key in extraKeys {
                guard RegionPlist.equal(extra[key], appliedExtra[key]) || RegionPlist.equal(extra[key], oldExtra[key]) else {
                    throw RegionOperationError("\(key) was changed by another workflow; restore refused.")
                }
                extra[key] = oldExtra[key]
            }
            root["CacheExtra"] = extra
        }
        for key in rootKeys {
            guard RegionPlist.equal(root[key], expected[key]) || RegionPlist.equal(root[key], before[key]) else {
                throw RegionOperationError("Activation field was changed by another workflow; restore refused.")
            }
            root[key] = before[key]
        }
        if !byteOffsets.isEmpty {
            guard var data = root["CacheData"] as? Data, let old = before["CacheData"] as? Data,
                  let changed = expected["CacheData"] as? Data, data.count == old.count,
                  root["CacheUUID"] as? String == cacheUUID, root["CacheVersion"] as? String == cacheVersion else {
                throw RegionOperationError("Cache identity changed; byte restore refused.")
            }
            for offset in byteOffsets {
                guard data[offset] == changed[offset] || data[offset] == old[offset] else {
                    throw RegionOperationError("Target cache byte changed externally; restore refused.")
                }
                data[offset] = old[offset]
            }
            root["CacheData"] = data
        }
        let result = try PropertyListSerialization.data(fromPropertyList: root, format: parsed.format, options: 0)
        try validate(before: current, after: result)
        return result
    }
}

struct RegionWritePlan {
    let file: RegionFile
    let before: Data
    let after: Data
    let scope: RegionPatchScope

    var comparison: [String] {
        var rows = ["\(file.rawValue): SHA-256 \(RegionBackupDigest.sha256(before)) → \(RegionBackupDigest.sha256(after))"]
        guard let a = try? RegionPlist.parse(before).root, let b = try? RegionPlist.parse(after).root else { return rows }
        func display(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "<absent>" }
        let ea = a["CacheExtra"] as? [String:Any] ?? [:], eb = b["CacheExtra"] as? [String:Any] ?? [:]
        rows += scope.extraKeys.map { "CacheExtra \($0): \(display(ea[$0])) → \(display(eb[$0]))" }
        rows += scope.rootKeys.map { "\(file.rawValue) \($0): \(display(a[$0])) → \(display(b[$0]))" }
        if let da = a["CacheData"] as? Data, let db = b["CacheData"] as? Data {
            rows += scope.byteOffsets.filter { da.indices.contains($0) && db.indices.contains($0) && da[$0] != db[$0] }
                .map { "CacheData[0x\(String($0, radix: 16))]: \(da[$0]) → \(db[$0])" }
        }
        return rows
    }
}

enum RegionModuleMutation {
    static let regionInfoKeys = ["yK+xavymRGZ3xWc1tb8XDg", "zHeENZu+wbg7PUprwNwBWg"]
    nonisolated static let intelligenceKey = "A62OafQ85EJAiiqKn4agtg"

    static func activationPlan(raw: Data) throws -> RegionWritePlan {
        let parsed = try RegionPlist.parse(raw)
        var root = parsed.root
        let families = [["DeviceRegionCountryCode", "CountryCode", "Region"],
                        ["DeviceRegionRegionInfo", "RegionInfo"], ["DeviceRegionSoftwareBehaviors", "SoftwareBehaviors"]]
        let keys = try families.map { family -> String in
            let existing = family.filter { root[$0] != nil }
            guard existing.count == 1, root[existing[0]] is String else { throw RegionOperationError("Unsupported or ambiguous MobileActivation field schema.") }
            return existing[0]
        }
        let country = root[keys[0]] as! String, info = root[keys[1]] as! String, behavior = root[keys[2]] as! String
        let isHex = behavior.lowercased().hasPrefix("0x")
        let digits = isHex ? String(behavior.dropFirst(2)) : behavior
        guard country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil,
              info.range(of: "^[A-Z0-9]{1,4}/[A-Z]$", options: .regularExpression) != nil,
              digits.range(of: isHex ? "^[0-9a-fA-F]+$" : "^[0-9]+$", options: .regularExpression) != nil,
              UInt32(digits, radix: isHex ? 16 : 10) != nil else { throw RegionOperationError("Unsupported MobileActivation field values.") }
        for (key, value) in zip(keys, ["JP", "J/A", "25"]) { root[key] = value }
        let after = RegionPlist.equal(parsed.root, root) ? raw :
            try PropertyListSerialization.data(fromPropertyList: root, format: parsed.format, options: 0)
        let scope = RegionPatchScope(rootKeys: keys)
        try scope.validate(before: raw, after: after)
        return .init(file: .mobileActivation, before: raw, after: after, scope: scope)
    }

    static func identityKey(_ module: RegionModule, extra: [String: Any]) throws -> String {
        switch module {
        case .regionCode: return JapanRegionMutation.regionCodeKey
        case .regulatoryModel: return JapanRegionMutation.regulatoryModelKey
        case .intelligence: return intelligenceKey
        case .regionInfo:
            let existing = regionInfoKeys.filter { extra[$0] != nil }
            guard existing.count == 1 else {
                throw RegionOperationError("Require exactly one existing RegionInfo key. Missing or dual aliases need runtime/binary semantic review; no alias will be added.")
            }
            return existing[0]
        default: throw RegionOperationError("Not an identity/capability field.")
        }
    }

    static func plan(module: RegionModule, raw: Data, productType: String,
                     assessments: [CacheMappingAssessment] = []) throws -> RegionWritePlan {
        let parsed = try RegionPlist.parse(raw)
        var root = parsed.root
        var scope = RegionPatchScope()
        if let question = module.question {
            guard let data = root["CacheData"] as? Data else { throw JapanRegionError.missingCacheData }
            let layout = try RegionCacheMapping.layout(for: question, assessments: assessments, plist: root)
            root["CacheData"] = try layout.applying(to: data)
            let slot = layout.fields[0].slot
            scope.byteOffsets = Array((slot * 8)..<(slot * 8 + 8)) + [layout.slotCount * 8 + slot]
            scope.cacheUUID = root["CacheUUID"] as? String
            scope.cacheVersion = root["CacheVersion"] as? String
            scope.cacheLength = data.count
        } else {
            guard var extra = root["CacheExtra"] as? [String: Any] else { throw JapanRegionError.invalidMobileGestalt }
            let key = try identityKey(module, extra: extra)
            if module == .intelligence {
                if let original = extra[key] {
                    guard let number = original as? NSNumber,
                          ["c", "B", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
                          number == 0 || number == 1 else { throw RegionOperationError("AI capability must be absent or a canonical Boolean/integer 0 or 1.") }
                    extra[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? NSNumber(value: true) : NSNumber(value: 1)
                } else { extra[key] = NSNumber(value: 1) }
            } else {
                guard let old = extra[key] as? String, !old.isEmpty else { throw RegionOperationError("Existing field must be a nonempty String.") }
                switch module {
                case .regionCode: extra[key] = "J"
                case .regionInfo: extra[key] = "J/A"
                case .regulatoryModel:
                    guard let profile = JapanRegionProfile.verified(for: productType) else { throw JapanRegionError.unsupportedProductType(productType) }
                    extra[key] = profile.regulatoryModel
                default: throw RegionOperationError("Unsupported independent module.")
                }
            }
            scope.extraKeys = [key]
            root["CacheExtra"] = extra
        }
        let after = RegionPlist.equal(parsed.root, root) ? raw :
            try PropertyListSerialization.data(fromPropertyList: root, format: parsed.format, options: 0)
        try scope.validate(before: raw, after: after)
        return .init(file: .mobileGestalt, before: raw, after: after, scope: scope)
    }
}
