// SPDX-License-Identifier: GPL-3.0-only
// Descriptor idea: GestaltX, Copyright (C) 2026 huamidev. See notices.
import Foundation

nonisolated struct RegionDescriptor: Codable, Equatable, Sendable {
    let key: String
    let slot: Int
    let type: Int
    let flags: Int
}

/// Persist identities and semantics, never live addresses or PAC words.
nonisolated struct RegionLayoutBinding: Codable, Equatable, Sendable {
    let format: String
    let imageUUID: String
    let cacheUUID: String
    let slotCount: Int
    let descriptors: [RegionDescriptor]
}

nonisolated enum RegionLayoutResolution {
    case unavailable(String)
    case rejected(String)
    case resolved(MobileGestaltRuntimeLayout)

    static func current() -> Self {
        #if os(iOS) && !targetEnvironment(simulator)
        do {
            let snapshot = try MobileGestaltImage.snapshot()
            do { return .resolved(try MobileGestaltRuntimeLayout.scan(snapshot)) }
            catch { return .rejected(error.localizedDescription) }
        } catch { return .unavailable(error.localizedDescription) }
        #else
        return .unavailable("Dynamic layout requires a loaded iOS device image.")
        #endif
    }
}

/// One reviewed ARM64 format, not a generic reverse-engineering framework.
/// All addresses below refer to copied, dyld-relocated sections of THIS image.
/// A different compiler/code/descriptor format is rejected, irrespective of OS.
nonisolated struct MobileGestaltRuntimeLayout {
    let imageUUID: String
    let cacheUUID: String
    let slotCount: Int
    private let descriptors: [String: [RegionDescriptor]]

    func binding(for questions: [RegionCacheQuestion]) throws -> RegionLayoutBinding {
        let selected = try questions.map { question -> RegionDescriptor in
            guard let hits = descriptors[question.key], hits.count == 1 else {
                throw RegionOperationError("\(question.rawValue): descriptor missing or duplicated.")
            }
            let hit = hits[0]
            let flags = question == .wapi ? 0x1C : 0x19
            guard hit.type == 11, hit.flags == flags, (0..<slotCount).contains(hit.slot) else {
                throw RegionOperationError("\(question.rawValue): descriptor type, flags or index not verified.")
            }
            // Reject aliasing even with a nontarget descriptor, not only among
            // the selected fields. A missing independent question is harmless.
            let owners = descriptors.values.flatMap { $0 }.filter { $0.slot == hit.slot }
            guard owners.count == 1 else { throw RegionOperationError("\(question.rawValue): conflicting cache slot.") }
            return hit
        }
        guard !selected.isEmpty, Set(selected.map(\.slot)).count == selected.count else {
            throw JapanRegionError.invalidCachePatchLayout
        }
        return .init(format: "arm64-mg64-v1", imageUUID: imageUUID, cacheUUID: cacheUUID,
                     slotCount: slotCount, descriptors: selected)
    }

    func validateStaticAgreement(_ expected: [RegionCacheQuestion: Int]) throws {
        for question in RegionCacheQuestion.allCases where descriptors[question.key] != nil {
            guard let proof = try? binding(for: [question]),
                  proof.descriptors.first?.slot == expected[question] else {
                throw RegionOperationError("Dynamic descriptor conflicts with the device-verified static profile (\(question.rawValue)).")
            }
        }
    }

    private struct Section {
        let segment: String
        let name: String
        let address: UInt64
        let data: Data
        let pointers: Data
        func contains(_ value: UInt64, _ count: Int) -> Bool {
            count >= 0 && value >= address && value - address <= UInt64(data.count)
                && UInt64(count) <= UInt64(data.count) - (value - address)
        }
    }
    private static func fail(_ message: String) -> RegionOperationError {
        .init("MobileGestalt descriptor format not verified: " + message)
    }
    private static func number(_ bytes: Data, _ offset: Int, _ count: Int) throws -> UInt64 {
        guard offset >= 0, count > 0, count <= 8, offset <= bytes.count, count <= bytes.count - offset else {
            throw fail("truncated image/record.")
        }
        return (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }
    private static func name(_ bytes: Data, _ offset: Int) throws -> String {
        guard offset >= 0, offset <= bytes.count, 16 <= bytes.count - offset else { throw fail("section name.") }
        return String(decoding: bytes[offset..<(offset + 16)].prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    private static func add(_ address: UInt64, _ delta: Int64) throws -> UInt64 {
        if delta >= 0 {
            let (value, overflow) = address.addingReportingOverflow(UInt64(delta))
            guard !overflow else { throw fail("address overflow.") }; return value
        }
        let amount = UInt64(-(delta + 1)) + 1
        guard address >= amount else { throw fail("address underflow.") }
        return address - amount
    }
    private static func signed(_ value: UInt64, bits: Int) -> Int64 {
        Int64(bitPattern: value << (64 - bits)) >> (64 - bits)
    }

    static func scan(_ image: [String: Any]) throws -> Self {
        guard let header = image["header"] as? Data, header.count >= 32,
              try number(header, 0, 4) == 0xFEEDFACF, try number(header, 4, 4) == 0x0100000C,
              [UInt64(0), 2].contains(try number(header, 8, 4) & 0x00FFFFFF),
              try number(header, 12, 4) == 6,
              let slideNumber = image["slide"] as? NSNumber,
              let entries = image["sections"] as? [[String: Any]], entries.count <= 16,
              let writer = image["writerAddress"] as? NSNumber else { throw fail("invalid ARM64 Mach-O snapshot.") }
        let commands = Int(try number(header, 16, 4)), commandBytes = Int(try number(header, 20, 4))
        guard (1...4096).contains(commands), commandBytes <= 1024 * 1024,
              commandBytes == header.count - 32 else { throw fail("load command bounds.") }
        var sections: [Section] = [], uuids: [String] = []
        var offset = 32
        for _ in 0..<commands {
            let command = try number(header, offset, 4), size = Int(try number(header, offset + 4, 4))
            guard size >= 8, size.isMultiple(of: 8), offset <= header.count, size <= header.count - offset else {
                throw fail("invalid load command length.")
            }
            if command == 0x1B {
                guard size == 24 else { throw fail("LC_UUID length.") }
                let bytes = [UInt8](header[(offset + 8)..<(offset + 24)])
                guard bytes.contains(where: { $0 != 0 }) else { throw fail("nil LC_UUID.") }
                let hex = bytes.map { String(format: "%02X", $0) }.joined()
                let parts = [8,4,4,4,12]; var start = hex.startIndex
                uuids.append(parts.map { count in let end = hex.index(start, offsetBy: count); defer { start = end }; return String(hex[start..<end]) }.joined(separator: "-"))
            } else if command == 0x19 {
                guard size >= 72 else { throw fail("segment bounds.") }
                let count = Int(try number(header, offset + 64, 4))
                guard count <= 256, size == 72 + count * 80 else { throw fail("section count.") }
                let segment = try name(header, offset + 8)
                let base = try number(header, offset + 24, 8), length = try number(header, offset + 32, 8)
                for i in 0..<count {
                    let position = offset + 72 + i * 80
                    let sectionName = try name(header, position)
                    let wanted = segment == "__TEXT" ? ["__text", "__cstring"].contains(sectionName) :
                        ["__AUTH_CONST", "__DATA_CONST", "__DATA"].contains(segment) && ["__const", "__cfstring"].contains(sectionName)
                    if !wanted { continue }
                    let address = try number(header, position + 32, 8), size = try number(header, position + 40, 8)
                    if size == 0 { continue }
                    guard try name(header, position + 16) == segment, address >= base, size <= length,
                          address - base <= length - size, size <= 32 * 1024 * 1024,
                          try number(header, offset + 60, 4) & 1 == 1 else { throw fail("section outside readable segment.") }
                    let runtimeAddress = try add(address, slideNumber.int64Value)
                    let matches = entries.filter { ($0["segment"] as? String) == segment && ($0["name"] as? String) == sectionName }
                    guard matches.count == 1, let entry = matches.first,
                          (entry["address"] as? NSNumber)?.uint64Value == runtimeAddress,
                          let data = entry["data"] as? Data, data.count == Int(size),
                          let pointers = entry["pointers"] as? Data, pointers.count == data.count,
                          runtimeAddress <= UInt64.max - size else { throw fail("missing/duplicate section or unresolved ASLR.") }
                    sections.append(.init(segment: segment, name: sectionName, address: runtimeAddress, data: data, pointers: pointers))
                }
            }
            offset += size
        }
        guard offset == header.count, uuids.count == 1, sections.count == entries.count,
              sections.reduce(0, { $0 + $1.data.count }) <= 64 * 1024 * 1024 else { throw fail("image identity/size.") }
        for (i, a) in sections.enumerated() {
            for b in sections.dropFirst(i + 1) where a.address < b.address + UInt64(b.data.count) && b.address < a.address + UInt64(a.data.count) {
                throw fail("overlapping sections.")
            }
        }
        func section(_ address: UInt64, _ length: Int, _ name: String) throws -> Section {
            let hits = sections.filter { $0.name == name && $0.contains(address, length) }
            guard hits.count == 1 else { throw fail("address does not belong to the expected image section.") }; return hits[0]
        }
        func word(_ address: UInt64) throws -> UInt32 {
            let s = try section(address, 4, "__text")
            return UInt32(try number(s.data, Int(address - s.address), 4))
        }
        func exact(_ address: UInt64, _ expected: UInt32, _ mask: UInt32 = .max) throws {
            guard try word(address) & mask == expected & mask else { throw fail("unrecognized cache consumer instructions.") }
        }
        func pair(_ address: UInt64, _ register: UInt32) throws -> UInt64 {
            let a = try word(address), b = try word(address + 4)
            guard a & 0x9F00001F == 0x90000000 | register,
                  b & 0xFFC003FF == 0x91000000 | (register << 5) | register else { throw fail("ADRP/ADD addressing.") }
            let delta = signed(UInt64(((a >> 5) & 0x7FFFF) << 2 | ((a >> 29) & 3)), bits: 21) * 4096
            return try add(add(address & ~UInt64(4095), delta), Int64((b >> 10) & 0xFFF))
        }
        func branch(_ address: UInt64) throws -> UInt64 {
            let w = try word(address)
            guard w & 0xFC000000 == 0x94000000 else { throw fail("expected direct BL.") }
            return try add(address, signed(UInt64(w & 0x03FFFFFF), bits: 26) * 4)
        }
        func immediate(_ address: UInt64, _ register: UInt32) throws -> Int {
            let w = try word(address)
            guard w & 0xFFE0001F == 0x52800000 | register else { throw fail("expected MOVZ W immediate.") }
            return Int((w >> 5) & 0xFFFF)
        }
        func cstring(_ address: UInt64, length: Int) throws -> String {
            let s = try section(address, length + 1, "__cstring"), i = Int(address - s.address)
            guard s.data[i + length] == 0, s.data[i..<(i + length)].allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw fail("invalid cstring.") }
            return String(decoding: s.data[i..<(i + length)], as: UTF8.self)
        }
        func cfstring(_ address: UInt64) throws -> String {
            let s = try section(address, 32, "__cfstring"), i = Int(address - s.address)
            guard i.isMultiple(of: 32), try number(s.data, i + 8, 8) == 0x7C8 else { throw fail("unrecognized CFString format.") }
            let length = try number(s.data, i + 24, 8)
            guard (1...128).contains(length) else { throw fail("CFString length.") }
            return try cstring(number(s.pointers, i + 16, 8), length: Int(length))
        }
        let entry = writer.uint64Value
        _ = try section(entry, 0x1A0, "__text")
        // v1 writer uses CFData length twice, then inserts version/data/extra/
        // UUID into one dictionary. Resolve actual referenced CFStrings, not
        // the only UUID-looking string in __cstring.
        let size = try immediate(entry + 0x88, 1)
        guard size == (try immediate(entry + 0x94, 1)), size > 0, size.isMultiple(of: 9), size / 9 <= 16384 else { throw fail("cache allocation size.") }
        try exact(entry + 0x84, 0xD2800000)
        _ = try branch(entry + 0x8C); try exact(entry + 0x90, 0xAA0003F4)
        _ = try branch(entry + 0x98); try exact(entry + 0x9C, 0xAA1403E0)
        _ = try branch(entry + 0xA0); try exact(entry + 0xA4, 0xF9001BE0)
        _ = try pair(entry + 0xA8, 0)
        try exact(entry + 0xB0, 0xD2800001)
        _ = try branch(entry + 0xB4)
        try exact(entry + 0xB8, 0xAA0003F5)
        let keys = entry + 0xBC
        let keyNames = ["CacheVersion", "CacheData", "CacheExtra"]
        var setter: UInt64?
        for (i, key) in keyNames.enumerated() {
            let p = keys + UInt64(i * 20)
            guard try cfstring(pair(p, 1)) == key else { throw fail("cache dictionary key binding.") }
            try exact(p + 8, 0xAA1303E0)
            try exact(p + 12, [UInt32(0xAA1503E2), 0xAA1403E2, 0xAA1603E2][i])
            let call = try branch(p + 16)
            if let setter { guard call == setter else { throw fail("dictionary setter mismatch.") } } else { setter = call }
        }
        let uuidKey = try pair(keys + 60, 1), uuidValue = try pair(keys + 68, 2)
        let uuidText = try cfstring(uuidValue)
        guard try cfstring(uuidKey) == "CacheUUID", let cacheUUID = UUID(uuidString: uuidText),
              cacheUUID != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else { throw fail("cache layout UUID.") }
        try exact(keys + 76, 0xF90023F3); try exact(keys + 80, 0xAA1303E0)
        guard try branch(keys + 84) == setter else { throw fail("UUID setter binding.") }
        // Resolve the writer's real table/count accessor without calling it.
        try exact(entry + 0x130, 0x12800008); try exact(entry + 0x134, 0xB81943A8)
        try exact(entry + 0x138, 0xD101B3A0); try exact(entry + 0x140, 0xAA0003F7)
        let accessor = try branch(entry + 0x13C)
        _ = try section(accessor, 20, "__text")
        let records = try immediate(accessor, 8)
        guard (1...32768).contains(records) else { throw fail("descriptor count.") }
        try exact(accessor + 4, 0xB9000008); try exact(accessor + 16, 0xD65F03C0)
        let tableAddress = try pair(accessor + 8, 0)
        try exact(entry + 0x17C, 0x8B1C1AF8) // add x24,x23,x28,lsl #6
        try exact(entry + 0x180, 0xF9400301)
        try exact(entry + 0x18C, 0x79C07709); try exact(entry + 0x198, 0x3940E309)
        let table = try section(tableAddress, records * 64, "__const")
        guard Int(tableAddress - table.address).isMultiple(of: 8) else { throw fail("descriptor alignment.") }
        let slots = size / 9
        guard slots <= 4096 else { throw fail("reader count exceeds the reviewed immediate format.") }
        let texts = sections.filter { $0.name == "__text" }
        guard texts.count == 1 else { throw fail("text section ambiguity.") }
        let text = texts[0]
        // v1 reader: signed index +0x3A, bounds, validity at count*8, exact
        // valid==1, type at +0x3C, type 11 reads one byte at index<<3.
        var readers = 0, loaders = 0
        for i in stride(from: 0, to: max(0, text.data.count - 0xDC), by: 4) {
            let w = UInt32(try number(text.data, i, 4)), p = text.address + UInt64(i)
            if w == 0x79407688 {
                guard (try? immediate(p + 0x28, 11)) == slots * 8,
                      (try? word(p + 4)) == 0x7100011F | UInt32(slots - 1) << 10,
                      (try? word(p + 8)) == 0x54000069,
                      (try? word(p + 0x20)) == 0x79807689,
                      (try? word(p + 0x24)) == 0x8B09010A,
                      (try? word(p + 0x2C)) == 0x8B0B014A,
                      (try? word(p + 0x30)) == 0x3940014A,
                      (try? word(p + 0x34)) == 0x7100055F,
                      (try? word(p + 0x38)) == 0x54000161,
                      (try? word(p + 0x3C)) == 0xB9403E8A,
                      (try? word(p + 0xAC)) == 0x71002D5F,
                      (try? word(p + 0xB0)) == 0x54000361,
                      (try? word(p + 0xB4)) == 0xD37DF129,
                      (try? word(p + 0xB8)) == 0x38696908 else { continue }
                readers += 1
            }
            if w & 0x9F00001F == 0x90000001,
               (try? pair(p, 1)) == uuidKey,
               (try? word(p + 8)) == 0xAA1303E0,
               (try? word(p + 20)) == 0xAA0003F9,
               (try? pair(p + 24, 26)) == uuidValue,
               (try? word(p + 32)) == 0xAA1A03E1,
               (try? immediate(p + 0x68, 2)) == size,
               (try? cfstring(pair(p + 44, 1))) == "CacheData" {
                _ = try branch(p + 12); _ = try branch(p + 36); _ = try branch(p + 56)
                try exact(p + 16, 0xB4000000, 0xFF00001F)
                try exact(p + 40, 0x34000000, 0xFF00001F)
                loaders += 1
            }
        }
        guard readers == 1, loaders == 1 else { throw fail("cache reader/UUID loader relationship.") }
        var descriptors: [String: [RegionDescriptor]] = [:]
        let tableOffset = Int(tableAddress - table.address)
        for i in 0..<records {
            let p = tableOffset + i * 64
            let rawPointer = try number(table.data, p, 8)
            if rawPointer == 0 {
                guard table.data[p..<(p + 64)].allSatisfy({ $0 == 0 }) else { throw fail("nonempty null descriptor.") }
                continue
            }
            let key = try cstring(number(table.pointers, p, 8), length: 22)
            guard key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47 }) else { throw fail("descriptor key.") }
            let index = Int(Int16(bitPattern: UInt16(try number(table.data, p + 58, 2))))
            let type = Int(try number(table.data, p + 60, 4)), flags = Int(try number(table.data, p + 56, 2))
            // Malformed target entries are retained for independent rejection;
            // unknown table formats are rejected globally.
            let isTarget = RegionCacheQuestion.allCases.contains { $0.key == key }
            guard isTarget || (flags & ~0x3F == 0 && (-1..<slots).contains(index) && (1...11).contains(type)) else { throw fail("descriptor properties.") }
            descriptors[key, default: []].append(.init(key: key, slot: index, type: type, flags: flags))
        }
        return .init(imageUUID: uuids[0], cacheUUID: cacheUUID.uuidString, slotCount: slots, descriptors: descriptors)
    }
}
