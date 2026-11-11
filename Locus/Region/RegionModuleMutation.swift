// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

nonisolated enum RegionModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case regionCode, regionInfo, regulatoryModel, greenTea, notGreenTea, wapi, fullJapan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .regionCode: return "RegionCode"
        case .regionInfo: return "RegionInfo"
        case .regulatoryModel: return "RegulatoryModelNumber"
        case .greenTea: return "green-tea"
        case .notGreenTea: return "not-green-tea"
        case .wapi: return "wapi"
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

nonisolated enum RegionFile: String, Codable, Sendable { case mobileGestalt }

nonisolated struct RegionPatchScope: Codable, Equatable, Sendable {
    var extraKeys: [String] = []
    var rootKeys: [String] = [] // Decode v1 metadata; never authorizes a current write.
    var byteOffsets: [Int] = []
    var cacheUUID: String?
    var cacheVersion: String?
    var cacheLength: Int?
    var layoutBinding: RegionLayoutBinding?

    func validate(before: Data, after: Data) throws {
        guard rootKeys.isEmpty else { throw RegionOperationError("Root-key mutations are no longer supported.") }
        let a = try RegionPlist.parse(before).root
        let b = try RegionPlist.parse(after).root
        let allowedRoots = Set((extraKeys.isEmpty ? [] : ["CacheExtra"]) + (byteOffsets.isEmpty ? [] : ["CacheData"]))
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
            if let binding = layoutBinding {
                guard binding.format == "arm64-mg64-v1", binding.cacheUUID == cacheUUID.flatMap(UUID.init(uuidString:))?.uuidString,
                      UUID(uuidString: binding.imageUUID) != nil,
                      (1...16384).contains(binding.slotCount), cacheLength == binding.slotCount * 9,
                      binding.descriptors.allSatisfy({ (0..<binding.slotCount).contains($0.slot) && $0.type == 11 }),
                      Set(binding.descriptors.map { $0.slot * 8 }) == Set(byteOffsets),
                      binding.descriptors.count == byteOffsets.count else {
                    throw RegionOperationError("Dynamic scope binding differs from its target offsets/identity.")
                }
            }
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
        let before = try RegionPlist.parse(original).root
        let expected = try RegionPlist.parse(applied).root
        let parsed = try RegionPlist.parse(current)
        for key in ["CacheUUID", "CacheVersion"] {
            guard RegionPlist.equal(before[key], parsed.root[key]) else {
                throw RegionOperationError("Backup cache identity differs from the current cache; restore refused.")
            }
        }
        let oldExtra = before["CacheExtra"] as? [String: Any] ?? [:]
        let liveExtra = parsed.root["CacheExtra"] as? [String: Any] ?? [:]
        for key in ["re6Zb+zwFKJNlkQTUeT+/w", "VasUgeSzVyHdB27g2XpN0g"] {
            guard RegionPlist.equal(oldExtra[key], liveExtra[key]) else {
                throw RegionOperationError("Backup device identity differs from the current cache.")
            }
        }
        if current == original { return current }
        if current == applied { return original }
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
        var rows: [String] = []
        guard let a = try? RegionPlist.parse(before).root, let b = try? RegionPlist.parse(after).root else { return rows }
        func display(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "<absent>" }
        let ea = a["CacheExtra"] as? [String:Any] ?? [:], eb = b["CacheExtra"] as? [String:Any] ?? [:]
        rows += scope.extraKeys.map { "CacheExtra \($0): \(display(ea[$0])) → \(display(eb[$0]))" }
        if let da = a["CacheData"] as? Data, let db = b["CacheData"] as? Data {
            let slots = da.count / 9
            rows += scope.byteOffsets.filter { $0 < slots * 8 && $0.isMultiple(of: 8) && db.indices.contains($0) }
                .map { offset in
                    let name = scope.layoutBinding?.descriptors.first(where: { $0.slot * 8 == offset })
                        .flatMap { descriptor in RegionCacheQuestion.allCases.first(where: { $0.key == descriptor.key })?.rawValue }
                        ?? RegionCacheMapping.question(atValueOffset: offset)?.rawValue ?? "CacheData[\(offset)]"
                    return "\(name): \(da[offset] == 1) → \(db[offset] == 1)"
                }
        }
        return rows
    }
}

enum RegionModuleMutation {
    static let regionInfoKeys = ["yK+xavymRGZ3xWc1tb8XDg", "zHeENZu+wbg7PUprwNwBWg"]
    static func validateSource(_ root: [String: Any], productType: String, build: String) throws {
        if !build.isEmpty, root["CacheVersion"] as? String != build { throw JapanRegionError.staleCache }
        if let cached = (root["CacheExtra"] as? [String: Any])?["0+nc/Udy4WNG8S+Q7a/s1A"] {
            guard let cached = cached as? String,
                  cached.split(separator: "-", maxSplits: 1).first == productType.split(separator: "-", maxSplits: 1).first,
                  !productType.isEmpty else { throw RegionOperationError("Cached ProductType differs from the running device.") }
        }
    }
    static func identityKey(_ module: RegionModule, extra: [String: Any]) throws -> String {
        switch module {
        case .regionCode: return JapanRegionMutation.regionCodeKey
        case .regulatoryModel: return JapanRegionMutation.regulatoryModelKey
        case .regionInfo:
            let existing = regionInfoKeys.filter { extra[$0] != nil }
            guard existing.count == 1 else {
                throw RegionOperationError("Require exactly one existing supported RegionInfo field. The two keys are distinct RegionInfoFromSysconfig and RegionInfo queries; missing or dual fields require semantic review.")
            }
            return existing[0]
        default: throw RegionOperationError("Not a region identity field.")
        }
    }

    static func plan(module: RegionModule, raw: Data, productType: String,
                     build: String = "", runtime: RegionLayoutResolution = .current()) throws -> RegionWritePlan {
        let parsed = try RegionPlist.parse(raw)
        var root = parsed.root
        try validateSource(root, productType: productType, build: build)
        var scope = RegionPatchScope()
        if module == .fullJapan {
            guard let profile = JapanRegionProfile.verified(for: productType) else {
                throw JapanRegionError.unsupportedProductType(productType)
            }
            root = try JapanRegionMutation.applying(to: parsed.root, profile: profile, build: build, runtime: runtime)
            let layout = try JapanRegionCacheLayout.resolve(plist: parsed.root, build: build, productType: productType, runtime: runtime)
            let extra = parsed.root["CacheExtra"] as! [String: Any]
            scope = RegionPatchScope(extraKeys: [JapanRegionMutation.regionCodeKey,
                try identityKey(.regionInfo, extra: extra), JapanRegionMutation.regulatoryModelKey],
                byteOffsets: layout.fields.map { $0.slot * 8 }, cacheUUID: root["CacheUUID"] as? String,
                cacheVersion: root["CacheVersion"] as? String, cacheLength: layout.size, layoutBinding: layout.binding)
        } else if let question = module.question {
            guard let data = root["CacheData"] as? Data else { throw JapanRegionError.missingCacheData }
            let layout = try RegionCacheMapping.layout(plist: root, build: build, productType: productType, questions: [question], runtime: runtime)
            root["CacheData"] = try layout.applying(to: data)
            let slot = layout.fields[0].slot
            scope.byteOffsets = [slot * 8]
            scope.cacheUUID = root["CacheUUID"] as? String
            scope.cacheVersion = root["CacheVersion"] as? String
            scope.cacheLength = data.count
            scope.layoutBinding = layout.binding
        } else {
            guard var extra = root["CacheExtra"] as? [String: Any] else { throw JapanRegionError.invalidMobileGestalt }
            let key = try identityKey(module, extra: extra)
            guard let old = extra[key] as? String, !old.isEmpty else { throw RegionOperationError("Existing field must be a nonempty String.") }
            switch module {
            case .regionCode: extra[key] = "J"
            case .regionInfo: extra[key] = "J/A"
            case .regulatoryModel:
                guard let profile = JapanRegionProfile.verified(for: productType) else { throw JapanRegionError.unsupportedProductType(productType) }
                extra[key] = profile.regulatoryModel
            default: throw RegionOperationError("Unsupported independent module.")
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
