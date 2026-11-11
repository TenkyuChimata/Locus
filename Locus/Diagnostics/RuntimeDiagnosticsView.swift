import SwiftUI
import UIKit

struct RuntimeDiagnosticsView: View {
    @EnvironmentObject private var service: RuntimeDiagnosticsService

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
                        value: DiagnosticValueFormatter.display(service.runtimeAnswers[item.query])
                    )
                    if let cacheKey = item.cacheKey {
                        labeledValue(
                            "CacheExtra",
                            value: DiagnosticValueFormatter.display(service.cacheExtra[cacheKey])
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
