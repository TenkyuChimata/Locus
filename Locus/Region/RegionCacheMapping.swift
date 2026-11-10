// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 huamidev
// Descriptor scanning adapted with independent evidence gates; see notices.
// Structural matches are observations, never binary semantic authorization.
import Foundation

nonisolated enum RegionCacheQuestion: String, CaseIterable, Codable, Sendable {
    case greenTea = "green-tea", notGreenTea = "not-green-tea", wapi
    var key: String {
        switch self {
        case .greenTea: return "iyfxmLogGVIaH7aEgqwcIA"
        case .notGreenTea: return "4snMZS8LJkSctKypt2m+xA"
        case .wapi: return "hiHut/WR+B9Lx/vd0WyeNg"
        }
    }
    var target: Bool { self == .notGreenTea }
}

enum CacheMappingStatus: String, Codable {
    case unavailable = "Unavailable", candidate = "Candidate"
    case structurallyValid = "Structurally Valid", binaryVerified = "Binary Verified", writable = "Writable"
}

struct CacheDescriptor: Equatable, Codable {
    let section: String
    let offset: Int
    let slot: Int
    let type: UInt32
}

struct CacheMappingAssessment {
    let question: RegionCacheQuestion
    let status: CacheMappingStatus
    let reason: String
    let descriptor: CacheDescriptor?
    let cacheValue: Bool?
    let valid: UInt8?
    let binding: CacheMappingBinding?
    var permitsMutation: Bool { status == .writable }
}

struct CacheMappingBinding: Equatable {
    let cacheUUID: String
    let version: String
    let byteCount: Int
}

/// Register only after independently tracing the UUID source, descriptor
/// consumer, type-11 representation, validity addressing and PAC/fixups in the
/// exact binary. A cstring UUID or matching runtime answers cannot supply this.
struct ReviewedCacheSchema {
    let binaryUUID: String
    let cacheUUID: String
    let build: String
    let byteCount: Int
    let descriptors: [RegionCacheQuestion: CacheDescriptor]
    let evidence: String
}

enum RegionCacheMapping {
    static let reviewed: [ReviewedCacheSchema] = []

    static func loadedImage() -> [String: Any] {
        #if os(iOS)
        return LocusCopyMobileGestaltImage()
        #else
        return ["error": "Loaded iOS MobileGestalt image is unavailable on this host."]
        #endif
    }

    static func assess(plist: [String: Any], build: String, image: [String: Any],
                       writeAccess: Bool, reviews: [ReviewedCacheSchema] = reviewed) -> [CacheMappingAssessment] {
        func all(_ status: CacheMappingStatus, _ reason: String) -> [CacheMappingAssessment] {
            RegionCacheQuestion.allCases.map {
                .init(question: $0, status: status, reason: reason, descriptor: nil, cacheValue: nil, valid: nil, binding: nil)
            }
        }
        guard let sections = image["sections"] as? [[String: Any]], sections.count <= 8,
              let binaryUUID = image["binaryUUID"] as? String, UUID(uuidString: binaryUUID) != nil else {
            return all(.unavailable, image["error"] as? String ?? "Missing image identity/sections.")
        }
        let stringsSections = sections.filter { $0["name"] as? String == "__TEXT.__cstring" }
        guard stringsSections.count == 1, let stringSection = stringsSections.first,
              let strings = stringSection["data"] as? Data, !strings.isEmpty, strings.count <= 32 * 1024 * 1024,
              let base = stringSection["address"] as? NSNumber,
              base.uint64Value <= UInt64.max - UInt64(strings.count), strings.last == 0 else {
            return all(.unavailable, "Missing, truncated or ambiguous cstring section.")
        }
        let allowedSections: Set<String> = ["__AUTH_CONST.__const", "__DATA_CONST.__const", "__DATA.__const"]
        let constants = sections.filter { allowedSections.contains($0["name"] as? String ?? "") }
        guard constants.contains(where: { (($0["data"] as? Data)?.count ?? 0) >= 64 }),
              Set(constants.compactMap { $0["name"] as? String }).count == constants.count,
              constants.allSatisfy({ section in
                  guard let data = section["data"] as? Data, let address = section["address"] as? NSNumber else { return false }
                  return !data.isEmpty && data.count <= 32 * 1024 * 1024 && address.uint64Value % 8 == 0
                      && address.uint64Value <= UInt64.max - UInt64(data.count)
              }) else { return all(.unavailable, "Invalid constant section bounds or duplicate section.") }
        var ranges: [Range<UInt64>] = []
        for section in [stringSection] + constants {
            let start = (section["address"] as! NSNumber).uint64Value
            let end = start + UInt64((section["data"] as! Data).count)
            let range = start..<end
            guard !ranges.contains(where: { $0.overlaps(range) }) else { return all(.unavailable, "Overlapping image sections.") }
            ranges.append(range)
        }
        var hashes: [UInt64: String] = [:]
        var hashCounts: [String: Int] = [:]
        var uuidOccurrences: [String] = []
        var start = 0
        let bytes = [UInt8](strings)
        for end in bytes.indices where bytes[end] == 0 {
            let token = bytes[start..<end]
            if token.count == 22 && token.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47
            }) {
                let key = String(decoding: token, as: UTF8.self)
                hashes[base.uint64Value + UInt64(start)] = key
                hashCounts[key, default: 0] += 1
            } else if token.count == 36, let text = String(bytes: token, encoding: .utf8), let uuid = UUID(uuidString: text) {
                uuidOccurrences.append(uuid.uuidString)
            }
            start = end + 1
        }
        var matches: [String: [CacheDescriptor]] = [:]
        var owners: [Int: Set<String>] = [:]
        for section in constants {
            let data = [UInt8](section["data"] as! Data)
            guard data.count >= 64 else { continue } // Bounded small constants cannot hold a descriptor.
            let name = section["name"] as! String
            for offset in stride(from: 0, through: data.count - 64, by: 8) {
                // PAC stripping is a candidate comparison only. Never dereference
                // this pointer and never equate a masked match with authentication.
                let pointer = little(data, offset, 8) & 0x0000_FFFF_FFFF_FFFF
                guard let key = hashes[pointer] else { continue }
                let slot = Int(Int16(bitPattern: UInt16(little(data, offset + 0x3A, 2))))
                let type = UInt32(little(data, offset + 0x3C, 4))
                matches[key, default: []].append(.init(section: name, offset: offset, slot: slot, type: type))
                // Conflicting descriptors count even if their type is unexpected.
                if slot >= 0 { owners[slot, default: []].insert(key) }
            }
        }
        let data = plist["CacheData"] as? Data
        let cacheUUID = (plist["CacheUUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
        let count = data.map { $0.count / 9 } ?? 0
        return RegionCacheQuestion.allCases.map { question in
            let candidates = matches[question.key] ?? []
            let descriptor = candidates.count == 1 ? candidates[0] : nil
            var status: CacheMappingStatus = .candidate
            var reason: String
            var value: Bool?
            var flag: UInt8?
            var binding: CacheMappingBinding?
            if hashCounts[question.key] != 1 {
                reason = "Question cstring is missing or duplicated."
            } else if candidates.count != 1 {
                reason = "Question has \(candidates.count) descriptor candidates; require exactly one."
            } else if let descriptor {
                if descriptor.type != 11 || descriptor.slot < 0 {
                    reason = "Descriptor type=\(descriptor.type), index=\(descriptor.slot); Boolean cached-slot hypothesis does not apply."
                } else if owners[descriptor.slot]?.count != 1 {
                    reason = "Different keys reference the same slot."
                } else if uuidOccurrences.count != 1 || cacheUUID == nil || uuidOccurrences.first != cacheUUID {
                    reason = "CacheUUID is missing, mismatched or not unique in cstrings; its source is unverified."
                } else if build.isEmpty || plist["CacheVersion"] as? String != build {
                    reason = "CacheVersion does not match the running build."
                } else if let data, !data.isEmpty, data.count.isMultiple(of: 9), count <= 16384,
                          descriptor.slot < count,
                          data.dropFirst(count * 8).allSatisfy({ $0 <= 1 }),
                          data[descriptor.slot * 8] <= 1,
                          data[(descriptor.slot * 8 + 1)..<(descriptor.slot * 8 + 8)].allSatisfy({ $0 == 0 }) {
                    value = data[descriptor.slot * 8] == 1
                    flag = data[count * 8 + descriptor.slot]
                    binding = .init(cacheUUID: cacheUUID!, version: build, byteCount: data.count)
                    status = .structurallyValid
                    reason = "64-byte/+0x3A/+0x3C hypothesis fits; UUID source and consumer instructions still require independent review."
                    let matching = reviews.filter {
                        $0.binaryUUID.uppercased() == binaryUUID.uppercased() && $0.cacheUUID.uppercased() == cacheUUID
                            && $0.build == build && $0.byteCount == data.count && $0.descriptors[question] == descriptor
                            && !$0.evidence.isEmpty
                    }
                    if matching.count == 1 {
                        status = .binaryVerified
                        reason = "Reviewed binary semantics: \(matching[0].evidence)."
                        if writeAccess { status = .writable }
                        else { reason += " Write access has not been established." }
                    }
                    if !(plist["CacheExtra"] is [String: Any]) {
                        status = .candidate
                        reason = "CacheExtra is missing or malformed; conflicting overrides cannot be excluded."
                    } else if let extra = plist["CacheExtra"] as? [String: Any], extra[question.key] != nil || extra[question.rawValue] != nil {
                        status = .candidate
                        reason = "A CacheExtra override conflicts with this CacheData question."
                    }
                } else {
                    reason = "CacheData length, slot bounds, Boolean representation or validity bytes are invalid."
                }
            } else { reason = "Descriptor unavailable." }
            return .init(question: question, status: status, reason: reason,
                         descriptor: descriptor, cacheValue: value, valid: flag, binding: binding)
        }
    }

    private static func little(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
    }

    static func layout(for question: RegionCacheQuestion, assessments: [CacheMappingAssessment],
                       plist: [String: Any]) throws -> JapanRegionCacheLayout {
        guard let item = assessments.first(where: { $0.question == question }),
              assessments.filter({ $0.question == question }).count == 1,
              item.permitsMutation, let descriptor = item.descriptor, let binding = item.binding,
              let uuid = (plist["CacheUUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString,
              binding.cacheUUID == uuid, binding.version == plist["CacheVersion"] as? String,
              let data = plist["CacheData"] as? Data, data.count == binding.byteCount,
              let extra = plist["CacheExtra"] as? [String: Any], extra[question.key] == nil, extra[question.rawValue] == nil else {
            throw JapanRegionError.unverifiedCacheSemantics
        }
        return .init(size: data.count, slotCount: data.count / 9,
                     fields: [.init(question: question.rawValue, slot: descriptor.slot, value: question.target)])
    }
}
