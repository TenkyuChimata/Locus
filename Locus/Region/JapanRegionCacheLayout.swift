// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// CacheUUID is a candidate descriptor-schema key, not a proven binary identity.
/// Its relationship to the descriptor table must be established in the binary.
/// A UUID may be registered only after its three question-to-slot mappings have
/// been audited against libMobileGestalt. Equal lengths or equal answers do not prove
/// that mapping: in particular green-tea and wapi can have identical values.
struct JapanRegionCacheLayout {
    struct BooleanField {
        let question: String
        let slot: Int
        let value: Bool
    }

    let size: Int
    let slotCount: Int
    let fields: [BooleanField]

    // Original recovered layout, retained without using its originating build
    // as authorization. Values are uint64 little-endian, followed by valid bytes.
    static let known1947 = JapanRegionCacheLayout(
        size: 0x1947, slotCount: 0x2CF,
        fields: [
            .init(question: "green-tea", slot: 0x17E, value: false),
            .init(question: "not-green-tea", slot: 0x1F9, value: true),
            .init(question: "wapi", slot: 0x2B5, value: false)
        ]
    )

    // The inherited source contains offsets but no CacheUUID or binary evidence.
    // Do not manufacture a fingerprint. Until a descriptor audit supplies one,
    // all persisted layouts are unknown and mutation fails closed, on every OS.
    // The reviewed registry now lives in RegionCacheMapping and binds the
    // binary UUID, build, CacheUUID, length and per-question descriptor evidence.

    /// Structural observations only. A plausible 8N + N layout never registers
    /// a schema or authorizes mutation; even its slot count remains a candidate.
    static func diagnostics(plist: [String: Any], build: String) -> [String: Any] {
        var result: [String: Any] = [
            "cacheUUIDType": plistType(plist["CacheUUID"]),
            "cacheVersionType": plistType(plist["CacheVersion"]),
            "cacheDataType": plistType(plist["CacheData"]),
            "cacheExtraType": plistType(plist["CacheExtra"]),
            "layoutSupported": false,
            "structuralStatus": "CacheData unavailable or wrong type"
        ]
        result["cacheUUID"] = plist["CacheUUID"] as? String ?? "<unavailable>"
        result["cacheUUIDValid"] = (plist["CacheUUID"] as? String)
            .flatMap { UUID(uuidString: $0) } != nil
        result["cacheVersion"] = plist["CacheVersion"] as? String ?? "<unavailable>"
        result["cacheVersionMatchesBuild"] = !build.isEmpty
            && (plist["CacheVersion"] as? String) == build
        if let data = plist["CacheData"] as? Data {
            result["cacheDataLength"] = data.count
            result["matchesHistoricalSize"] = data.count == known1947.size
            if !data.isEmpty && data.count.isMultiple(of: 9) {
                let count = data.count / 9
                let validity = data.dropFirst(count * 8)
                let canonical = validity.allSatisfy { $0 <= 1 }
                result["candidateSlotCount"] = count
                result["candidateValidityOffset"] = count * 8
                result["candidateValidCount"] = validity.filter { $0 == 1 }.count
                result["candidateValidityCanonical"] = canonical
                result["structuralStatus"] = canonical
                    ? "Consistent with uint64 LE slots + validity bytes; semantics unverified"
                    : "Candidate validity bytes contain values other than 0 or 1"
            } else {
                result["structuralStatus"] = "Length is not a positive multiple of 9"
            }
        }
        do {
            _ = try resolve(plist: plist, build: build)
            result["layoutSupported"] = true
            result["mutationStatus"] = "Reviewed schema and current cache validated"
        } catch {
            result["mutationStatus"] = error.localizedDescription
        }
        return result
    }

    private static func plistType(_ value: Any?) -> String {
        switch value {
        case nil: return "missing"
        case is String: return "String"
        case is Data: return "Data"
        case is [String: Any]: return "Dictionary"
        case is [Any]: return "Array"
        case is NSNumber: return "Number"
        case is Date: return "Date"
        default: return "unsupported"
        }
    }

    static func resolve(plist: [String: Any], build: String) throws -> Self {
        let assessments = RegionCacheMapping.assess(plist: plist, build: build,
            image: RegionCacheMapping.loadedImage(), writeAccess: false)
        if let data = plist["CacheData"] as? Data,
           assessments.count == RegionCacheQuestion.allCases.count,
           assessments.allSatisfy({ $0.status == .binaryVerified || $0.status == .writable }) {
            let layout = Self(size: data.count, slotCount: data.count / 9, fields: try assessments.map { item in
                guard let descriptor = item.descriptor else { throw JapanRegionError.unverifiedCacheSemantics }
                return .init(question: item.question.rawValue, slot: descriptor.slot, value: item.question.target)
            })
            try layout.validate(data)
            return layout
        }
        guard !build.isEmpty, plist["CacheVersion"] as? String == build else { throw JapanRegionError.staleCache }
        guard plist["CacheData"] is Data else { throw JapanRegionError.missingCacheData }
        throw JapanRegionError.unverifiedCacheSemantics
    }

    func validate(_ data: Data) throws {
        guard data.count == size else {
            throw JapanRegionError.unexpectedCacheDataSize(data.count)
        }
        guard size > 0, slotCount > 0, slotCount <= size / 9,
              slotCount * 9 == size else {
            throw JapanRegionError.invalidCachePatchLayout
        }
        let validBase = slotCount * MemoryLayout<UInt64>.size
        guard validBase + slotCount == size,
              Set(fields.map(\.slot)).count == fields.count,
              fields.allSatisfy({ (0..<slotCount).contains($0.slot) }),
              data[validBase..<size].allSatisfy({ $0 <= 1 }) else {
            throw JapanRegionError.invalidCachePatchLayout
        }
        for field in fields {
            let offset = field.slot * MemoryLayout<UInt64>.size
            // Only canonical booleans are accepted, including when invalid.
            guard data[offset] <= 1,
                  data[(offset + 1)..<(offset + 8)].allSatisfy({ $0 == 0 }) else {
                throw JapanRegionError.invalidCachePatchLayout
            }
        }
    }

    func applying(to original: Data) throws -> Data {
        try validate(original)
        var result = original
        for field in fields {
            let offset = field.slot * 8
            result.replaceSubrange(offset..<(offset + 8),
                                   with: [field.value ? 1 : 0] + [UInt8](repeating: 0, count: 7))
            result[slotCount * 8 + field.slot] = 1
        }
        // Independently enforce the entire write set, including unchanged slots.
        let allowed = Set(fields.flatMap { field in
            Array((field.slot * 8)..<(field.slot * 8 + 8)) + [slotCount * 8 + field.slot]
        })
        guard result.indices.allSatisfy({ result[$0] == original[$0] || allowed.contains($0) }) else {
            throw JapanRegionError.invalidCachePatchLayout
        }
        return result
    }

    func isApplied(to data: Data) -> Bool {
        guard (try? validate(data)) != nil else { return false }
        return fields.allSatisfy { field in
            data[field.slot * 8] == (field.value ? 1 : 0)
                && data[slotCount * 8 + field.slot] == 1
        }
    }
}
