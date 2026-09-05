import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import UIKit
import CloudCodeCore

struct ContentView: View {
    private enum RootTab: Hashable {
        case chat, tasks, device, settings, more
    }

    @ObservedObject var model: CloudCodeViewModel
    @ObservedObject private var approval: ApprovalCenter
    @State private var selectedTab: RootTab = .chat

    init(model: CloudCodeViewModel) {
        self.model = model
        self.approval = model.approvalCenter
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView(model: model)
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                .tag(RootTab.chat)
            TasksView(model: model)
                .tabItem { Label("任务", systemImage: "checklist") }
                .tag(RootTab.tasks)
            PhoneView(model: model)
                .tabItem { Label("设备", systemImage: "iphone") }
                .tag(RootTab.device)
            SettingsView(model: model)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(RootTab.settings)
            MoreView(model: model)
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }
                .tag(RootTab.more)
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
            if model.hasCurrentProviderFailure {
                if model.canRetryCurrentProviderFailure {
                    Button("重试") { model.retryCurrentProviderFailure() }
                } else {
                    Button("查看检查点") {
                        model.lastError = nil
                        selectedTab = .tasks
                    }
                }
                Button("切换厂商") {
                    model.lastError = nil
                    selectedTab = .settings
                }
            }
            Button("知道了", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

private struct MoreView: View {
    private enum Destination: String, Identifiable {
        case apps, files, memory, activity, trash

        var id: String { rawValue }
    }

    @ObservedObject var model: CloudCodeViewModel
    @State private var destination: Destination?

    var body: some View {
        NavigationStack {
            List {
                Section("工具") {
                    moreButton(.apps, title: "应用", systemImage: "square.grid.2x2", subtitle: "查看已安装应用与应用能力")
                    moreButton(.files, title: "文件", systemImage: "folder", subtitle: "浏览当前可访问的文件系统")
                    moreButton(.memory, title: "Hermes 记忆", systemImage: "books.vertical", subtitle: "查看、检索和维护本地记忆")
                }
                Section("维护") {
                    moreButton(.activity, title: "记录", systemImage: "waveform.path.ecg", subtitle: "查看任务与事务活动")
                    moreButton(.trash, title: "回收站", systemImage: "trash", subtitle: "恢复或永久删除回收内容")
                }
            }
            .navigationTitle("更多")
            .sheet(item: $destination) { item in
                switch item {
                case .apps:
                    AppsView(model: model)
                case .files:
                    FilesView(model: model)
                case .memory:
                    HermesVaultView(model: model)
                case .activity:
                    ActivityView(model: model)
                case .trash:
                    TrashView(model: model)
                }
            }
        }
    }

    private func moreButton(_ target: Destination, title: String, systemImage: String, subtitle: String) -> some View {
        Button {
            destination = target
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ChatView: View {
    @ObservedObject var model: CloudCodeViewModel
    @StateObject private var voice = VoiceInputController()
    @State private var input = ""
    @State private var showSessionHistory = false
    @State private var showDiagnostics = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingImageData: Data?
    @State private var pendingImagePreview: UIImage?
    @State private var isConversationAtBottom = true

    private let conversationBottomID = "cloudcode-conversation-bottom"

    private var visibleMessages: [ChatMessage] {
        model.session.messages.filter {
            ($0.role == .user || $0.role == .assistant)
                && $0.providerMetadata["internal_observation"] == nil
        }
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
                .sheet(isPresented: $showDiagnostics) {
                    NavigationStack {
                        DiagnosticLogsView(model: model)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("关闭") { showDiagnostics = false }
                                }
                            }
                    }
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
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
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

                        if model.isCurrentSessionRunning && model.streamingAssistantMessageID == nil {
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

                        Color.clear
                            .frame(height: 1)
                            .id(conversationBottomID)
                            .onAppear { isConversationAtBottom = true }
                            .onDisappear { isConversationAtBottom = false }
                    }
                    .padding()
                }
                .onAppear {
                    isConversationAtBottom = true
                    scrollConversationToBottom(proxy, animated: false)
                }
                .onChange(of: model.session.id) { _ in
                    isConversationAtBottom = true
                    scrollConversationToBottom(proxy, animated: false)
                }
                .onChange(of: visibleMessages.last?.content) { _ in
                    if isConversationAtBottom {
                        scrollConversationToBottom(proxy, animated: true)
                    }
                }
                .onChange(of: model.activityLines.last) { _ in
                    if isConversationAtBottom {
                        scrollConversationToBottom(proxy, animated: true)
                    }
                }

                if !isConversationAtBottom && !visibleMessages.isEmpty {
                    Button {
                        scrollConversationToBottom(proxy, animated: true)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.headline.weight(.semibold))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("回到对话底部")
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func scrollConversationToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.20)) {
                    proxy.scrollTo(conversationBottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(conversationBottomID, anchor: .bottom)
            }
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

            Button(action: toggleVoiceInput) {
                Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic")
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel(voice.isRecording ? "停止语音输入" : "开始语音输入")

            TextField("输入要让 Cloud Code 完成的任务…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)

            Button(model.isCurrentSessionRunning ? "追加" : "发送", action: sendCurrentInput)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)

            if model.isCurrentSessionRunning {
                Button("停止") { model.cancelCurrentTask() }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showDiagnostics = true
            } label: {
                Label("日志", systemImage: "doc.text.magnifyingglass")
            }

            Button {
                showSessionHistory = true
            } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }

            Button(action: createNewConversation) {
                Label("新建对话", systemImage: "square.and.pencil")
            }
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
                                if model.isSessionRunning(item.id) {
                                    Label("运行中", systemImage: "play.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if model.sessionHasUnfinishedTask(item.id) {
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
                            .disabled(model.isSessionRunning(item.id) || model.sessionHasUnfinishedTask(item.id))
                    }
                    .contextMenu {
                        Button("删除对话", role: .destructive) { pendingDelete = item }
                            .disabled(model.isSessionRunning(item.id) || model.sessionHasUnfinishedTask(item.id))
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
                                    .disabled(model.isSessionRunning(task.sessionID) || model.isCheckpointOperationInFlight(task.id))
                                Button("回滚") { model.rollbackTask(task) }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isSessionRunning(task.sessionID) || model.isCheckpointOperationInFlight(task.id))
                                Button("取消", role: .destructive) { model.cancelInterruptedTask(task) }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isSessionRunning(task.sessionID) || model.isCheckpointOperationInFlight(task.id))
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

private struct HermesVaultView: View {
    @ObservedObject var model: CloudCodeViewModel
    @State private var query = ""
    @State private var showEditor = false
    @State private var editingRecord: HermesMemoryRecord?
    @State private var showImporter = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            List {
                if let status = model.hermesStatusMessage, !status.isEmpty {
                    Section {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if !model.hermesProjects.isEmpty {
                    Section("Projects") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(model.hermesProjects, id: \.self) { project in
                                    Text(project)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(.thinMaterial, in: Capsule())
                                }
                            }
                        }
                    }
                }

                Section(model.hermesRecords.isEmpty ? "记忆" : "记忆 · \(model.hermesRecords.count)") {
                    if model.hermesRecords.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("还没有 Hermes 记忆", systemImage: "books.vertical")
                                .font(.headline)
                            Text("可以新建 Markdown 记忆，或导入 Markdown / Obsidian Vault。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(model.hermesRecords) { record in
                            Button {
                                editingRecord = record
                                showEditor = true
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        if record.pinned { Image(systemName: "pin.fill") }
                                        Text(record.title).font(.headline)
                                        Spacer()
                                        Text(record.kind.displayName).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(record.body)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                    HStack(spacing: 8) {
                                        if let project = record.project { Text(project) }
                                        ForEach(record.tags.prefix(3), id: \.self) { tag in Text("#\(tag)") }
                                        Spacer()
                                        Text(record.updatedAt.formatted(date: .abbreviated, time: .omitted))
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(record.pinned ? "取消固定" : "固定") {
                                    model.setHermesPinned(record, pinned: !record.pinned)
                                }
                                Button("删除", role: .destructive) { model.deleteHermesMemory(record) }
                            }
                        }
                    }
                }

                if !model.hermesTags.isEmpty {
                    Section("Tags") {
                        Text(model.hermesTags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("导入 / 导出") {
                    Button("导入 Markdown / Obsidian Vault") { showImporter = true }
                    Button("准备导出 Markdown") {
                        Task { exportURL = await model.prepareHermesExportFile() }
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("分享 Hermes-Export.md", systemImage: "square.and.arrow.up")
                        }
                    }
                    Text("知识库保存在 Application Support/CloudCode/Hermes/。Markdown 是可读源文件，SQLite FTS 用于本地检索；升级 IPA 不会主动删除该目录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Hermes")
            .searchable(text: $query, prompt: "搜索记忆、项目、标签")
            .onChange(of: query) { value in Task { await model.reloadHermes(query: value) } }
            .refreshable { await model.reloadHermes(query: query) }
            .task { if model.hermesRecords.isEmpty { await model.reloadHermes() } }
            .toolbar {
                Button {
                    editingRecord = nil
                    showEditor = true
                } label: { Image(systemName: "square.and.pencil") }
            }
            .sheet(isPresented: $showEditor) {
                HermesMemoryEditor(model: model, existing: editingRecord, isPresented: $showEditor)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder, .plainText]) { result in
                switch result {
                case .success(let url): model.importHermesMarkdown(from: url)
                case .failure(let error): model.lastError = "Hermes 导入失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

private struct HermesMemoryEditor: View {
    @ObservedObject var model: CloudCodeViewModel
    let existing: HermesMemoryRecord?
    @Binding var isPresented: Bool
    @State private var kind: HermesMemoryKind
    @State private var title: String
    @State private var bodyText: String
    @State private var project: String
    @State private var tagsText: String
    @State private var pinned: Bool
    @State private var hasExpiry: Bool
    @State private var expiry: Date

    init(model: CloudCodeViewModel, existing: HermesMemoryRecord?, isPresented: Binding<Bool>) {
        self.model = model
        self.existing = existing
        self._isPresented = isPresented
        _kind = State(initialValue: existing?.kind ?? .projectMemory)
        _title = State(initialValue: existing?.title ?? "")
        _bodyText = State(initialValue: existing?.body ?? "")
        _project = State(initialValue: existing?.project ?? "")
        _tagsText = State(initialValue: existing?.tags.joined(separator: ", ") ?? "")
        _pinned = State(initialValue: existing?.pinned ?? false)
        _hasExpiry = State(initialValue: existing?.expiresAt != nil)
        _expiry = State(initialValue: existing?.expiresAt ?? Date().addingTimeInterval(24 * 60 * 60))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("类型") {
                    Picker("记忆类型", selection: $kind) {
                        ForEach(HermesMemoryKind.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                }
                Section("内容") {
                    TextField("标题", text: $title)
                    TextField("Project（可选）", text: $project)
                    TextField("Tags，以逗号分隔", text: $tagsText)
                    TextEditor(text: $bodyText).frame(minHeight: 220)
                    Toggle("固定", isOn: $pinned)
                }
                Section("过期") {
                    Toggle("设置过期时间", isOn: $hasExpiry)
                    if hasExpiry { DatePicker("过期时间", selection: $expiry) }
                    Text("Temporary Context 建议设置过期时间；过期记录会从检索和上下文中自动清理。相同类型、标题和 Project 的新记录会让旧记录进入 superseded 状态。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existing == nil ? "新建记忆" : "编辑记忆")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let tags = tagsText.split(separator: ",").map(String.init)
                        model.saveHermesMemory(
                            id: existing?.id,
                            kind: kind,
                            title: title,
                            body: bodyText,
                            project: project,
                            tags: tags,
                            pinned: pinned,
                            expiresAt: hasExpiry ? expiry : nil
                        )
                        isPresented = false
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
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
                            let presence = model.keyPresenceLabel(providerID: model.selectedProviderID, keySlotID: slot.id)
                            Text("\(slot.label) · \(presence) · \(localizedKeyStatus(slot.status.rawValue))").tag(slot.id)
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

                    Picker("推理强度", selection: Binding(
                        get: { model.selectedReasoningEffort },
                        set: { model.selectReasoningEffort($0) }
                    )) {
                        ForEach(ModelReasoningEffort.allCases, id: \.self) { effort in
                            Text(localizedReasoningEffort(effort)).tag(effort)
                        }
                    }

                    if let provider = model.selectedProvider {
                        LabeledContent("厂商状态", value: localizedProviderStatus(provider.readiness.rawValue))
                        if let health = model.selectedProviderEndpointHealth {
                            let detail = health.state == .healthy
                                ? "正常"
                                : "异常 / 需检查" + (health.errorCode.map { " · \($0)" } ?? "")
                            LabeledContent("接口健康", value: detail)
                        }
                        LabeledContent("当前 Key", value: model.selectedKeyIsInstalled ? "本次已确认" : "启动未扫描")
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
                        let value = selectedKeyInput
                        Task {
                            guard await model.setKey(value) else { return }
                            selectedKeyInput = ""
                        }
                    }
                    .disabled(selectedKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isProviderKeyMutationInFlight)

                    Button("检查当前 Key") {
                        keyInputFocused = false
                        Task { _ = await model.verifySelectedKeyPresence() }
                    }
                    .disabled(model.availableKeySlots.isEmpty || model.isProviderKeyMutationInFlight)

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

                    LabeledContent("本次已确认 Key", value: "\(model.configuredCatalogKeyCount) / \(model.totalCatalogKeyCount)")
                    Text(model.bundledPrivateBootstrapAvailable
                         ? "当前是私有 Key 版 IPA。为避免 TrollStore 真机启动阶段触发 Keychain 问题，任何启动都不会自动读取、遍历、迁移或覆盖 Provider Keychain。需要使用安装包内置 Key 时，请显式点“一键导入预配置 Key”；已有 Key 可先点“检查当前 Key”。"
                         : "当前安装包未内置预配置 Key。任何启动都不会自动扫描 Provider Keychain；可以手动检查当前 Key 或从文件导入。真实 Key 不写入 UserDefaults。")
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

                Section("诊断") {
                    NavigationLink {
                        DiagnosticLogsView(model: model)
                    } label: {
                        Label("日志", systemImage: "doc.text.magnifyingglass")
                    }
                    Text("结构化日志仅保存在本机，默认保留 72 小时且总量约 100 MB；写入和导出都会脱敏。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .onAppear { model.recordStartupBreadcrumb("settings.appear") }
            .onDisappear {
                model.recordStartupBreadcrumb("settings.disappear")
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

private struct DiagnosticLogsView: View {
    @ObservedObject var model: CloudCodeViewModel
    @State private var query = ""
    @State private var selectedSessionID: UUID?
    @State private var selectedToolCallID: UUID?
    @State private var selectedLevel: DiagnosticLogLevel?
    @State private var statusMessage: String?
    @State private var shareItem: DiagnosticShareItem?
    @State private var isExporting = false
    @State private var isConfirmingClear = false

    private var sessionIDs: [UUID] {
        Array(Set(model.diagnosticLogs.compactMap(\.sessionID))).sorted { $0.uuidString < $1.uuidString }
    }

    private var toolCallIDs: [UUID] {
        Array(Set(model.diagnosticLogs.compactMap(\.toolCallID))).sorted { $0.uuidString < $1.uuidString }
    }

    private var visibleLogs: [DiagnosticLogRecord] {
        model.filteredDiagnosticLogs(
            query: query,
            sessionID: selectedSessionID,
            toolCallID: selectedToolCallID,
            level: selectedLevel
        )
    }

    var body: some View {
        List {
            Section("操作") {
                HStack {
                    Button("复制诊断日志") {
                        Task {
                            UIPasteboard.general.string = await model.diagnosticTextForAll()
                            statusMessage = "已复制脱敏后的诊断日志。"
                        }
                    }
                    Button("复制最近一次任务日志") {
                        Task {
                            UIPasteboard.general.string = await model.diagnosticTextForMostRecentTask()
                            statusMessage = "已复制当前会话的脱敏日志。"
                        }
                    }
                }
                Button("复制闪退线索") {
                    Task {
                        UIPasteboard.general.string = await model.crashRecoveryDiagnosticText()
                        statusMessage = "已复制轻量闪退线索（启动 breadcrumbs + 最近日志）。"
                    }
                }
                Button {
                    guard !isExporting else { return }
                    isExporting = true
                    Task {
                        defer { isExporting = false }
                        do {
                            let url = try await model.exportDiagnosticBundle()
                            shareItem = DiagnosticShareItem(url: url)
                            statusMessage = "诊断包已生成，可保存到“文件”App或分享。"
                        } catch {
                            model.lastError = "导出诊断包失败：\(error)"
                        }
                    }
                } label: {
                    HStack {
                        if isExporting { ProgressView() }
                        Text("导出诊断包")
                    }
                }
                .disabled(isExporting)
                Button("清空诊断日志", role: .destructive) {
                    isConfirmingClear = true
                }
                LabeledContent("当前日志占用", value: ByteCountFormatter.string(fromByteCount: model.diagnosticLogBytes, countStyle: .file))
                    .font(.caption)
                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("筛选") {
                Picker("Session", selection: $selectedSessionID) {
                    Text("全部").tag(Optional<UUID>.none)
                    ForEach(sessionIDs, id: \.self) { id in
                        Text(String(id.uuidString.prefix(8))).tag(Optional(id))
                    }
                }
                Picker("Tool Call", selection: $selectedToolCallID) {
                    Text("全部").tag(Optional<UUID>.none)
                    ForEach(toolCallIDs, id: \.self) { id in
                        Text(String(id.uuidString.prefix(8))).tag(Optional(id))
                    }
                }
                Picker("级别", selection: $selectedLevel) {
                    Text("全部").tag(Optional<DiagnosticLogLevel>.none)
                    ForEach(DiagnosticLogLevel.allCases, id: \.self) { level in
                        Text(diagnosticLevelName(level)).tag(Optional(level))
                    }
                }
            }

            Section("日志 · \(visibleLogs.count)") {
                if visibleLogs.isEmpty {
                    Text("没有匹配的日志。")
                        .foregroundStyle(.secondary)
                }
                ForEach(visibleLogs) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(diagnosticLevelName(record.level))
                                .font(.caption.bold())
                            Text(record.subsystem)
                                .font(.caption.monospaced())
                            Spacer()
                            Text(record.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text("\(record.action) · \(record.result)")
                            .font(.subheadline)
                        if let diagnostic = record.diagnostic, !diagnostic.isEmpty {
                            Text(diagnostic)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 8) {
                            if let sessionID = record.sessionID {
                                Text("S \(sessionID.uuidString.prefix(8))")
                            }
                            if let toolCallID = record.toolCallID {
                                Text("T \(toolCallID.uuidString.prefix(8))")
                            }
                            if let domain = record.errorDomain {
                                Text("\(domain) \(record.errorCode.map { String($0) } ?? "")")
                            }
                        }
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("诊断日志")
        .searchable(text: $query, prompt: "搜索动作、结果、错误或 diagnostic")
        .refreshable { await model.refreshDiagnosticLogs() }
        .task {
            model.recordStartupBreadcrumb("diagnostics.appear")
            await model.refreshDiagnosticLogs()
        }
        .onDisappear { model.recordStartupBreadcrumb("diagnostics.disappear") }
        .sheet(item: $shareItem) { item in
            DiagnosticActivityShareSheet(items: [item.url])
        }
        .confirmationDialog(
            "清空诊断日志？",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("清空诊断日志", role: .destructive) {
                Task {
                    if await model.clearDiagnosticLogs() {
                        selectedSessionID = nil
                        selectedToolCallID = nil
                        selectedLevel = nil
                        query = ""
                        statusMessage = "诊断日志已清空；审计记录、事务记录和回收站日志未删除。"
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清空运行时诊断日志，方便重新复现后导出更小的日志；不会删除审计、事务、回收站或会话数据。")
        }
    }
}

private struct DiagnosticShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DiagnosticActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private func diagnosticLevelName(_ level: DiagnosticLogLevel) -> String {
    switch level {
    case .debug: return "调试"
    case .info: return "信息"
    case .warning: return "警告"
    case .error: return "错误"
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
    case "automation.gui.open_app": return "GUI · 打开 App"
    case "automation.gui.tree": return "GUI · UI Tree 观察"
    case "automation.gui.screenshot": return "GUI · 全局截图"
    case "automation.gui.touch": return "GUI · 全局触控"
    case "automation.gui.text_input": return "GUI · 文本输入"
    case "automation.gui.gestures": return "GUI · 滑动/滚动"
    case "automation.gui.verify": return "GUI · 结果验证"
    case "automation.gui": return "GUI 自动化（完整链路）"
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
    case "filesystem.unrestricted": return "保守验证 /var/mobile 范围的实际读写能力；通过也不等于具有 root 身份。"
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
    case "automation.gui.open_app": return "由 bounded helper / LaunchServices 独立验证能否打开其他 App；不依赖完整 GUI backend。"
    case "automation.gui.tree": return "只有隔离 helper 实际从前台 App 返回 bounded AXRuntime tree 后才标记可用。"
    case "automation.gui.screenshot": return "只有隔离 helper 实际捕获并编码全局截图后才标记可用。"
    case "automation.gui.touch": return "只有当前 TrollStore 签名下 IOHID client 与 digitizer runtime 握手成功后才标记可用。"
    case "automation.gui.text_input": return "只有 IOHID Unicode 文本事件 runtime 握手成功后才标记可用；输入正文不会进入诊断/审批日志。"
    case "automation.gui.gestures": return "滑动和滚动依赖同一 bounded IOHID digitizer backend，并限制坐标、时长和 helper 超时。"
    case "automation.gui.verify": return "验证必须基于一次新的 AX tree 观察；如果 tree 不可用则验证能力也不可用。"
    case "automation.gui":
        return "完整 GUI 自动化只有打开 App、观察、截图、触控、输入、手势和验证全部在当前运行时真实可用时才会标记可用。"
    case "ipa.inspect": return "可在本地进程内检查 IPA 的 ZIP、Info.plist、架构和签名元数据。"
    case "ipa.decrypt":
        return detail.contains("No IPA decryption executor") ? "当前版本没有接入 IPA 解密执行器，因此不可用。" : "解密需要兼容的高权限运行环境以及可访问的目标进程。"
    case "ipa.install":
        return detail.contains("No IPA installation executor") ? "当前版本没有接入 IPA 安装执行器，因此不可用。" : "安装 IPA 依赖 TrollStore 或其他已验证的高权限安装能力。"
    default: return detail
    }
}

private func localizedReasoningEffort(_ effort: ModelReasoningEffort) -> String {
    switch effort {
    case .automatic: return "自动（兼容优先）"
    case .low: return "低"
    case .medium: return "中"
    case .high: return "高"
    case .xhigh: return "超高"
    case .max: return "最高"
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
