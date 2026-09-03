import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import UIKit
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
    @StateObject private var voice = VoiceInputController()
    @State private var input = ""
    @State private var showSessionHistory = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingImageData: Data?
    @State private var pendingImagePreview: UIImage?

    private var visibleMessages: [ChatMessage] {
        model.session.messages.filter { $0.role == .user || $0.role == .assistant }
    }

    var body: some View {
        NavigationStack {
            chatLayout
                .navigationTitle(model.session.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { chatToolbar }
                .sheet(isPresented: $showSessionHistory) {
                    SessionHistoryView(model: model, isPresented: $showSessionHistory)
                }
                .onChange(of: voice.recognizedText) { value in
                    if !value.isEmpty { input = value }
                }
                .onChange(of: voice.errorMessage) { value in
                    if let value, !value.isEmpty { model.lastError = value }
                }
                .onChange(of: selectedPhotoItem) { item in
                    loadSelectedPhoto(item)
                }
                .onDisappear { voice.stop() }
        }
    }

    private var chatLayout: some View {
        VStack(spacing: 0) {
            conversationPane
            Divider()
            composer
        }
    }

    private var conversationPane: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if visibleMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cloud Code iOS")
                            .font(.title2.bold())
                        Text("消息会按你和 Cloud Code 分开显示。长按消息文字后可以只选择并复制其中一部分。")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(visibleMessages) { message in
                        ChatBubble(message: message)
                    }
                }

                if model.isRunning && model.streamingAssistantMessageID == nil {
                    HStack {
                        ProgressView()
                        Text("Cloud Code 正在处理…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                if !model.activityLines.isEmpty {
                    Divider()
                    ForEach(Array(model.activityLines.suffix(5).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            pendingImageBanner
            inputRow
            if voice.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                    Text("正在语音转文字；停止后可继续修改再发送。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var pendingImageBanner: some View {
        if let pendingImagePreview {
            HStack(spacing: 10) {
                Image(uiImage: pendingImagePreview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("待发送图片")
                        .font(.caption.bold())
                    Text(ByteCountFormatter.string(fromByteCount: Int64(pendingImageData?.count ?? 0), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive, action: clearPendingImage) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Image(systemName: "photo")
                    .frame(width: 30, height: 30)
            }
            .disabled(model.isRunning)

            Button(action: toggleVoiceInput) {
                Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic")
                    .frame(width: 30, height: 30)
            }
            .disabled(model.isRunning)
            .accessibilityLabel(voice.isRecording ? "停止语音输入" : "开始语音输入")

            TextField("输入要让 Cloud Code 完成的任务…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)

            if model.isRunning {
                Button("停止") { model.cancelCurrentTask() }
                    .buttonStyle(.bordered)
            } else {
                Button("发送", action: sendCurrentInput)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showSessionHistory = true
            } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }
            .disabled(model.isRunning)

            Button(action: createNewConversation) {
                Label("新建对话", systemImage: "square.and.pencil")
            }
            .disabled(model.isRunning)
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImageData != nil
    }

    private func toggleVoiceInput() {
        if voice.isRecording {
            voice.stop()
        } else {
            voice.start(existingText: input)
        }
    }

    private func sendCurrentInput() {
        let value = input
        let image = pendingImageData
        input = ""
        clearPendingImage()
        voice.stop()
        model.send(value, imageData: image, imageMimeType: "image/jpeg", imageFilename: "photo.jpg")
    }

    private func createNewConversation() {
        input = ""
        clearPendingImage()
        voice.stop()
        model.createNewSession()
    }

    private func clearPendingImage() {
        pendingImageData = nil
        pendingImagePreview = nil
        selectedPhotoItem = nil
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let original = try await item.loadTransferable(type: Data.self),
                      let prepared = Self.prepareImageForSend(original),
                      let preview = UIImage(data: prepared) else {
                    model.lastError = "无法读取所选图片。"
                    return
                }
                pendingImageData = prepared
                pendingImagePreview = preview
            } catch {
                model.lastError = "读取图片失败：\(error.localizedDescription)"
            }
        }
    }

    private static func prepareImageForSend(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let limits: [(CGFloat, CGFloat)] = [(2048, 0.82), (1800, 0.72), (1600, 0.62), (1280, 0.55)]
        for (maxDimension, quality) in limits {
            let source = image.size
            let scale = min(1, maxDimension / max(source.width, source.height))
            let size = CGSize(width: max(1, source.width * scale), height: max(1, source.height * scale))
            let renderer = UIGraphicsImageRenderer(size: size)
            let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let encoded = resized.jpegData(compressionQuality: quality), encoded.count <= ChatMessageAttachmentPolicy.maxImageBytes {
                return encoded
            }
        }
        return nil
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 6) {
                Text(isUser ? "你" : "Cloud Code")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                ForEach(message.attachments) { attachment in
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: attachment.path)),
                       let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240, maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Label(attachment.filename, systemImage: "photo")
                            .font(.caption)
                    }
                }

                if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                        .font(.body)
                }
            }
            .padding(10)
            .background(isUser ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contextMenu {
                if !message.content.isEmpty {
                    Button("复制整条消息") {
                        UIPasteboard.general.string = message.content
                    }
                }
            }
            if !isUser { Spacer(minLength: 44) }
        }
    }
}

private struct SessionHistoryView: View {
    @ObservedObject var model: CloudCodeViewModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var pendingDelete: AgentSession?

    var body: some View {
        NavigationStack {
            List {
                if model.sessions(matching: query).isEmpty {
                    Text(query.isEmpty ? "暂无历史对话" : "没有匹配的对话")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sessions(matching: query)) { item in
                    Button {
                        model.openSession(item)
                        isPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.title).font(.headline).foregroundStyle(.primary)
                                Spacer()
                                if model.sessionHasUnfinishedTask(item.id) {
                                    Label("未完成", systemImage: "clock.badge.exclamationmark")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(sessionLastMessageSummary(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack(spacing: 8) {
                                Text(item.providerID ?? "厂商未记录")
                                Text(item.model ?? "模型未记录")
                                Spacer()
                                Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { pendingDelete = item }
                            .disabled(model.sessionHasUnfinishedTask(item.id))
                    }
                    .contextMenu {
                        Button("删除对话", role: .destructive) { pendingDelete = item }
                            .disabled(model.sessionHasUnfinishedTask(item.id))
                    }
                }
            }
            .navigationTitle("历史对话")
            .searchable(text: $query, prompt: "搜索标题或消息")
            .confirmationDialog(
                "删除这条历史对话？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pendingDelete {
                    Button("删除“\(pendingDelete.title)”", role: .destructive) {
                        model.deleteSession(pendingDelete)
                        self.pendingDelete = nil
                    }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("删除后会同时清理该对话保存的图片附件。包含未完成任务的对话必须先处理任务。")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("新建对话") {
                        model.createNewSession()
                        isPresented = false
                    }
                    .disabled(model.isRunning)
                }
            }
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

    private var buildLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("检测") {
                    HStack(spacing: 10) {
                        if model.isRefreshingCapabilities {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        Text(model.capabilityRefreshMessage ?? "尚未完成设备能力检测。")
                            .font(.subheadline)
                    }
                    LabeledContent("当前构建", value: buildLabel)
                        .font(.caption)
                    if let date = model.lastCapabilityRefreshAt {
                        LabeledContent("最近检测", value: date.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                    }
                    Text("“需要真机验证”表示当前 Runtime 没有足够证据自动证明该能力；不会为了显示全绿而把未验证能力标成可用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("“不可用”也可能只是当前版本尚未接入对应执行后端，不等同于 TrollStore 权限或签名失败；每一项下方会显示实际探测原因。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("能力状态") {
                    ForEach(model.capabilities.records, id: \.id) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(localizedCapabilityName(record.id)).font(.subheadline)
                                Text(record.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                Text(localizedCapabilityDetail(record.id, detail: record.detail)).font(.caption).foregroundStyle(.secondary)
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
                Button {
                    model.refreshCapabilities()
                } label: {
                    if model.isRefreshingCapabilities {
                        ProgressView()
                    } else {
                        Text("重新检测")
                    }
                }
                .disabled(model.isRefreshingCapabilities)
            }
        }
    }
}

private struct AppsView: View {
    @ObservedObject var model: CloudCodeViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("检测状态") {
                    HStack(spacing: 8) {
                        if model.isRefreshingCapabilities { ProgressView() }
                        Text(model.capabilityRefreshMessage ?? "尚未检测应用能力。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.capabilities.status("apps.enumerate") != .available {
                        Text("当前只能显示 Cloud Code 自身或已知记录。只有真机运行时实际枚举到其他 App 后，才会把“已安装 App 枚举”标记为可用。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("已发现应用") {
                    if model.apps.isEmpty {
                        Text("没有发现应用记录")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.apps) { app in
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
                }
            }
            .navigationTitle("应用")
            .refreshable { model.refreshCapabilities() }
            .toolbar {
                Button {
                    model.refreshCapabilities()
                } label: {
                    if model.isRefreshingCapabilities { ProgressView() } else { Text("刷新") }
                }
                .disabled(model.isRefreshingCapabilities)
            }
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
                    if !event.detail.isEmpty {
                        ForEach(event.detail.keys.sorted(), id: \.self) { key in
                            if let value = event.detail[key], !value.isEmpty {
                                Text("\(key): \(value)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
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
    @FocusState private var keyInputFocused: Bool

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
                        .focused($keyInputFocused)
                        .submitLabel(.done)
                        .onSubmit { keyInputFocused = false }
                    Button("保存当前 Key 到 Keychain") {
                        keyInputFocused = false
                        guard model.setKey(selectedKeyInput) else { return }
                        selectedKeyInput = ""
                    }
                    .disabled(selectedKeyInput.isEmpty || model.isProviderKeyMutationInFlight)

                    if model.bundledPrivateBootstrapAvailable {
                        Button("一键导入预配置 Key") {
                            keyInputFocused = false
                            model.importBundledProviderBootstrap()
                        }
                        .disabled(model.isProviderKeyMutationInFlight)
                    }

                    Button("从文件导入 Key 配置") {
                        keyInputFocused = false
                        showBootstrapImporter = true
                    }
                    .disabled(model.isProviderKeyMutationInFlight)

                    LabeledContent("已配置 Key", value: "\(model.configuredCatalogKeyCount) / \(model.totalCatalogKeyCount)")
                    Text(model.bundledPrivateBootstrapAvailable
                         ? "当前是私有 Key 版 IPA：首次启动会自动把预配置 Key 写入 iOS Keychain；也可以点上方按钮重新一键导入。厂商、Key 和模型仍由你手动选择。"
                         : "当前安装包未内置预配置 Key。可以从文件导入；导入后写入 iOS Keychain。真实 Key 不写入 UserDefaults。")
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
                    Text("高权限签名权限和辅助进程能力只有在当前 TrollStore iPhone 上实际探测成功后才会标记为“可用”；未证明的能力会显示为“需要真机验证”或“不可用”。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .onDisappear {
                keyInputFocused = false
                selectedKeyInput = ""
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { keyInputFocused = false }
                }
            }
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

private func sessionLastMessageSummary(_ session: AgentSession) -> String {
    let text = session.messages.reversed().first(where: {
        ($0.role == .user || $0.role == .assistant) && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? "暂无消息"
    return text.count <= 80 ? text : String(text.prefix(80)) + "…"
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

private func localizedCapabilityName(_ id: String) -> String {
    switch id {
    case "filesystem.own_container": return "本 App 容器读写"
    case "filesystem.shared_user_files": return "共享用户文件访问"
    case "filesystem.unrestricted": return "扩展文件系统访问"
    case "apps.enumerate": return "已安装 App 枚举"
    case "apps.resolve_own_bundle_path": return "本 App 安装路径解析"
    case "apps.resolve_own_data_container": return "本 App 数据目录解析"
    case "apps.resolve_bundle_path": return "其他 App 安装路径解析"
    case "apps.resolve_data_container": return "其他 App 数据目录解析"
    case "execution.ios_system": return "iOS 系统命令执行接口"
    case "execution.posix_spawn_symbol": return "进程创建接口"
    case "execution.spawn_helper": return "辅助进程启动"
    case "execution.root_helper": return "高权限辅助进程"
    case "execution.jit_wasm": return "JIT / WASM 运行能力"
    case "apps.launch": return "启动其他 App"
    case "apps.terminate": return "终止其他 App"
    case "apps.uninstall": return "卸载其他 App"
    case "data.photos": return "照片访问"
    case "data.contacts": return "联系人访问"
    case "data.calendar": return "日历访问"
    case "data.keychain_scope": return "本 App Keychain"
    case "automation.url_scheme": return "URL Scheme 自动化"
    case "automation.xctest_wda": return "XCTest / WDA 自动化"
    case "automation.gui": return "GUI 自动化"
    case "ipa.inspect": return "IPA 检查"
    case "ipa.decrypt": return "IPA 解密"
    case "ipa.install": return "IPA 安装"
    default: return id
    }
}

private func localizedCapabilityDetail(_ id: String, detail: String) -> String {
    switch id {
    case "filesystem.own_container": return "检测当前 App 主目录是否可读写。"
    case "filesystem.shared_user_files": return "检测用户媒体目录的读取权限；实际范围取决于当前签名权限和设备。"
    case "filesystem.unrestricted": return "保守检测 /var/mobile 等扩展目录访问；可访问不等于具有 root 身份。"
    case "apps.enumerate":
        if detail.contains("verified") || detail.contains("返回") {
            let count = detail.split(separator: " ").first(where: { Int($0) != nil }).map(String.init) ?? "若干"
            return "已安装 App 枚举接口已通过跨 App 可见性验证，当前检测到 \(count) 个 App。"
        }
        return "当前只能看到本 App 或回退结果，尚未证明可以枚举其他已安装 App。"
    case "apps.resolve_own_bundle_path": return "检测 Cloud Code 自身安装路径是否可以解析。"
    case "apps.resolve_own_data_container": return "检测 Cloud Code 自身数据目录是否可以解析。"
    case "apps.resolve_bundle_path": return detail.contains("Resolved") ? "已成功解析至少一个其他 App 的安装路径。" : "当前运行环境尚未证明可以解析其他 App 的安装路径。"
    case "apps.resolve_data_container": return detail.contains("Resolved") ? "已成功解析至少一个其他 App 的数据目录；目录会动态解析，不缓存容器 UUID。" : "当前运行环境尚未证明可以解析其他 App 的数据目录。"
    case "execution.ios_system": return "动态检测 ios_system 接口；结构化工具不会依赖它。"
    case "execution.posix_spawn_symbol": return "只检测进程创建符号是否存在，不代表已经获得越过沙盒或高权限执行能力。"
    case "execution.spawn_helper":
        return detail.contains("does not bundle") ? "当前安装包没有内置辅助程序，因此这项能力现在不可用。" : "需要安装包内辅助程序、签名权限和当前设备共同验证后才能启用。"
    case "execution.root_helper":
        return detail.contains("does not bundle") ? "当前安装包没有 root helper；TrollStore 安装本身不会自动提供 root helper。" : "需要当前 TrollStore 设备上的高权限签名和辅助程序实际握手成功。"
    case "execution.jit_wasm":
        return detail.contains("No WASM/JIT") ? "当前版本没有接入 WASM / JIT 执行后端，因此不可用。" : "JIT / WASM 能力取决于设备版本、签名方式和权限。"
    case "apps.launch":
        return detail.contains("No app-launch executor") ? "当前版本没有接入启动其他 App 的执行器，因此不可用。" : "启动其他 App 的私有接口需要在当前设备上验证后才能使用。"
    case "apps.terminate":
        return detail.contains("No app-termination executor") ? "当前版本没有接入终止其他 App 的执行器，因此不可用。" : "终止其他 App 属于系统级变更，必须在当前设备上验证并受权限策略保护。"
    case "apps.uninstall":
        if detail.contains("prerequisites are present") { return "已检测到卸载后端所需的 LaunchServices 枚举、安装状态查询和卸载接口；真正卸载时仍会要求确认并在操作后重新查询验证。" }
        if detail.contains("not currently executable") { return "当前卸载后端没有达到可执行条件；请展开本次检测结果判断是枚举、LaunchServices 接口还是安装状态查询缺失。" }
        return "卸载属于永久性破坏操作；只有运行时探测达到可执行条件时才允许进入确认和执行流程。"
    case "data.photos": return "照片权限由你控制；只有授权后才会开放对应访问。"
    case "data.contacts": return "联系人权限受系统授权控制，核心不会自动请求。"
    case "data.calendar": return "日历权限受系统授权控制，核心不会自动请求。"
    case "data.keychain_scope":
        if detail.contains("-34018") { return "当前安装签名缺少 Keychain 身份/访问组授权，因此不能保存或读取厂商 Key。" }
        if detail.contains("write succeeded") { return "Keychain 写入成功，但读取回验失败，当前不能把它当成可用。" }
        if detail.contains("currently unavailable") { return "Keychain 当前受保护不可访问（例如设备锁定）；解锁后重新检测。" }
        if detail.contains("Verified on this runtime") { return "已在当前设备实际完成临时写入、读取和删除回验；Cloud Code 自身 Keychain 可用。" }
        return "正在按当前设备实际结果判断 Cloud Code 自身 Keychain，不再仅凭配置假定可用。"
    case "automation.url_scheme":
        return detail.contains("disabled placeholder") ? "当前 URL Scheme 执行器只是禁用占位实现，因此现在不可用。" : "只有 URL 打开适配器真实接入并验证后才会启用。"
    case "automation.xctest_wda":
        return detail.contains("No XCTest/WDA") ? "当前版本没有接入 XCTest / WDA 运行后端，因此不可用。" : "需要独立的 XCTest / WDA 运行后端。"
    case "automation.gui":
        return detail.contains("explicitly unavailable") ? "当前 GUI 自动化后端明确处于不可用状态，没有连接可执行的自动化运行时。" : "GUI 自动化只有在后端实际就绪并通过探测后才会启用。"
    case "ipa.inspect": return "可在本地进程内检查 IPA 的 ZIP、Info.plist、架构和签名元数据。"
    case "ipa.decrypt":
        return detail.contains("No IPA decryption executor") ? "当前版本没有接入 IPA 解密执行器，因此不可用。" : "解密需要兼容的高权限运行环境以及可访问的目标进程。"
    case "ipa.install":
        return detail.contains("No IPA installation executor") ? "当前版本没有接入 IPA 安装执行器，因此不可用。" : "安装 IPA 依赖 TrollStore 或其他已验证的高权限安装能力。"
    default: return detail
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
