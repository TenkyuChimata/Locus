#if canImport(Combine)
import Combine
#endif
import Foundation
import CoreFoundation

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
    // Distinct questions, not proven old/new aliases. Keep each cached value
    // paired with its own question; matching runtime answers do not merge them.
    .init(title: "RegionInfo", query: "RegionInfo", cacheKey: "zHeENZu+wbg7PUprwNwBWg", group: .region),
    .init(title: "RegionInfoFromSysconfig (direct key)", query: "yK+xavymRGZ3xWc1tb8XDg", cacheKey: "yK+xavymRGZ3xWc1tb8XDg", group: .region),
    .init(title: "RegionInfo (direct key)", query: "zHeENZu+wbg7PUprwNwBWg", cacheKey: "zHeENZu+wbg7PUprwNwBWg", group: .region),
    .init(title: "Apple Intelligence Capability", query: RegionModuleMutation.intelligenceKey, cacheKey: RegionModuleMutation.intelligenceKey, group: .region),
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
    @Published private(set) var cacheInfo: [String: Any] = [:]
    @Published private(set) var cacheStatus = "Not read"
    @Published private(set) var chosenProperties: [String: Any] = [:]
    @Published private(set) var syscfgProperties: [String: Any] = [:]
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var regionalBehaviorRead = RegionalBehaviorRead.notRead
    @Published private(set) var chosenStatus = "Not Read"
    @Published private(set) var chosenObservedAt: Date?
    @Published private(set) var regionalObservedAt: Date?

    static let observationBoundary = "DeviceTree is read before this refresh's MG queries. Earlier framework or process initialization is unknown; this is not a first-initialization snapshot. MG queries may initialize process caches."

    // Region と Diagnostics で同じ読み取り経路を使う。表示の評価から I/O は行わない。
    func refreshRegionalBehavior() {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var errors: [String] = []
        readChosen(errors: &errors)
        readRuntime(questions: JapanRegionalBehaviorReference.queries, errors: &errors)
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func readChosen(errors: inout [String]) {
        chosenObservedAt = Date()
        do {
            chosenProperties = try DeviceTreeAccess.shared().chosenProperties(
                for: ["software-behavior", "marketing-software-behavior"])
            chosenStatus = "Read — nil property means absent or unavailable to this API"
        } catch {
            chosenProperties = [:]
            chosenStatus = "Read Failed: \(error.localizedDescription)"
            errors.append("DeviceTree /chosen: \(error.localizedDescription)")
        }
    }

    private func readRuntime(questions: [String], errors: inout [String]) {
        regionalObservedAt = Date()
        do {
            runtimeAnswers = try MobileGestaltAccess.shared().runtimeAnswers(for: questions)
            regionalBehaviorRead = .values(runtimeAnswers)
        } catch {
            runtimeAnswers = [:]
            regionalBehaviorRead = .failed(error.localizedDescription)
            errors.append("MobileGestalt runtime: \(error.localizedDescription)")
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var errors: [String] = []
        let deviceTree = DeviceTreeAccess.shared()
        let gestalt = MobileGestaltAccess.shared()

        readChosen(errors: &errors)

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
                cacheInfo = [
                    "CacheUUID": plist["CacheUUID"] as? String ?? "<unavailable>",
                    "CacheVersion": plist["CacheVersion"] as? String ?? "<unavailable>"
                ]
                if let data = plist["CacheData"] as? Data { cacheInfo["CacheDataBytes"] = data.count }
                cacheStatus = "Readable"
            } else {
                cacheExtra = [:]
                cacheInfo = [:]
                cacheStatus = "Unavailable"
                errors.append("MobileGestalt cache: expected a dictionary.")
            }
        } catch {
            cacheExtra = [:]
            cacheInfo = [:]
            cacheStatus = "Unavailable"
            errors.append("MobileGestalt cache: \(error.localizedDescription)")
        }

        let questions = runtimeDiagnosticQuestions.map(\.query)
        readRuntime(questions: questions + JapanRegionalBehaviorReference.queries.filter { !questions.contains($0) }, errors: &errors)

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
        JapanRegionalBehaviorReference.describe(value)
    }

    static func deviceTreeData(_ value: Any?) -> String {
        let raw = JapanRegionalBehaviorReference.describe(value)
        guard let data = value as? Data, data.count >= 4 else { return raw }
        let bytes = [UInt8](data)
        let big = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return raw + "\nUInt32 BE: " + String(format: "0x%08X", big)
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

}
