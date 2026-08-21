import Combine
import Foundation

struct RuntimeDiagnosticQuestion: Identifiable {
    enum Group: Equatable { case region, hardware }

    var id: String { query }
    let title: String
    let query: String
    let cacheKey: String?
    let group: Group
}

let runtimeDiagnosticQuestions: [RuntimeDiagnosticQuestion] = [
    .init(title: "RegionCode", query: "RegionCode", cacheKey: JapanRegionMutation.regionCodeKey, group: .region),
    .init(title: "RegionInfo", query: "RegionInfo", cacheKey: JapanRegionMutation.regionInfoKey, group: .region),
    .init(title: "RegulatoryModelNumber", query: "RegulatoryModelNumber", cacheKey: JapanRegionMutation.regulatoryModelKey, group: .region),
    .init(title: "WSKU", query: "gD8SNRcHQeIxCAvsp+2vjA", cacheKey: "gD8SNRcHQeIxCAvsp+2vjA", group: .hardware),
    .init(title: "green-tea", query: "green-tea", cacheKey: "iyfxmLogGVIaH7aEgqwcIA", group: .region),
    .init(title: "not-green-tea", query: "not-green-tea", cacheKey: "4snMZS8LJkSctKypt2m+xA", group: .region),
    .init(title: "wapi", query: "wapi", cacheKey: "hiHut/WR+B9Lx/vd0WyeNg", group: .region),
    .init(title: "RegionalBehaviorAll", query: "RegionalBehaviorAll", cacheKey: "D4AU4tOIuGKN3G/uix65cQ", group: .region),
    .init(title: "RegionalBehaviorChinaBrick", query: "RegionalBehaviorChinaBrick", cacheKey: "0L5PkT61qoH1b/B1USWqjQ", group: .region),
    .init(title: "RegionalBehaviorGB18030", query: "RegionalBehaviorGB18030", cacheKey: "inLiSl5OQHJ1stAIvKH8wg", group: .region),
    .init(title: "RegionalBehaviorNoWiFi", query: "RegionalBehaviorNoWiFi", cacheKey: "kjKnJNt7HY90iN6rpbSeFQ", group: .region),
    .init(title: "RegionalBehaviorShutterClick", query: "RegionalBehaviorShutterClick", cacheKey: nil, group: .region),
    .init(title: "RegionalBehaviorValid", query: "RegionalBehaviorValid", cacheKey: "KMgjmT+dsqBCXu1YQEcOFg", group: .region),
    .init(title: "RestrictedCountryCodes", query: "RestrictedCountryCodes", cacheKey: "nSo8opze5rFk+EdBoR6tBw", group: .region),
    .init(title: "CountryOfOrigin", query: "CountryOfOrigin", cacheKey: "gizLvTWx1sMUYQ9EYr/N4g", group: .region),
    .init(title: "SoftwareBehavior", query: "SoftwareBehavior", cacheKey: "7IgVvZZLtNjMFdInQlKg6A", group: .region),
    .init(title: "SysCfg", query: "SysCfg", cacheKey: "0Y4fmR6ZHZPxDZFfPtBnRQ", group: .region),
    .init(title: "SysCfgDict", query: "SysCfgDict", cacheKey: nil, group: .region),
    .init(title: "RegionalBehaviorsFromActivation", query: "RegionalBehaviorsFromActivation", cacheKey: "m+Ltk7LIvEX8QIlAusf4ew", group: .region),
    .init(title: "RegionInfoFromActivation", query: "RegionInfoFromActivation", cacheKey: nil, group: .region),
    .init(title: "ProductType", query: "ProductType", cacheKey: "h9jDsbgj7xIVeIQ8S3/X3Q", group: .hardware),
    .init(title: "HardwarePlatform", query: "HardwarePlatform", cacheKey: "5pYKlGnYYBzGvAlIU8RjEQ", group: .hardware),
    .init(title: "HWModelStr", query: "HWModelStr", cacheKey: "/YYygAofPDbhrwToVsXdeA", group: .hardware)
]

@MainActor
final class RuntimeDiagnosticsService: ObservableObject {
    @Published private(set) var runtimeAnswers: [String: Any] = [:]
    @Published private(set) var cacheExtra: [String: Any] = [:]
    @Published private(set) var chosenProperties: [String: Any] = [:]
    @Published private(set) var syscfgProperties: [String: Any] = [:]
    @Published private(set) var activation: [String: Any] = [:]
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var errors: [String] = []
        let activationAccess = MobileActivationRegionAccess.shared()
        let deviceTree = DeviceTreeAccess.shared()
        let gestalt = MobileGestaltAccess.shared()

        // Preserve the existing first-touch ordering: collect the direct MAE
        // result before asking MobileGestalt for activation-derived answers.
        do {
            activation = try activationAccess.regionDiagnostics()
        } catch {
            activation = [:]
            errors.append("MobileActivation: \(error.localizedDescription)")
        }

        do {
            chosenProperties = try deviceTree.chosenProperties(
                for: ["software-behavior", "marketing-software-behavior"]
            )
        } catch {
            chosenProperties = [:]
            errors.append("DeviceTree /chosen: \(error.localizedDescription)")
        }

        do {
            let chosen = try deviceTree.properties(at: "IODeviceTree:/chosen")
            syscfgProperties = chosen.filter { $0.key.hasPrefix("syscfg-") }
        } catch {
            syscfgProperties = [:]
            errors.append("iBoot SysCfg: \(error.localizedDescription)")
        }

        do {
            if let plist = try gestalt.readCachePlist() as? [String: Any] {
                cacheExtra = plist["CacheExtra"] as? [String: Any] ?? [:]
            } else {
                cacheExtra = [:]
            }
        } catch {
            cacheExtra = [:]
            errors.append("MobileGestalt cache: \(error.localizedDescription)")
        }

        do {
            runtimeAnswers = try gestalt.runtimeAnswers(
                for: runtimeDiagnosticQuestions.map(\.query)
            )
        } catch {
            runtimeAnswers = [:]
            errors.append("MobileGestalt runtime: \(error.localizedDescription)")
        }

        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}

enum DiagnosticValueFormatter {
    static func display(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "<nil>" }
        if let data = value as? Data {
            let base64 = data.base64EncodedString()
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            return "Base64: \(base64)\nHex: \(hex)"
        }
        if let array = value as? [Any] {
            return "[" + array.map { display($0) }.joined(separator: ", ") + "]"
        }
        if let dictionary = value as? [String: Any] {
            let entries = dictionary.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(display($0.value))" }
            return "{ " + entries.joined(separator: ", ") + " }"
        }
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return String(describing: value)
    }

    static func softwareBehavior(_ value: Any?) -> String {
        let raw = display(value)
        guard let parsed = uint32(value) else { return raw }
        return raw
            + "\nUInt32: " + String(format: "0x%08X (%u)", parsed, parsed)
            + "\nValid bit 0: " + ((parsed & 1) != 0 ? "true" : "false")
    }

    static func deviceTreeData(_ value: Any?) -> String {
        let raw = display(value)
        guard let data = value as? Data, data.count >= 4 else { return raw }
        let bytes = [UInt8](data)
        let little = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let big = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return raw
            + "\nUInt32 LE: " + String(format: "0x%08X", little)
            + "\nUInt32 BE: " + String(format: "0x%08X", big)
    }

    static func syscfg(_ value: Any?) -> String {
        let raw = display(value)
        guard let data = value as? Data else { return raw }
        let bytes = [UInt8](data)
        var output = raw + "\nLength: \(bytes.count) bytes"
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 4) else { return output }

        var integers: [String] = []
        var chunks: [String] = []
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let part = Array(bytes[offset..<(offset + 4)])
            let little = UInt32(part[0])
                | (UInt32(part[1]) << 8)
                | (UInt32(part[2]) << 16)
                | (UInt32(part[3]) << 24)
            integers.append(String(format: "0x%08X (%u)", little, little))
            chunks.append(part.allSatisfy { (0x20...0x7E).contains($0) }
                ? (String(bytes: part, encoding: .ascii) ?? "????")
                : String(format: "0x%08X", little))
        }
        output += "\nUInt32 LE: [" + integers.joined(separator: ", ") + "]"
        output += "\n4-byte view: [" + chunks.joined(separator: ", ") + "]"
        return output
    }

    private static func uint32(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber { return number.uint32Value }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.lowercased().hasPrefix("0x")
                ? UInt32(trimmed.dropFirst(2), radix: 16)
                : UInt32(trimmed, radix: 10)
        }
        if let data = value as? Data, data.count >= 4 {
            let bytes = [UInt8](data)
            return UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
        }
        return nil
    }
}
