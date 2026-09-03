import SwiftUI
import UniformTypeIdentifiers
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
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
            TasksView(model: model)
                .tabItem { Label("任务", systemImage: "checklist") }
            PhoneView(model: model)
                .tabItem { Label("设备", systemImage: "iphone") }
            AppsView(model: model)
                .tabItem { Label("应用", systemImage: "square.grid.2x2") }
            FilesView(model: model)
                .tabItem { Label("文件", systemImage: "folder") }
            ActivityView(model: model)
                .tabItem { Label("记录", systemImage: "waveform.path.ecg") }
            TrashView(model: model)
                .tabItem { Label("回收站", systemImage: "trash") }
            SettingsView(model: model)
                .tabItem { Label("设置", systemImage: "gearshape") }
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
            Button("知道了", role: .cancel) { model.lastError = nil }
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
                            Text("本地工具优先 Agent。优先使用结构化工具、文件系统和容器能力，只有必要时才回退到 GUI 自动化。")
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
                    TextField("输入要让 Cloud Code 完成的任务…", text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                    if model.isRunning {
                        Button("停止") { model.cancelCurrentTask() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("发送") {
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
            .navigationTitle("对话")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct TasksView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("中断 / 可恢复") {
                    if model.interruptedTasks.isEmpty {
                        Text("暂无中断任务检查点")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.interruptedTasks) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(localizedTaskName(task.taskName)).font(.headline)
                            Text("步骤 \(task.stepIndex)/\(task.totalSteps)：\(localizedTaskStepName(task.stepName))")
                            Text(localizedCheckpointState(task.state)).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("继续") { model.resumeTask(task) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.isRunning || model.isCheckpointOperationInFlight(task.id))
                                Button("回滚") { model.rollbackTask(task) }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isCheckpointOperationInFlight(task.id))
                                Button("取消", role: .destructive) { model.cancelInterruptedTask(task) }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isCheckpointOperationInFlight(task.id))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("生命周期") {
                    Text("任务会保存检查点。iOS 暂停或终止 App 后，下次启动会识别最后一个可靠步骤，而不是假设后台进程一直存活。")
                        .font(.footnote)
                }
            }
            .navigationTitle("任务")
            .refreshable { await model.reloadActivity() }
        }
    }
}

private struct PhoneView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("能力状态") {
                    ForEach(model.capabilities.records, id: \.id) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.id).font(.subheadline.monospaced())
                                Text(record.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(localizedCapabilityStatus(record.status.rawValue))
                                .font(.caption2.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .navigationTitle("设备")
            .toolbar {
                Button("重新检测") { model.refreshCapabilities() }
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
            .navigationTitle("应用")
            .toolbar { Button("刷新") { model.refreshCapabilities() } }
        }
    }
}

private struct FilesView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("路径", text: $model.browsePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                    Button("打开") {
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
            .navigationTitle("文件")
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
            .navigationTitle("操作记录")
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
                        Button("恢复") { model.restoreTrash(record) }
                            .disabled(model.isTrashOperationInFlight(record.id))
                        Button("永久删除", role: .destructive) { model.purgeTrash(record) }
                            .disabled(model.isTrashOperationInFlight(record.id))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("回收站")
            .refreshable { await model.reloadActivity() }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: CloudCodeViewModel
    @State private var selectedKeyInput = ""
    @State private var customModelInput = ""
    @State private var showCustomProvider = false
    @State private var showBootstrapImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("厂商 / Key / 模型") {
                    Picker("厂商", selection: Binding(
                        get: { model.selectedProviderID },
                        set: { model.selectProvider($0) }
                    )) {
                        ForEach(model.providerProfiles.filter(\.enabled)) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }

                    Picker("Key", selection: Binding(
                        get: { model.selectedKeySlotID },
                        set: { model.selectKey($0) }
                    )) {
                        ForEach(model.availableKeySlots) { slot in
                            let installed = model.isKeyInstalled(providerID: model.selectedProviderID, keySlotID: slot.id)
                            Text("\(slot.label) · \(installed ? "已配置" : "未配置") · \(localizedKeyStatus(slot.status.rawValue))").tag(slot.id)
                        }
                    }
                    .disabled(model.availableKeySlots.isEmpty)

                    Picker("模型", selection: Binding(
                        get: { model.selectedModel },
                        set: { model.selectModel($0) }
                    )) {
                        ForEach(model.availableModels, id: \.self) { modelID in
                            Text(modelID).tag(modelID)
                        }
                        if model.selectedProvider?.customModelAllowed == true,
                           !model.selectedModel.isEmpty,
                           !model.availableModels.contains(model.selectedModel) {
                            Text("自定义 · \(model.selectedModel)").tag(model.selectedModel)
                        }
                    }
                    .disabled(model.availableModels.isEmpty)

                    if let provider = model.selectedProvider {
                        LabeledContent("厂商状态", value: localizedProviderStatus(provider.readiness.rawValue))
                        LabeledContent("当前 Key", value: model.selectedKeyIsInstalled ? "已配置" : "未配置")
                    }
                    LabeledContent("配置规模", value: "\(model.providerProfiles.filter(\.enabled).count) 个厂商 · \(model.providerProfiles.filter(\.enabled).reduce(0) { $0 + $1.keySlots.count }) 个 Key")
                }

                Section("Key 管理") {
                    SecureField("替换当前选择的 Key", text: $selectedKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存当前 Key 到 Keychain") {
                        guard model.setKey(selectedKeyInput) else { return }
                        selectedKeyInput = ""
                    }
                    .disabled(selectedKeyInput.isEmpty || model.isProviderKeyMutationInFlight)

                    Button("导入私有 Key 配置") { showBootstrapImporter = true }
                        .disabled(model.isProviderKeyMutationInFlight)
                    Text("厂商、Key 和模型都由你手动选择。私有 Key 配置导入后写入 iOS Keychain，明文配置源会被删除；真实 Key 不写入 UserDefaults，也不会随公开 IPA 分发。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if model.selectedProvider?.customModelAllowed == true {
                    Section("自定义模型") {
                        TextField("模型 ID", text: $customModelInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("使用自定义模型") {
                            let value = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            model.selectModel(value)
                            customModelInput = ""
                        }
                        .disabled(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("厂商管理") {
                    Button("添加自定义厂商") { showCustomProvider = true }
                        .disabled(model.isProviderKeyMutationInFlight)
                }

                Section("高级") {
                    LabeledContent("协议", value: model.selectedProtocol?.rawValue ?? "待验证")
                    if let provider = model.selectedProvider {
                        Text(provider.baseURL.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("协议由已验证的厂商 / Key / 模型元数据决定。禁止自动跨厂商故障切换。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Agent 权限") {
                    Picker("模式", selection: $model.permissionMode) {
                        Text("安全").tag(PermissionMode.safe)
                        Text("平衡").tag(PermissionMode.balanced)
                        Text("完全 / 不询问").tag(PermissionMode.full)
                    }
                    Text(permissionExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("高权限能力") {
                    Text("TrollStore、no-sandbox、root-helper 等能力与 Agent 权限分开检测。即使选择“完全”模式，也不会凭空获得设备实际不存在的系统能力。")
                        .font(.footnote)
                    Text("高权限 entitlement 和 helper 行为在目标 TrollStore iPhone 真机验证前仍保持 DEVICE_VALIDATION_REQUIRED。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showCustomProvider) {
                CustomProviderSheet(model: model, isPresented: $showCustomProvider)
            }
            .fileImporter(isPresented: $showBootstrapImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): model.importProviderBootstrap(from: url)
                case .failure(let error): model.lastError = String(describing: error)
                }
            }
        }
    }

    private var permissionExplanation: String {
        switch model.permissionMode {
        case .safe: return "通常允许读取。重要修改、删除、安装/卸载、外部副作用和永久删除都需要你确认。"
        case .balanced: return "普通写入可以直接执行；删除会进入 Cloud Code 回收站。重要数据和不可逆操作仍需要确认。"
        case .full: return "Agent 可以跳过大多数确认，但会尽可能保留审计记录、事务记录和备份。此模式只能由你手动选择。"
        }
    }
}

private struct CustomProviderSheet: View {
    @ObservedObject var model: CloudCodeViewModel
    @Binding var isPresented: Bool
    @State private var label = ""
    @State private var baseURL = ""
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("自定义厂商") {
                    TextField("名称", text: $label)
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("Cloud Code 会发现 /v1/models，并使用最小请求验证 Anthropic Messages、OpenAI Chat 和 OpenAI Responses。Key 只保存到 Keychain。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加厂商")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        model.addCustomProvider(label: label, baseURLText: baseURL, apiKey: apiKey)
                        apiKey = ""
                        isPresented = false
                    }
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL.isEmpty || apiKey.isEmpty || model.isProviderKeyMutationInFlight)
                }
            }
        }
    }
}

private struct ApprovalSheet: View {
    let preview: ApprovalPreview
    @ObservedObject var approval: ApprovalCenter

    var body: some View {
        NavigationStack {
            List {
                Section("目标") {
                    Text(preview.target).font(.caption.monospaced()).textSelection(.enabled)
                    if let original = preview.originalSummary { Text(original) }
                }
                Section("原因") { Text(preview.reason) }
                if let diff = preview.diff {
                    Section("差异") {
                        ScrollView(.horizontal) {
                            Text(diff).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section("执行计划") {
                    ForEach(preview.plan, id: \.self) { Text($0) }
                }
                Section("风险") { Text(localizedRisk(preview.risk.rawValue)) }
            }
            .navigationTitle(preview.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("拒绝") { approval.deny() } }
                ToolbarItem(placement: .confirmationAction) { Button("批准") { approval.approve() } }
            }
        }
    }
}

private func localizedProviderStatus(_ value: String) -> String {
    switch value {
    case "READY": return "可用"
    case "PARTIAL": return "部分可用"
    case "UNAVAILABLE": return "不可用"
    case "AUTH_FAILED": return "认证失败"
    case "CAPACITY": return "额度 / 容量不足"
    case "NEEDS_VALIDATION": return "待验证"
    default: return value
    }
}

private func localizedKeyStatus(_ value: String) -> String {
    switch value {
    case "verified": return "已验证"
    case "unknown": return "未知"
    case "unavailable": return "不可用"
    case "auth_failed": return "认证失败"
    case "capacity": return "额度 / 容量不足"
    case "needs_validation": return "待验证"
    default: return value
    }
}

private func localizedCapabilityStatus(_ value: String) -> String {
    switch value {
    case "available": return "可用"
    case "unavailable": return "不可用"
    case "unknown": return "未知"
    case "device_validation_required": return "需要真机验证"
    default: return value
    }
}

private func localizedTaskName(_ value: String) -> String {
    switch value {
    case "Agent request": return "Agent 请求"
    default: return value
    }
}

private func localizedTaskStepName(_ value: String) -> String {
    if value.hasPrefix("agent round ") {
        return value.replacingOccurrences(of: "agent round ", with: "Agent 轮次 ")
    }
    if value.hasPrefix("resuming: ") {
        return value.replacingOccurrences(of: "resuming: capability re-probe", with: "继续前重新检测能力")
    }
    switch value {
    case "capability probe": return "能力检测"
    case "completed": return "已完成"
    case "cancelled by lifecycle": return "因生命周期变化而取消"
    case "failed": return "失败"
    case "recovered after app restart": return "App 重启后恢复"
    case "用户取消": return "用户取消"
    case "最近一次已提交事务已回滚": return "最近一次已提交事务已回滚"
    default: return value
    }
}

private func localizedCheckpointState(_ value: String) -> String {
    switch value {
    case "running": return "运行中"
    case "interrupted": return "已中断"
    case "completed": return "已完成"
    case "cancelled": return "已取消"
    case "rolled_back": return "已回滚"
    default: return value
    }
}

private func localizedRisk(_ value: String) -> String {
    switch value {
    case "readOnly": return "只读"
    case "safeWrite": return "普通写入"
    case "sensitiveWrite": return "重要写入"
    case "destructive": return "破坏性操作"
    case "permanentDestructive": return "永久破坏性操作"
    case "systemChange": return "系统变更"
    default: return value
    }
}
