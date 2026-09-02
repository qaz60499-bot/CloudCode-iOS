import SwiftUI
import CloudCodeCore

struct ContentView: View {
    @ObservedObject var model: CloudCodeViewModel
    @ObservedObject private var approval: ApprovalCenter

    init(model: CloudCodeViewModel) {
        self.model = model
        self.approval = model.approvalCenter
    }

    var body: some View {
        TabView {
            ChatView(model: model)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            TasksView(model: model)
                .tabItem { Label("Tasks", systemImage: "checklist") }
            PhoneView(model: model)
                .tabItem { Label("Phone", systemImage: "iphone") }
            AppsView(model: model)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            FilesView(model: model)
                .tabItem { Label("Files", systemImage: "folder") }
            ActivityView(model: model)
                .tabItem { Label("Activity", systemImage: "waveform.path.ecg") }
            TrashView(model: model)
                .tabItem { Label("Trash", systemImage: "trash") }
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: Binding(
            get: { approval.pending != nil },
            set: { presented in if !presented && approval.pending != nil { approval.deny() } }
        )) {
            if let preview = approval.pending {
                ApprovalSheet(preview: preview, approval: approval)
            }
        }
        .alert("Cloud Code", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

private struct ChatView: View {
    @ObservedObject var model: CloudCodeViewModel
    @State private var input = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.transcript.isEmpty {
                            Text("Cloud Code iOS")
                                .font(.title2.bold())
                            Text("Tool-first local agent. Structured tools and filesystem/container services are preferred over GUI automation.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(model.transcript)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .font(.system(.body, design: .monospaced))
                        }

                        if !model.activityLines.isEmpty {
                            Divider()
                            ForEach(Array(model.activityLines.suffix(8).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                }

                Divider()
                HStack(alignment: .bottom) {
                    TextField("Ask Cloud Code…", text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                    if model.isRunning {
                        Button("Stop") { model.cancelCurrentTask() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Send") {
                            let value = input
                            input = ""
                            model.send(value)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct TasksView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Interrupted / resumable") {
                    if model.interruptedTasks.isEmpty {
                        Text("No interrupted task checkpoints")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.interruptedTasks) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.taskName).font(.headline)
                            Text("Step \(task.stepIndex)/\(task.totalSteps): \(task.stepName)")
                            Text(task.state).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Lifecycle") {
                    Text("Tasks are checkpointed. If iOS suspends or terminates the app, the next launch can identify the last durable step instead of assuming a Windows-style daemon stayed alive.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Tasks")
            .refreshable { await model.reloadActivity() }
        }
    }
}

private struct PhoneView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Capability Profile") {
                    ForEach(model.capabilities.records, id: \.id) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.id).font(.subheadline.monospaced())
                                Text(record.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(record.status.rawValue)
                                .font(.caption2.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .navigationTitle("Phone")
            .toolbar {
                Button("Probe") { model.refreshCapabilities() }
            }
        }
    }
}

private struct AppsView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            List(model.apps) { app in
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.displayName).font(.headline)
                    Text(app.ownerBundleID ?? app.logicalLocation)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let path = app.resolvedPath {
                        Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Apps")
            .toolbar { Button("Refresh") { model.refreshCapabilities() } }
        }
    }
}

private struct FilesView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("Path", text: $model.browsePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    Button("Open") {
                        do { try model.refreshFiles() } catch { model.lastError = String(describing: error) }
                    }
                }
                .padding()
                Divider()
                List(model.files) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if item.isDirectory {
                            model.browsePath = item.path
                            do { try model.refreshFiles() } catch { model.lastError = String(describing: error) }
                        }
                    }
                }
            }
            .navigationTitle("Files")
        }
    }
}

private struct ActivityView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            List(model.auditEvents) { event in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(event.action).font(.headline)
                        Spacer()
                        Text(event.result).font(.caption.monospaced())
                    }
                    if let target = event.target {
                        Text(target).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Activity")
            .refreshable { await model.reloadActivity() }
        }
    }
}

private struct TrashView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            List(model.trash) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.filename).font(.headline)
                    Text(record.originalPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file))
                        .font(.caption)
                    HStack {
                        Button("Restore") { model.restoreTrash(record) }
                        Button("Delete permanently", role: .destructive) { model.purgeTrash(record) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Trash")
            .refreshable { await model.reloadActivity() }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    TextField("Name", text: $model.providerName)
                    TextField("Base URL", text: $model.providerBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model", text: $model.providerModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key (stored in Keychain)", text: $model.providerAPIKey)
                    Button("Save Provider") { model.saveProvider() }
                }
                Section("Agent Permission") {
                    Picker("Mode", selection: $model.permissionMode) {
                        Text("Safe").tag(PermissionMode.safe)
                        Text("Balanced").tag(PermissionMode.balanced)
                        Text("Full / Don’t Ask").tag(PermissionMode.full)
                    }
                    Text(permissionExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("High privilege") {
                    Text("TrollStore/no-sandbox/root-helper capabilities are probed separately from Agent Permission. Full mode never grants a system capability that the device does not actually have.")
                        .font(.footnote)
                    Text("High-privilege entitlements and helper behavior remain DEVICE_VALIDATION_REQUIRED until verified on the target TrollStore iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var permissionExplanation: String {
        switch model.permissionMode {
        case .safe: return "Reads are generally allowed. Important modification, deletion, install/uninstall, external side effects and permanent deletion require approval."
        case .balanced: return "Ordinary writes can proceed; deletion goes to Cloud Code Trash. Important data and irreversible operations still require approval."
        case .full: return "The Agent may skip most confirmations, but Audit Log, transaction records and backups remain enabled when feasible. This mode must be selected by you."
        }
    }
}

private struct ApprovalSheet: View {
    let preview: ApprovalPreview
    @ObservedObject var approval: ApprovalCenter

    var body: some View {
        NavigationStack {
            List {
                Section("Target") {
                    Text(preview.target).font(.caption.monospaced()).textSelection(.enabled)
                    if let original = preview.originalSummary { Text(original) }
                }
                Section("Why") { Text(preview.reason) }
                if let diff = preview.diff {
                    Section("Diff") {
                        ScrollView(.horizontal) {
                            Text(diff).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section("Plan") {
                    ForEach(preview.plan, id: \.self) { Text($0) }
                }
                Section("Risk") { Text(preview.risk.rawValue) }
            }
            .navigationTitle(preview.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Deny") { approval.deny() } }
                ToolbarItem(placement: .confirmationAction) { Button("Approve") { approval.approve() } }
            }
        }
    }
}
