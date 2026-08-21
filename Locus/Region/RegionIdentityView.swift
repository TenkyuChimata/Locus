import SwiftUI

struct RegionIdentityView: View {
    @EnvironmentObject private var service: RegionIdentityService
    @State private var confirmsMutation = false

    var body: some View {
        NavigationStack {
            List {
                identitySection
                currentRegionSection
                supportSection

                if let operationResult = service.operationResult {
                    Section("Last Operation") {
                        Label(operationResult, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                    }
                }

                if let errorMessage = service.errorMessage {
                    Section("Error") {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmsMutation = true
                    } label: {
                        HStack {
                            Label("Apply Japan Region Identity", systemImage: "externaldrive.badge.plus")
                            Spacer()
                            if service.isBusy {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(service.isBusy || service.snapshot?.mutationPathReady != true)
                } footer: {
                    Text(
                        "This persistently rewrites MobileActivation and MobileGestalt in place. "
                        + "Exact backups, read-back verification, and reverse-order rollback are automatic."
                    )
                }
            }
            .navigationTitle("Japan Region")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        service.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(service.isBusy)
                    .accessibilityLabel("Refresh Region Identity")
                }
            }
            .task { service.refresh() }
            .confirmationDialog(
                "Apply Persistent Japan Region Identity?",
                isPresented: $confirmsMutation,
                titleVisibility: .visible
            ) {
                Button("Apply and Verify", role: .destructive) {
                    service.applyJapanRegion()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Only continue on an authorized test device. Locus will preserve real hardware identity, "
                    + "create exact backups of both files, and roll back if verification fails."
                )
            }
        }
    }

    private var identitySection: some View {
        Section("Real Device Identity") {
            valueRow("OS Build", service.snapshot?.build)
            valueRow("ProductType", service.snapshot?.productType)
            valueRow("Verified Device", service.snapshot?.profile?.marketingName)
            valueRow("Japan Regulatory Model", service.snapshot?.profile?.regulatoryModel)
        }
    }

    private var currentRegionSection: some View {
        Section("Current Persistent Identity") {
            valueRow("MobileGestalt RegionCode", service.snapshot?.regionCode)
            valueRow("MobileGestalt RegionInfo", service.snapshot?.regionInfo)
            valueRow("Regulatory Model", service.snapshot?.regulatoryModel)
            valueRow("Activation Country", service.snapshot?.activationCountry)
            valueRow("Activation Region", service.snapshot?.activationRegion)
            valueRow("Activation Behaviors", service.snapshot?.activationBehaviors)
        }
    }

    private var supportSection: some View {
        Section("Mutation Capability") {
            statusRow(
                "Exact Build Path",
                text: service.snapshot?.exactBuildSupported == true ? "Supported" : "Unsupported",
                systemImage: service.snapshot?.exactBuildSupported == true
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill",
                color: service.snapshot?.exactBuildSupported == true ? .green : .orange
            )
            statusRow(
                "Verified Profile",
                text: service.snapshot?.profile != nil ? "Found" : "Unavailable",
                systemImage: service.snapshot?.profile != nil
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill",
                color: service.snapshot?.profile != nil ? .green : .orange
            )
            configurationStatusRow(service.snapshot?.configurationState)

            if let detail = service.snapshot?.readinessDetail,
               service.snapshot?.mutationPathReady != true {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func valueRow(_ title: String, _ value: String?) -> some View {
        LabeledContent(title) {
            Text(value ?? "<unavailable>")
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func statusRow(
        _ title: String,
        text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Label(text, systemImage: systemImage)
                .foregroundStyle(color)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }

    private func configurationStatusRow(_ state: RegionConfigurationState?) -> some View {
        let presentation: (text: String, systemImage: String, color: Color)
        switch state {
        case .verified:
            presentation = ("Verified", "checkmark.circle.fill", .green)
        case .japanLikeUnverified:
            presentation = ("Detected · Unverified", "exclamationmark.triangle.fill", .orange)
        case .notApplied:
            presentation = ("Not Applied", "xmark.circle.fill", .orange)
        case .unavailable, nil:
            presentation = ("Unavailable", "questionmark.circle.fill", .orange)
        }
        return statusRow(
            "Configuration State",
            text: presentation.text,
            systemImage: presentation.systemImage,
            color: presentation.color
        )
    }
}
