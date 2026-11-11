// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// This report has no relationship to ReviewedCacheSchema or mutation admission.
/// Native snapshots are private inputs; only the explicit allowlist below is exported.
enum MobileGestaltEvidenceCollector {
    enum CollectionMode: String {
        case passive = "passive-read-only"
        case authorized = "authorized-read-only"
    }
    static let stageIDs = ["authorization-requested", "authorization-result", "workspace-preparation",
        "authorized-path-resolution", "read-only-fd-open", "file-identity-validation", "first-full-read",
        "intermediate-metadata-check", "second-full-read", "final-metadata-check", "path-identity-revalidation",
        "authorization-release", "workspace-cleanup"]
    static let reasonCodes: Set<String> = ["not-executed", "unavailable", "user-not-confirmed", "user-confirmed",
        "workspace-refused", "workspace-prepared", "workspace-restored", "workspace-recovery-required",
        "library-preparation-failed", "token-release-failed", "token-released", "prior-token-release-failed",
        "prior-token-released", "lease-accounting-unavailable", "shared-reference-returned-token-retained",
        "lease-acquired-rights-not-introspected", "lease-not-acquired", "fixed-backing-path-selected-no-alias",
        "target-metadata-unavailable-or-unsupported", "app-group-unavailable", "query-create-failed",
        "query-rejected-or-token-unusable", "target-outside-scope", "signed-app-group-unavailable", "authorization-api-unavailable",
        "read-step-completed", "read-step-unavailable"]
    static let effectCodes: Set<String> = ["app-group-library-create-directory-attempt",
        "app-group-lock-opened-or-created-and-retained", "app-group-caches-directory-temporarily-renamed",
        "app-group-caches-symlink-created", "process-sandbox-token-consume-attempt"]
    struct Target {
        let name: String, hash: String
        let offset: Int, slot: Int, flags: UInt8
    }
    static let targets: [Target] = [
        .init(name: "green-tea", hash: "iyfxmLogGVIaH7aEgqwcIA", offset: 0xDCB0, slot: 383, flags: 0x19),
        .init(name: "not-green-tea", hash: "4snMZS8LJkSctKypt2m+xA", offset: 0x71F0, slot: 506, flags: 0x19),
        .init(name: "wapi", hash: "hiHut/WR+B9Lx/vd0WyeNg", offset: 0x12EB0, slot: 694, flags: 0x1C)
    ]
    static let binaryUUID = "9F28583A-0C54-304C-BE18-C12F593AC826"
    static let cacheUUID = "48CB1FAC-755B-435F-9A01-A20E5D810EA9"
    static let descriptorSection = "__AUTH_CONST.__const"
    static let tableOffset = 0x830, tableCount = 2323, recordSize = 64
    static let fileName = "Locus-MobileGestalt-RuntimeEvidence-24B119.json"
    static let null = NSNull()
    static let metadataKeys = ["device", "inode", "size", "mode", "uid", "gid", "links", "mtimeSeconds", "mtimeNanoseconds", "ctimeSeconds", "ctimeNanoseconds"]

    static func equalFileMetadata(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard lhs.count == rhs.count,
              metadataKeys.allSatisfy({ lhs[$0] is NSNumber && rhs[$0] is NSNumber }) else { return false }
        // Compare every field, including future numeric additions. On Linux,
        // NSDictionary.isEqual(to:) can report identical native Swift metadata
        // dictionaries as unequal. Do not discard fields or narrow stat values
        // to Double/Int in order to work around that bridge.
        return lhs.allSatisfy { key, value in
            guard let left = value as? NSNumber, let right = rhs[key] as? NSNumber else { return false }
            return left.compare(right) == .orderedSame
        }
    }

    static func json<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? null }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func collect(mode: CollectionMode = .passive, userConfirmed: Bool = false) -> [String: Any] {
        let start = Date()
        #if os(iOS)
        let allowed = mode == .passive || userConfirmed
        let device: [String: Any] = allowed ? LocusCopyEvidenceDeviceIdentity() : [:]
        let image: [String: Any] = allowed ? LocusCopyMobileGestaltImage() : [:] // Does not load or query MG.
        let cache = mode == .passive ? LocusCopyMobileGestaltEvidenceFile() :
            LocusCopyAuthorizedMobileGestaltEvidenceFile(userConfirmed)
        #else
        let device: [String: Any] = [:]
        let image: [String: Any] = ["error": "iOS loaded image unavailable on this host."]
        let cache: [String: Any] = ["stage": "host-unavailable"]
        #endif
        return assemble(device: device, image: image, file: cache, started: start, ended: Date(), mode: mode)
    }

    /// Native authorization dictionaries include private identities. Export only
    /// fixed enums, booleans, bounded errno and finite elapsed times.
    static func authorization(_ file: [String: Any], mode: CollectionMode) -> [String: Any] {
        let raw = mode == .authorized ? (file["authorization"] as? [String: Any] ?? [:]) : [:]
        let nativeEvents = (raw["events"] as? [[String: Any]] ?? []) + (file["readEvents"] as? [[String: Any]] ?? [])
        var stages: [[String: Any]] = nativeEvents.compactMap { event in
            guard let id = event["id"] as? String, stageIDs.contains(id) else { return nil }
            let status = event["status"] as? String ?? "INCOMPLETE"
            let reason = event["reason"] as? String ?? "unavailable"
            let effects = event["sideEffects"] as? String ?? "unknown"
            let duration = (event["elapsedMilliseconds"] as? NSNumber)?.doubleValue
            let error = (event["errno"] as? NSNumber)?.intValue
            return ["id": id, "status": ["PASS", "FAIL", "INCOMPLETE"].contains(status) ? status : "INCOMPLETE",
                "elapsedMilliseconds": json(duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }),
                "errno": json(error.flatMap { (1...4096).contains($0) ? $0 : nil }),
                "reason": reasonCodes.contains(reason) ? reason : "unavailable",
                "sideEffects": ["no", "yes", "possible", "unknown"].contains(effects) ? effects : "unknown"]
        }
        for id in stageIDs where !stages.contains(where: { $0["id"] as? String == id }) {
            stages.append(["id": id, "status": "INCOMPLETE", "elapsedMilliseconds": null, "errno": null,
                "reason": "not-executed", "sideEffects": "no"])
        }
        let effects = raw["sideEffects"] as? [String] ?? []
        let attempts: [[String: Any]] = (raw["attempts"] as? [[String: Any]] ?? []).prefix(2).compactMap { attempt in
            guard let variant = attempt["variant"] as? Int, (1...2).contains(variant) else { return nil }
            let duration = (attempt["elapsedMilliseconds"] as? NSNumber)?.doubleValue
            let error = (attempt["errno"] as? NSNumber)?.intValue
            return ["variant": variant, "resultReturned": json(attempt["resultReturned"] as? Bool),
                "tokenIssued": json(attempt["tokenIssued"] as? Bool), "consumed": json(attempt["consumed"] as? Bool),
                "errno": json(error.flatMap { (1...4096).contains($0) ? $0 : nil }),
                "elapsedMilliseconds": json(duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })]
        }
        return ["requested": mode == .authorized && raw["requested"] as? Bool == true,
            "mechanism": mode == .authorized ? "existing-worse-query-app-group-part-lease" : "none",
            "granted": json(raw["granted"] as? Bool),
            "scope": mode == .authorized ? "Requested existing MobileGestalt cache directory; process-wide token rights not introspected or restricted to read-only." : "No authorization requested by this collection.",
            "grantReused": json(raw["grantReused"] as? Bool),
            "referenceReleased": json(raw["referenceReleased"] as? Bool), "tokenRevoked": json(raw["tokenRevoked"] as? Bool),
            "otherLeaseHoldersRemain": json(raw["otherLeaseHoldersRemain"] as? Bool),
            "cleanupSucceeded": json(raw["cleanupSucceeded"] as? Bool),
            "cleanupScope": "Restore temporary App Group Caches link/directory only; Library and lock file may remain. Tokens remain active while other lease holders remain.",
            "sideEffects": Array(Set(effects.filter { effectCodes.contains($0) })).sorted(), "attempts": attempts, "stages": stages]
    }

    /// Only a sandbox temporary directory is ever written by this component.
    /// Writer injection exercises actual serialization and failure propagation.
    static func export(_ report: [String: Any], directory: URL = FileManager.default.temporaryDirectory,
                       write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws -> URL {
        guard JSONSerialization.isValidJSONObject(report) else {
            throw NSError(domain: "Locus.RuntimeEvidence", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Evidence contains a non-JSON value."])
        }
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let folder = directory.appendingPathComponent("Locus-Evidence-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let url = folder.appendingPathComponent(fileName)
        do { try write(bytes, url) }
        catch {
            let writeError = error
            do { try FileManager.default.removeItem(at: folder) }
            catch {
                throw NSError(domain: "Locus.RuntimeEvidence", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Export failed: \(writeError.localizedDescription); temporary report cleanup also failed: \(error.localizedDescription)"])
            }
            throw writeError
        }
        return url
    }

    static func little(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> UInt64 {
        (0..<width).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }

    static func kind(_ value: Any?) -> String {
        guard let value else { return "missing" }
        if value is Data { return "data" }
        if value is String { return "string" }
        if value is [String: Any] { return "dictionary" }
        if value is [Any] { return "array" }
        if value is NSNumber { return "number" }
        return "unsupported"
    }

    static func assemble(device: [String: Any], image: [String: Any], file: [String: Any],
                         started: Date, ended: Date, mode: CollectionMode = .passive) -> [String: Any] {
        var checks: [[String: Any]] = []
        // nil means unobservable, false means a concrete mismatch.
        func check(_ id: String, _ result: Bool?, _ detail: String) {
            checks.append(["id": id, "status": result.map { $0 ? "PASS" : "FAIL" } ?? "INCOMPLETE", "detail": detail])
        }
        func summary(_ selected: [[String: Any]]) -> String {
            if selected.contains(where: { $0["status"] as? String == "FAIL" }) { return "FAIL" }
            return !selected.isEmpty && selected.allSatisfy { $0["status"] as? String == "PASS" } ? "PASS" : "INCOMPLETE"
        }
        func identity(_ field: String, _ expected: String) {
            let actual = device[field] as? String
            check("device." + field, actual.flatMap { $0.isEmpty ? nil : $0 == expected },
                  "Expected \(expected); source: hw.machine / kern.osversion / NSProcessInfo. Missing identity is unavailable.")
        }
        identity("productType", "iPhone18,3")
        identity("systemVersion", "27.2")
        identity("build", "24B119")
        check("image.uuid", (image["binaryUUID"] as? String).map { $0.uppercased() == binaryUUID },
              image["error"] as? String ?? "Exact previously reviewed LC_UUID required.")
        check("image.path", (image["path"] as? String).map { $0 == "/usr/lib/libMobileGestalt.dylib" },
              "Exact system library path, reported publicly as a normalized category.")
        let cpu = image["cpuType"] as? NSNumber, subtype = image["cpuSubtype"] as? NSNumber
        check("image.architecture", cpu.flatMap { c in subtype.map { c.uint32Value == 0x0100000C && $0.uint32Value & 0x00FF_FFFF == 2 } },
              "Require arm64e; subtype capability bits are excluded only for CPU classification.")
        let sourceOK = image["source"] as? String == "current process loaded image" &&
            image["pointerRepresentation"] as? String == "dyld-resolved key addresses" && image["error"] == nil
        check("image.loadedSource", sourceOK ? true : nil, "Observe the current process only; never load a missing library.")
        let reviewApplicability = summary(checks)
        let loadedIdentity = summary(checks.filter { ($0["id"] as? String)?.hasPrefix("image.") == true })

        let sections = image["sections"] as? [[String: Any]] ?? []
        let allowed = Set(["__TEXT.__cstring", descriptorSection, "__DATA_CONST.__const", "__DATA.__const"])
        var ranges: [Range<UInt64>] = []
        var sectionOK = !sections.isEmpty && sections.count <= 8
        for section in sections {
            guard let name = section["name"] as? String, allowed.contains(name),
                  let address = section["address"] as? NSNumber, let data = section["data"] as? Data,
                  !data.isEmpty, data.count <= 32 * 1024 * 1024, address.uint64Value > 0,
                  address.uint64Value <= UInt64.max - UInt64(data.count) else { sectionOK = false; continue }
            let range = address.uint64Value..<(address.uint64Value + UInt64(data.count))
            if ranges.contains(where: { $0.overlaps(range) }) { sectionOK = false }
            ranges.append(range)
        }
        if Set(sections.compactMap { $0["name"] as? String }).count != sections.count { sectionOK = false }
        let stringSections = sections.filter { $0["name"] as? String == "__TEXT.__cstring" }
        let constantSections = sections.filter { $0["name"] as? String == descriptorSection }
        let strings = stringSections.first?["data"] as? Data
        let constants = constantSections.first?["data"] as? Data
        sectionOK = sectionOK && stringSections.count == 1 && constantSections.count == 1 && strings?.last == 0
        check("descriptors.sections", sections.isEmpty ? nil : sectionOK,
              "Require unique bounded readable cstring and AUTH_CONST sections with no overlap.")
        check("descriptors.loadedSource", sourceOK ? true : nil,
              "Descriptor observations require a checked current-process snapshot, not bytes from a file.")
        let stringBase = (stringSections.first?["address"] as? NSNumber)?.uint64Value ?? 0
        var tokens: [UInt64: String] = [:], tokenOffsets: [String: [Int]] = [:]
        if sectionOK, let strings {
            let bytes = [UInt8](strings)
            var start = 0
            for end in bytes.indices where bytes[end] == 0 {
                let token = bytes[start..<end]
                if token.count == 22 && token.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47
                }) {
                    let text = String(decoding: token, as: UTF8.self)
                    tokens[stringBase + UInt64(start)] = text
                    tokenOffsets[text, default: []].append(start)
                }
                start = end + 1
            }
        }
        let bytes = [UInt8](constants ?? Data())
        var matches: [String: [Int]] = [:], owners: [Int: [Int]] = [:]
        let tableReadable = sectionOK && bytes.count >= tableOffset + tableCount * recordSize
        var allKeysResolved = tableReadable
        var populated = 0
        if tableReadable {
            for ordinal in 0..<tableCount {
                let offset = tableOffset + ordinal * recordSize
                let pointer = little(bytes, offset, 8)
                if pointer == 0 { continue }
                populated += 1
                let slot = Int(Int16(bitPattern: UInt16(little(bytes, offset + 0x3A, 2))))
                if slot >= 0 { owners[slot, default: []].append(offset) }
                if slot >= 720 { allKeysResolved = false }
                if let key = tokens[pointer] { matches[key, default: []].append(offset) }
                else { allKeysResolved = false }
            }
        }
        check("descriptors.tableCoverage", tableReadable ? (allKeysResolved ? true : nil) : nil,
              "Exact offline table: section +0x830, 2323 records × 64. Every populated ordinary Key pointer must resolve without masking; no callback is executed.")
        var descriptors: [[String: Any]] = []
        for target in targets {
            let offsets = tokenOffsets[target.hash] ?? []
            let readable = sectionOK && target.offset <= bytes.count && bytes.count - target.offset >= 64
            var item: [String: Any] = ["key": target.name, "hash": target.hash, "section": descriptorSection,
                "sectionOffset": target.offset, "read64Bytes": readable, "hashCStringOffsets": offsets,
                "descriptorMatchOffsets": matches[target.hash] ?? [],
                "runtimeKeyPointerResolved": null, "runtimePointerComparisonPassed": null,
                "resolvedKeyHash": null, "resolvedCStringOffset": null,
                "slot": null, "type": null, "flags": null, "slotOwnerOffsets": [],
                "callbackPointerTargetDecodedOffline": "Previously reviewed exact binary only; not decoded from runtime PAC pointer",
                "callbackPACAuthenticationVerified": "Not Verified"]
            check("descriptors.\(target.name).read", readable ? true : nil, "Full 64 bytes must lie inside the observed section.")
            check("descriptors.\(target.name).uniqueHash", sectionOK ? offsets.count == 1 : nil, "Hash must be a unique complete cstring token.")
            if readable {
                let pointer = little(bytes, target.offset, 8) // Full 64-bit ordinary Key address, never stripped/masked.
                let resolved = tokens[pointer]
                let slot = Int(Int16(bitPattern: UInt16(little(bytes, target.offset + 0x3A, 2))))
                let type = little(bytes, target.offset + 0x3C, 4), flags = bytes[target.offset + 0x38]
                item["slot"] = slot; item["type"] = type; item["flags"] = Int(flags)
                item["slotOwnerOffsets"] = owners[slot] ?? []
                item["runtimeKeyPointerResolved"] = resolved != nil
                item["resolvedKeyHash"] = json(resolved) // Only a complete 22-byte hash token from this image.
                let exact = offsets.count == 1 && pointer == stringBase + UInt64(offsets[0])
                item["runtimePointerComparisonPassed"] = exact
                if exact { item["resolvedCStringOffset"] = offsets[0] }
                check("descriptors.\(target.name).pointer", resolved == nil ? nil : exact,
                      "Unresolved pointer is INCOMPLETE; another known string is FAIL. No high-bit removal, file-pointer decoding or PAC authentication.")
                check("descriptors.\(target.name).fields", slot == target.slot && slot >= 0 && slot < 720 && type == 11 && flags == target.flags,
                      "Require exact signed slot \(target.slot), type 11 and flags \(target.flags); nearby indices are not equivalent.")
                let candidates = matches[target.hash] ?? []
                let unique: Bool? = !tableReadable ? nil :
                    (candidates.count > 1 || candidates.contains(where: { $0 != target.offset }) ? false :
                        (allKeysResolved ? candidates == [target.offset] : nil))
                check("descriptors.\(target.name).uniqueDescriptor", unique,
                      "The complete table must reference the target exactly once at the reviewed offset.")
                check("descriptors.\(target.name).slotOwnership", tableReadable ? owners[slot] == [target.offset] : nil,
                      "No second populated descriptor may claim the same slot, including unresolved keys.")
            } else {
                for suffix in ["pointer", "fields", "uniqueDescriptor", "slotOwnership"] {
                    check("descriptors.\(target.name)." + suffix, nil, "Descriptor unreadable or section invalid.")
                }
            }
            descriptors.append(item)
        }
        let descriptorSummary = summary(checks.filter { ($0["id"] as? String)?.hasPrefix("descriptors.") == true })

        let publicAuthorization = authorization(file, mode: mode)
        if mode == .authorized {
            let stages = publicAuthorization["stages"] as? [[String: Any]] ?? []
            let reused = publicAuthorization["grantReused"] as? Bool == true
            let required = Set(stageIDs.filter { !reused || !["workspace-preparation", "workspace-cleanup"].contains($0) })
            let allStagesPass = required.allSatisfy { id in
                let observations = stages.filter { $0["id"] as? String == id }
                return !observations.isEmpty && observations.allSatisfy {
                    $0["status"] as? String == "PASS" && $0["elapsedMilliseconds"] is NSNumber && $0["errno"] is NSNull &&
                        !["unavailable", "not-executed"].contains($0["reason"] as? String ?? "unavailable")
                }
            }
            let observedFailure = stages.contains { $0["status"] as? String == "FAIL" }
            let ready = publicAuthorization["requested"] as? Bool == true && publicAuthorization["granted"] as? Bool == true &&
                publicAuthorization["referenceReleased"] as? Bool == true &&
                (publicAuthorization["tokenRevoked"] as? Bool == true || publicAuthorization["otherLeaseHoldersRemain"] as? Bool == true) &&
                (reused || publicAuthorization["cleanupSucceeded"] as? Bool == true) && allStagesPass
            check("authorization.lifecycle", ready ? true : (observedFailure ? false : nil),
                "Explicit confirmation, usable lease, checked direct-path reads, reference release and any workspace restoration required. Shared tokens may remain active; rights are not read-only scoped.")
        }

        let first = file["first"] as? Data, second = file["second"] as? Data
        let firstHash = first.map { RegionBackupDigest.sha256($0) }
        let secondHash = second.map { RegionBackupDigest.sha256($0) }
        let metadata = ["before", "between", "after", "namedAfter"].compactMap { file[$0] as? [String: Any] }
        let metadataComplete = metadata.count == 4 && metadata.allSatisfy { m in metadataKeys.allSatisfy { m[$0] is NSNumber } }
        let metadataEqual = metadataComplete && metadata.dropFirst().allSatisfy { equalFileMetadata($0, metadata[0]) }
        let readError = (file["errno"] as? NSNumber)?.intValue
        let stable = first != nil && first == second && firstHash == secondHash && metadataEqual &&
            file["stable"] as? Bool == true && readError == 0
        let observedChange = readError == Int(POSIXErrorCode.EBUSY.rawValue) || readError == Int(POSIXErrorCode.ESTALE.rawValue) ||
            (first != nil && second != nil && (first != second || (metadataComplete && !metadataEqual)))
        check("cache.stableFile", stable ? true : (observedChange ? false : nil),
              "Two complete reads on one O_RDONLY fd plus before/between/after metadata and path re-open. This is not an atomic cross-process snapshot. Stage: \(file["stage"] as? String ?? "unavailable"); errno: \(readError.map(String.init) ?? "unavailable").")
        var plist: [String: Any]?
        var parseError: String?
        if let first {
            do {
                let root = try PropertyListSerialization.propertyList(from: first, options: [], format: nil)
                plist = root as? [String: Any]
                if plist == nil { parseError = "Plist root is not a dictionary." }
            } catch { parseError = "PropertyListSerialization failed (\((error as NSError).domain), \((error as NSError).code))." }
        }
        check("cache.plist", first == nil ? nil : plist != nil, parseError ?? "Parse only the first complete raw read, never a separate path read.")
        let uuid = plist?["CacheUUID"] as? String, version = plist?["CacheVersion"] as? String
        check("cache.uuid", plist.map { _ in uuid?.uppercased() == cacheUUID }, "Require the exact offline producer/loader CacheUUID.")
        check("cache.version", plist.map { _ in version == "24B119" }, "CacheVersion must equal the exact reviewed build.")
        let data = plist?["CacheData"] as? Data, extra = plist?["CacheExtra"] as? [String: Any]
        let layout = data?.count == 6480
        let canonicalValidity = data.map { layout && $0.dropFirst(5760).allSatisfy { $0 <= 1 } }
        check("cache.layout", plist.map { _ in layout }, "Require data type and exactly 720×8 + 720 = 6480 bytes; validity base 5760.")
        check("cache.validityBytes", canonicalValidity, "All 720 validity bytes must be canonical 0/1.")
        check("cache.extraType", plist.map { _ in extra != nil }, "A dictionary is required to exclude overrides; values are never exported.")
        var slots: [[String: Any]] = []
        for target in targets {
            let override = extra.map { $0[target.hash] != nil || $0[target.name] != nil }
            var slot: [String: Any] = ["key": target.name, "slot": target.slot, "typeFromOfflineDescriptor": 11,
                "flagsFromOfflineDescriptor": Int(target.flags), "valueOffset": target.slot * 8,
                "validityOffset": 5760 + target.slot, "valueByte": null, "highSevenBytesZero": null,
                "booleanCanonical": null, "validityByte": null, "cacheExtraOverride": json(override)]
            check("cache.\(target.name).noOverride", override.map { !$0 }, "Check both hash and logical-name CacheExtra entries.")
            if layout, let data {
                let offset = target.slot * 8, value = data[offset], valid = data[5760 + target.slot]
                let highZero = data[(offset + 1)..<(offset + 8)].allSatisfy { $0 == 0 }
                slot["valueByte"] = Int(value); slot["validityByte"] = Int(valid)
                slot["highSevenBytesZero"] = highZero; slot["booleanCanonical"] = value <= 1
                check("cache.\(target.name).boolean", value <= 1 && highZero, "Canonical representation only; either true or false is acceptable, regardless of Locus target.")
                check("cache.\(target.name).valid", valid > 1 ? false : (valid == 1 ? true : nil), "0 is canonical but unavailable as an active cached answer; 1 is valid; >1 is FAIL.")
            } else {
                check("cache.\(target.name).boolean", nil, "Exact CacheData layout unavailable.")
                check("cache.\(target.name).valid", nil, "Exact CacheData layout unavailable.")
            }
            slots.append(slot)
        }
        let cacheSummary = summary(checks.filter { ($0["id"] as? String)?.hasPrefix("cache.") == true })
        let binding = summary(checks)
        let publicSections: [[String: Any]] = sections.compactMap { section in
            guard let name = section["name"] as? String, allowed.contains(name) else { return nil }
            return ["name": name, "byteCount": json((section["data"] as? Data)?.count)]
        }
        // Exact allowlist. Native dictionaries are never serialized wholesale.
        let publicDevice: [String: Any] = [
            "productType": json(device["productType"] as? String),
            "systemVersion": json(device["systemVersion"] as? String),
            "build": json(device["build"] as? String), "processIdentifier": "redacted",
            "identitySource": "hw.machine / kern.osversion / NSProcessInfo"]
        let publicImage: [String: Any] = [
            "lcUUID": json(image["binaryUUID"] as? String),
            "cpuType": json(cpu), "cpuSubtype": json(subtype),
            "pathClass": image["path"] as? String == "/usr/lib/libMobileGestalt.dylib" ? "system-library-MobileGestalt" : "unavailable",
            "slide": "redacted", "sectionRuntimeAddresses": "redacted", "sections": publicSections,
            "descriptorTable": ["sectionOffset": tableOffset, "recordCount": tableCount, "recordSize": recordSize,
                "populatedRecords": tableReadable ? populated as Any : null,
                "allPopulatedKeysResolved": tableReadable ? allKeysResolved as Any : null,
                "cachedSlotOwnerCount": tableReadable ? owners.count as Any : null],
            "error": json(image["error"] as? String)]
        // Wrong build strings are included only when they have Apple's build-number shape.
        let safeVersion = version.flatMap { $0.range(of: "^[0-9]{2}[A-Z][0-9]{1,5}[a-z]?$", options: .regularExpression) != nil ? $0 : nil }
        let publicCache: [String: Any] = [
            "sourceClass": "system-MobileGestalt-backing-plist", "stableAcrossObservedReads": stable,
            "readStage": json(file["stage"] as? String), "errno": json(readError),
            "failedPathComponentOrdinal": json((file["failedComponent"] as? NSNumber)?.uintValue),
            "readErrorDescription": json(readError.flatMap { $0 == 0 ? nil : NSError(domain: NSPOSIXErrorDomain, code: $0).localizedDescription }),
            "rawFileSHA256": json(firstHash), "secondReadSHA256": json(secondHash),
            "rawFileByteCount": json(first?.count),
            "metadataEqual": metadataComplete ? metadataEqual as Any : null,
            "metadata": "device/inode/uid/gid/timestamps redacted; full metadata compared privately",
            "cacheUUID": json(uuid.flatMap { UUID(uuidString: $0)?.uuidString }),
            "cacheUUIDType": kind(plist?["CacheUUID"]), "cacheVersionType": kind(plist?["CacheVersion"]),
            "cacheVersion": json(safeVersion),
            "cacheDataType": kind(plist?["CacheData"]), "cacheExtraType": kind(plist?["CacheExtra"]),
            "cacheDataByteCount": json(data?.count), "cacheDataSHA256": json(data.map { RegionBackupDigest.sha256($0) }),
            "slotCount": layout ? 720 as Any : null, "validityBase": layout ? 5760 as Any : null,
            "allValidityBytesCanonical": json(canonicalValidity), "slots": slots,
            "parseError": json(parseError)]
        let assessment: [String: Any] = [
            "offlineBinaryMapping": "PASS", "offlineBinaryMappingBasis":
                "Prior exact-binary review: docs/20261110-mobilegestalt-24B119-binary-review.md and docs/evidence/mobilegestalt-24B119.json; NOT re-executed by this collector.",
            "offlineBinarySHA256": "d5b2c93693db10cfb47574b4a9555c4c5affc5309b5f15101066dfd02308c9f7",
            "offlineReviewApplicability": reviewApplicability, "loadedImageIdentity": loadedIdentity, "runtimeDescriptorMapping": descriptorSummary,
            "cacheInstanceConsistency": cacheSummary, "runtimeBinding": binding,
            "runtimeBindingScope": "Observed loaded ordinary-Key descriptors and persisted cache only; no in-memory answer provenance, atomicity or callback PAC proof.",
            "independentReview": "Pending independent review of this report", "callbackPACAuthentication": "Not Verified",
            "safeMutationAuthorization": "NO-GO"]
        return ["schemaVersion": 2, "collectionMode": mode.rawValue, "redacted": true,
            "collectedAt": timestamp(started), "collectionStartedAt": timestamp(started), "collectionEndedAt": timestamp(ended),
            "device": publicDevice, "loadedImage": publicImage, "descriptors": descriptors,
            "cacheInstance": publicCache, "authorization": publicAuthorization, "checks": checks, "assessment": assessment,
            "limitations": ["No MG answers are queried; earlier ordinary Refresh may already have initialized MG.",
                "Two equal reads cannot exclude ABA changes, later changes or prove the process uses this persisted cache.",
                "Passive collection requests no lease but may inherit existing process grants. Authorized collection can create App Group state and consume a process-wide token with unverified rights.",
                "PASS applies only to the listed observations; it never registers a writable schema."]]
    }
}
