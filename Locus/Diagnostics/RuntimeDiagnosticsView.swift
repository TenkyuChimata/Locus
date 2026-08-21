import SwiftUI

struct RuntimeDiagnosticsView: View {
    @EnvironmentObject private var service: RuntimeDiagnosticsService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    valueRow("OS Build", MobileGestaltAccess.currentOSBuild())
                    Label("Read-only diagnostics", systemImage: "eye.fill")
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = service.errorMessage {
                    Section("Partial Errors") {
                        Text(errorMessage)
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                mobileActivationSection
                deviceTreeSection
                syscfgSection
                mobileGestaltSection(group: .hardware, title: "Hardware Identity Sanity")
                mobileGestaltSection(group: .region, title: "MobileGestalt Region / Runtime")
            }
            .navigationTitle("Runtime Diagnostics")
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
                    .accessibilityLabel("Refresh Runtime Diagnostics")
                }
            }
            .task { service.refresh() }
        }
    }

    private var mobileActivationSection: some View {
        Section {
            sourceHeader("Direct region_info.plist")
            valueRow("Backing Path", service.activation["resolvedBackingPath"])
            valueRow("Read Succeeded", service.activation["backingReadSucceeded"])
            valueRow("CountryCode", service.activation["backingCountryCode"])
            valueRow("RegionInfo", service.activation["backingRegionInfo"])
            behaviorRow("SoftwareBehaviors", service.activation["backingSoftwareBehaviors"])

            sourceHeader("Effective MobileActivation API")
            valueRow("Call Succeeded", service.activation["effectiveCallSucceeded"])
            valueRow("CountryCode", service.activation["effectiveCountryCode"])
            valueRow("RegionInfo", service.activation["effectiveRegionInfo"])
            behaviorRow("SoftwareBehaviors", service.activation["effectiveSoftwareBehaviors"])
            valueRow("API Error", service.activation["effectiveErrorDescription"])
            valueRow("Resolver Status", service.activation["resolverStatus"])
        } header: {
            Text("MobileActivation")
        } footer: {
            Text("The direct backing file and MAECopyDeviceRegionInfoWithError are independent observations.")
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

    private func sourceHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func valueRow(_ title: String, _ value: Any?) -> some View {
        labeledValue(title, value: DiagnosticValueFormatter.display(value))
    }

    private func behaviorRow(_ title: String, _ value: Any?) -> some View {
        labeledValue(title, value: DiagnosticValueFormatter.softwareBehavior(value))
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
