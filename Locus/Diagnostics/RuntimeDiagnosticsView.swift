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
                metadataAccessSection
                deviceTreeSection
                syscfgSection
                cacheLayoutSection
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
            valueRow("Direct Stage", service.activation["backingStage"])
            valueRow("Direct Error", service.activation["backingReadError"])
            valueRow("Direct Error Details", service.activation["backingErrorDetails"])
            valueRow("Path State", service.activation["backingPathState"])
            valueRow("Lease Target State", service.activation["regionLeaseTargetState"])
            valueRow("Discovery Source", activationDiscovery["source"])
            DisclosureGroup("Discovery scope and directory leases") {
                ForEach([("candidateCount", "Candidates in scan"), ("uuidCandidateCount", "UUID candidates"),
                         ("namedCandidateInScan", "Named candidate in scan"),
                         ("uuidMetadataDirectoriesLeased", "UUID directory leases"),
                         ("uuidMetadataLeaseFailures", "UUID lease failures"),
                         ("namedMetadataDirectoriesLeased", "Named directory leases"),
                         ("namedMetadataLeaseFailures", "Named lease failures"),
                         ("inodeScanPerformed", "Scan attempted"), ("inodeLimit", "Inode limit"),
                         ("scanCoverage", "Coverage"), ("rootInodeAboveLimit", "Root inode exceeds limit"),
                         ("rootInodeError", "Root inode error"), ("lastMetadataLeaseDetail", "Lease detail")], id: \.0) { key, title in
                    valueRow(title, activationDiscovery[key])
                }
            }
            sourceHeader("Identity Query")
            ForEach([("status", "Query Status"), ("apiAvailable", "API Available"),
                     ("queryCreated", "Query Created"), ("iterationReturned", "Iteration Returned"),
                     ("iterationCompleted", "Iteration Completed"), ("results", "Visible Results"),
                     ("errorIntrospectionAvailable", "Query Error Getter Available"),
                     ("queryErrorPresent", "Query Error Object Present"),
                     ("errorTypeGetterAvailable", "Error Type Getter Available"),
                     ("errorPOSIXGetterAvailable", "POSIX Getter Available"),
                     ("queryErrorType", "Query Error Type"), ("queryErrorName", "Query Error Name"),
                     ("queryErrorPOSIXCode", "Query POSIX Code"), ("enumerationRights", "Enumeration Rights")], id: \.0) { key, title in
                valueRow(title, (activationDiscovery["identityQuery"] as? [String: Any])?[key])
            }
            valueRow("Schema Supported", service.activation["mutationSchemaSupported"])
            valueRow("Backing Schema Shape Valid", service.activation["backingSchemaValid"])
            valueRow("Existing File Write Access", service.activation["backingWriteAccessAvailable"])
            valueRow("Write Access Error", service.activation["backingWriteAccessError"])
            valueRow("Framework LC_UUID", service.activation["binaryUUID"])
            valueRow("Binary Semantics Reviewed", service.activation["binarySupported"])
            valueRow("Storage Path Evidence", service.activation["storagePathProvenance"])
            valueRow("Metadata Denial Meaning", service.activation["metadataDenialMeaning"])
            valueRow("Schema Error", service.activation["mutationSchemaError"])
            valueRow("Schema Error Details", service.activation["mutationSchemaErrorDetails"])
            valueRow("CountryCode", service.activation["backingCountryCode"])
            valueRow("RegionInfo", service.activation["backingRegionInfo"])
            behaviorRow("SoftwareBehaviors", service.activation["backingSoftwareBehaviors"])

            sourceHeader("Effective MobileActivation API")
            valueRow("Call Succeeded", service.activation["effectiveCallSucceeded"])
            valueRow("CountryCode", service.activation["effectiveCountryCode"])
            valueRow("RegionInfo", service.activation["effectiveRegionInfo"])
            behaviorRow("SoftwareBehaviors", service.activation["effectiveSoftwareBehaviors"])
            valueRow("API Error", service.activation["effectiveErrorDescription"])
            valueRow("API Stage", service.activation["effectiveStage"])
            valueRow("API Error Domain", service.activation["effectiveErrorDomain"])
            valueRow("API Error Code", service.activation["effectiveErrorCode"])
            valueRow("Resolver Status", service.activation["resolverStatus"])
            valueRow("Resolver Status Name", service.activation["resolverStatusName"])
            valueRow("Resolver Detail", service.activation["resolverDetail"])
        } header: {
            Text("MobileActivation")
        } footer: {
            Text("The direct backing file and MAECopyDeviceRegionInfoWithError are independent observations. Resolver status belongs to ContainerManager; path stat errors are POSIX errors.")
        }
    }

    private var activationDiscovery: [String: Any] {
        service.activation["discovery"] as? [String: Any] ?? [:]
    }

    private var metadataAccessSection: some View {
        Section {
            valueRow("Metadata path targets", activationDiscovery["metadataFilesAttempted"])
            valueRow("Data read requests", activationDiscovery["metadataReadAttempts"])
            valueRow("Unreadable path targets", activationDiscovery["metadataReadFailures"])
            valueRow("Alias read recoveries", activationDiscovery["metadataAliasReadRecoveries"])
            valueRow("Alias identity failures", activationDiscovery["metadataAliasIdentityFailures"])
            ForEach(MobileActivationDiagnosticSummary.aliasRows(activationDiscovery)) { row in
                labeledValue(row.title, value: row.value)
            }
            ForEach(MobileActivationDiagnosticSummary.probeGroups(activationDiscovery)) { group in
                DisclosureGroup(group.title) {
                    ForEach(group.rows) { row in
                        labeledValue(row.title, value: row.value)
                    }
                }
            }
            DisclosureGroup("Complete read error distribution") {
                ForEach(MobileActivationDiagnosticSummary.readErrorRows(activationDiscovery)) { row in
                    labeledValue(row.title, value: row.value)
                }
            }
            DisclosureGroup("Latest errors by stage") {
                valueRow("Metadata Read", activationDiscovery["lastMetadataReadFailure"])
                valueRow("Directory Lease", activationDiscovery["lastMetadataLeaseFailure"])
                valueRow("Plist Parse", activationDiscovery["lastMetadataParseFailure"])
                valueRow("Alias Identity", activationDiscovery["lastMetadataAliasIdentityFailure"])
            }
        } header: {
            Text("Metadata Access")
        } footer: {
            Text("Each count belongs to one operation and path alias. Do not add stat/lstat/lookup counts as files. An opened directory or object does not prove metadata content is readable. EPERM does not identify the enforcing policy.")
        }
    }

    private var cacheLayoutSection: some View {
        Section {
            valueRow("Loaded Binary LC_UUID", service.imageIdentity["binaryUUID"])
            valueRow("Image Snapshot Error", service.imageIdentity["error"])
            valueRow("Pointer Comparison", service.imageIdentity["pointerComparison"])
            valueRow("CacheUUID", service.cacheLayout["cacheUUID"])
            valueRow("CacheUUID Type", service.cacheLayout["cacheUUIDType"])
            valueRow("CacheUUID Valid", service.cacheLayout["cacheUUIDValid"])
            valueRow("CacheVersion", service.cacheLayout["cacheVersion"])
            valueRow("CacheVersion Type", service.cacheLayout["cacheVersionType"])
            valueRow("Matches OS Build", service.cacheLayout["cacheVersionMatchesBuild"])
            valueRow("CacheData Type", service.cacheLayout["cacheDataType"])
            valueRow("CacheData Bytes", service.cacheLayout["cacheDataLength"])
            valueRow("CacheExtra Type", service.cacheLayout["cacheExtraType"])
            valueRow("Candidate Slots", service.cacheLayout["candidateSlotCount"])
            valueRow("Candidate Validity Offset", service.cacheLayout["candidateValidityOffset"])
            valueRow("Candidate Valid Slots", service.cacheLayout["candidateValidCount"])
            valueRow("Canonical Validity Bytes", service.cacheLayout["candidateValidityCanonical"])
            valueRow("Structure", service.cacheLayout["structuralStatus"])
            valueRow("Write Layout Supported", service.cacheLayout["layoutSupported"])
            valueRow("Write Validation", service.cacheLayout["mutationStatus"])
            ForEach(service.cacheMapping, id: \.question) { item in
                DisclosureGroup(item.question.rawValue + " · " + item.status.rawValue) {
                    Text(item.reason).font(.caption.monospaced()).textSelection(.enabled)
                    if let descriptor = item.descriptor {
                        valueRow("Descriptor Section", descriptor.section)
                        valueRow("Descriptor Offset", descriptor.offset)
                        valueRow("Candidate Index", descriptor.slot)
                        valueRow("Candidate Type", descriptor.type)
                    }
                    valueRow("Candidate Cache Value", item.cacheValue)
                    valueRow("Validity Byte", item.valid)
                }
            }
        } header: {
            Text("MobileGestalt Cache Layout")
        } footer: {
            Text("Structural consistency does not establish question-to-slot mappings or enable writes.")
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
