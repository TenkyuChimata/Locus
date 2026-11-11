import SwiftUI
import UIKit

struct RuntimeDiagnosticsView: View {
    @EnvironmentObject private var service: RuntimeDiagnosticsService
    @EnvironmentObject private var regionService: RegionIdentityService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    valueRow("Device Model", RealDeviceIdentity.productType)
                    valueRow("iOS Version", UIDevice.current.systemVersion)
                    valueRow("OS Build", MobileGestaltAccess.currentOSBuild())
                }

                if let errorMessage = service.errorMessage {
                    Section("Partial Errors") {
                        Text(errorMessage)
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                cacheSection
                Section("Japan RegionalBehavior") {
                    RegionalBehaviorDiagnosticsContent(service: service, productType: RealDeviceIdentity.productType,
                        build: MobileGestaltAccess.currentOSBuild(), activationRows: regionService.activationSourceDiagnostics)
                }
                deviceTreeSection
                syscfgSection
                mobileGestaltSection(group: .hardware, title: "Hardware")
                mobileGestaltSection(group: .region, title: "Region Values")
            }
            .navigationTitle("Diagnostics")
            .task { service.refresh() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        service.refresh()
                    } label: {
                        if service.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(service.isLoading)
                    .accessibilityLabel("Refresh Diagnostics")
                }
            }
        }
    }

    private var cacheSection: some View {
        Section("MobileGestalt Cache") {
            valueRow("File Access", service.cacheStatus)
            valueRow("CacheUUID", service.cacheInfo["CacheUUID"])
            valueRow("CacheVersion", service.cacheInfo["CacheVersion"])
            valueRow("CacheData Bytes", service.cacheInfo["CacheDataBytes"])
            valueRow("CacheExtra Fields", service.cacheExtra.count)
        }
    }

    private var deviceTreeSection: some View {
        Section {
            ForEach(["software-behavior", "marketing-software-behavior"], id: \.self) { name in
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.subheadline.weight(.semibold))
                    Text(DiagnosticValueFormatter.deviceTreeData(service.chosenProperties[name]))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }
        } header: {
            Text("DeviceTree /chosen")
        } footer: {
            Text("Raw IODeviceTree properties; these are not MobileGestalt answers.")
        }
    }

    private var syscfgSection: some View {
        Section {
            if service.syscfgProperties.isEmpty {
                Text("No syscfg-* properties available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.syscfgProperties.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(key).font(.caption.weight(.semibold)).textSelection(.enabled)
                        Text(DiagnosticValueFormatter.syscfg(service.syscfgProperties[key]))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                }
            }
        } header: {
            Text("iBoot SysCfg Runtime")
        } footer: {
            Text("syscfg-* properties enumerated from IODeviceTree:/chosen; independent of MGCopyAnswer(\"SysCfg\") and SysCfgDict.")
        }
    }

    private func mobileGestaltSection(
        group: RuntimeDiagnosticQuestion.Group,
        title: String
    ) -> some View {
        Section {
            ForEach(runtimeDiagnosticQuestions.filter { $0.group == group }) { item in
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                    labeledValue(
                        "Runtime",
                        value: formatted(service.runtimeAnswers[item.query], question: item)
                    )
                    if let cacheKey = item.cacheKey {
                        labeledValue(
                            "CacheExtra",
                            value: formatted(service.cacheExtra[cacheKey], question: item)
                        )
                        Text(cacheKey)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(title)
        } footer: {
            Text("Runtime values come from MGCopyAnswer; CacheExtra values come directly from the persistent plist.")
        }
    }

    private func formatted(_ value: Any?, question: RuntimeDiagnosticQuestion) -> String {
        question.title == "SoftwareBehavior"
            ? DiagnosticValueFormatter.softwareBehavior(value)
            : DiagnosticValueFormatter.display(value)
    }

    private func valueRow(_ title: String, _ value: Any?) -> some View {
        labeledValue(title, value: DiagnosticValueFormatter.display(value))
    }

    private func labeledValue(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// 両画面で同じ観測値と比較関数を表示する。展開だけでは再取得しない。
struct RegionalBehaviorDiagnosticsContent: View {
    @ObservedObject var service: RuntimeDiagnosticsService
    let productType: String
    let build: String
    let activationRows: [RegionAccessDiagnosticRow]

    private var comparison: RegionalBehaviorComparison {
        JapanRegionalBehaviorReference.observed.compare(service.regionalBehaviorRead, productType: productType, build: build)
    }

    var body: some View {
        LabeledContent("Comparison", value: comparison.status.rawValue)
        Text(comparison.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        DisclosureGroup("RegionalBehavior Source Diagnostics") {
            Text(RuntimeDiagnosticsService.observationBoundary).font(.caption).foregroundStyle(.secondary)
            diagnostic("DeviceTree Read", service.chosenStatus)
            diagnostic("DeviceTree Attempt", service.chosenObservedAt?.formatted(date: .abbreviated, time: .standard) ?? "Not Read")
            diagnostic("MG Attempt", service.regionalObservedAt?.formatted(date: .abbreviated, time: .standard) ?? "Not Read")
            ForEach(["software-behavior", "marketing-software-behavior"], id: \.self) { key in
                diagnostic("/chosen/\(key)", DiagnosticValueFormatter.deviceTreeData(service.chosenProperties[key]))
            }
            ForEach(["RegionalBehaviorsFromActivation", "RegionalBehaviorAll", "SoftwareBehavior"], id: \.self) { key in
                diagnostic(key, JapanRegionalBehaviorReference.describe(service.runtimeAnswers[key]))
            }
            Text("MobileActivation API errors below come from the last explicit Advanced Research refresh; its time may differ. No container scan runs here.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(activationRows) { row in diagnostic(row.title, row.value) }
            Text("Runtime Dictionary; CacheExtra is not required and does not provide a supported override for these outputs.")
                .font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("Required Fields / Types") {
            ForEach(comparison.checks) { check in
                diagnostic("\(check.id): \(check.result.rawValue)", check.detail)
            }
        }
    }

    private func diagnostic(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            Text(text).font(.caption2.monospaced()).textSelection(.enabled)
        }.padding(.vertical, 2)
    }
}
