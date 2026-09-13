import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CloudCodeCore

struct AppProviderManagementView: View {
    @ObservedObject var model: CloudCodeViewModel
    @State private var showBuilder = false
    @State private var showImporter = false
    @State private var shareItem: AppProviderShareItem?

    var body: some View {
        List {
            Section("Provider Packages") {
                if model.appProviderPackages.isEmpty {
                    Text("暂无 App Provider Package")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.appProviderPackages) { package in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(package.manifest.displayName)
                                    .font(.headline)
                                Text(package.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("\(package.manifest.bundleID) · rev \(package.manifest.compatibility.selectorRevision)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { package.enabled },
                                set: { enabled in
                                    Task { await model.setAppProviderEnabled(packageID: package.id, enabled: enabled) }
                                }
                            ))
                            .labelsHidden()
                        }

                        if let status = model.appProviderStatusMessages[package.id], !status.isEmpty {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button("使用") { model.selectAppProviderPackage(package.id) }
                                .disabled(!package.enabled)
                            Button("授权") {
                                Task { await model.setAppProviderUseConsent(packageID: package.id, enabled: true) }
                            }
                                .disabled(!package.enabled)
                            Button("撤销") {
                                Task { await model.setAppProviderUseConsent(packageID: package.id, enabled: false) }
                            }
                            Button("探测") {
                                Task { _ = await model.probeAppProviderSetup(packageID: package.id) }
                            }
                                .disabled(!package.enabled)
                            Button("测试") {
                                Task { _ = await model.testAppProvider(packageID: package.id) }
                            }
                                .disabled(!package.enabled)
                            Button("导出") {
                                Task {
                                    do {
                                        shareItem = AppProviderShareItem(url: try await model.exportAppProvider(packageID: package.id))
                                    } catch {
                                        model.lastError = "导出 App Provider Package 失败：\(error)"
                                    }
                                }
                            }
                        }
                        .buttonStyle(.bordered)

                        if !Self.isFirstParty(package.id) {
                            Button("删除 Custom Provider", role: .destructive) {
                                Task { await model.deleteAppProvider(packageID: package.id) }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("操作") {
                Button("制作 Custom App Provider") { showBuilder = true }
                Button("导入 Provider Package") { showImporter = true }
                Text("导入包只允许 provider.json、selectors.json、workflow.json、recovery.json 与 prompts.md 一类 declarative 资源；未知 capability、路径穿越、symlink、超限 ZIP 会 fail closed。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("App Provider")
        .refreshable { await model.reloadAppProviderPackages() }
        .task { await model.reloadAppProviderPackages() }
        .sheet(isPresented: $showBuilder) {
            CustomAppProviderSheet(model: model, isPresented: $showBuilder)
        }
        .sheet(item: $shareItem) { item in
            AppProviderActivityShareSheet(items: [item.url])
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url):
                Task { await model.importAppProvider(from: url) }
            case .failure(let error):
                model.lastError = String(describing: error)
            }
        }
    }

    private static func isFirstParty(_ id: String) -> Bool {
        id == "ai.gemini.app" || id == "ai.deepseek.app" || id == "ai.chatgpt.app"
    }
}

struct CustomAppProviderSheet: View {
    @ObservedObject var model: CloudCodeViewModel
    @Binding var isPresented: Bool

    @State private var displayName = ""
    @State private var bundleID = ""
    @State private var launchScheme = ""
    @State private var composerText = ""
    @State private var sendText = ""
    @State private var readyText = ""
    @State private var loginText = ""
    @State private var generationStartText = ""
    @State private var generationCompleteText = ""
    @State private var copyText = ""
    @State private var errorText = ""
    @State private var requiresLogin = false
    @State private var generationTimeoutSeconds = 180.0
    @State private var retryBudget = 1
    @State private var createdPackageID = ""
    @State private var probeCandidates: [String] = []
    @State private var statusMessage: String?

    private var installedApps: [ResourceNode] {
        model.apps
            .filter { $0.ownerBundleID?.isEmpty == false }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("1. 选择 App") {
                    if !installedApps.isEmpty {
                        Picker("已安装 App", selection: $bundleID) {
                            Text("手动输入").tag("")
                            ForEach(installedApps) { app in
                                if let candidateBundleID = app.ownerBundleID {
                                    Text(app.displayName).tag(candidateBundleID)
                                }
                            }
                        }
                        .onChange(of: bundleID) { newValue in
                            guard !newValue.isEmpty else { return }
                            Task { await loadMetadata(bundleID: newValue) }
                        }
                    }
                    TextField("Bundle ID", text: $bundleID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("显示名称", text: $displayName)
                    TextField("Launch Scheme（可留空自动读取）", text: $launchScheme)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("读取 App 元数据") {
                        Task { await loadMetadata(bundleID: bundleID) }
                    }
                    .disabled(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("2. 创建 declarative Template") {
                    Button("创建 Template") {
                        Task {
                            let ok = await model.createCustomAppProviderTemplate(
                                displayName: displayName,
                                bundleID: bundleID,
                                launchScheme: launchScheme
                            )
                            guard ok else { return }
                            createdPackageID = model.selectedAppProviderPackageID
                            statusMessage = "Template 已创建。下一步只做观察探测，不会发送消息或点击外部动作。"
                        }
                    }
                    .disabled(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !createdPackageID.isEmpty {
                        Text(createdPackageID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("3. 无点击界面探测") {
                    Button("启动 App 并读取当前可见候选") {
                        Task {
                            guard !createdPackageID.isEmpty,
                                  let result = await model.probeAppProviderSetup(packageID: createdPackageID) else { return }
                            displayName = result.displayName
                            bundleID = result.bundleID
                            if launchScheme.isEmpty { launchScheme = result.launchSchemes.first ?? "" }
                            composerText = result.proposedComposer ?? composerText
                            sendText = result.proposedSend ?? sendText
                            readyText = result.proposedReadyIndicator ?? readyText
                            probeCandidates = result.visibleCandidates
                            statusMessage = "已读取 fresh observation。请人工确认 selector；不会把学习数据当作跳过 fresh observation 的依据。"
                        }
                    }
                    .disabled(createdPackageID.isEmpty)

                    if !probeCandidates.isEmpty {
                        ForEach(Array(probeCandidates.prefix(12).enumerated()), id: \.offset) { _, value in
                            Text(value)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("4. 确认 Selector / 状态信号") {
                    TextField("Composer 可见文本", text: $composerText)
                    TextField("Send 可见文本", text: $sendText)
                    TextField("Ready Indicator", text: $readyText)
                    Toggle("需要官方 App 登录", isOn: $requiresLogin)
                    if requiresLogin {
                        TextField("Needs Login Indicator", text: $loginText)
                    }
                    TextField("Generation Start（可选）", text: $generationStartText)
                    TextField("Generation Complete（可选）", text: $generationCompleteText)
                    TextField("Copy Button（可选）", text: $copyText)
                    TextField("Error Indicator（可选）", text: $errorText)
                    Stepper("Generation timeout：\(Int(generationTimeoutSeconds)) 秒", value: $generationTimeoutSeconds, in: 10...900, step: 10)
                    Stepper("提交前 recovery budget：\(retryBudget)", value: $retryBudget, in: 0...3)
                    Text("坐标不会由学习过程自动固化。若 Package 明确声明 coordinate fallback，Runtime 还会逐项核对设备类型、方向、App 版本和屏幕几何；任一不匹配就拒绝点击。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("保存 Selector / Timeout / Recovery") {
                        Task {
                            let ok = await model.saveAppProviderSelectors(
                                packageID: createdPackageID,
                                composerText: composerText,
                                submitText: sendText,
                                readyText: readyText,
                                loginText: loginText,
                                generationStartText: generationStartText,
                                generationCompleteText: generationCompleteText,
                                copyText: copyText,
                                errorText: errorText,
                                requiresLogin: requiresLogin,
                                generationTimeoutSeconds: generationTimeoutSeconds,
                                retryBudget: retryBudget
                            )
                            if ok { statusMessage = "Selector / timeout / recovery 已原子保存；Package 内容变化后必须重新授权。" }
                        }
                    }
                    .disabled(
                        createdPackageID.isEmpty || composerText.isEmpty || sendText.isEmpty ||
                        (requiresLogin && readyText.isEmpty && loginText.isEmpty)
                    )
                }

                Section("5. 无副作用 Roundtrip") {
                    Button("授权并执行 harmless marker 测试") {
                        Task {
                            guard !createdPackageID.isEmpty else { return }
                            await model.setAppProviderUseConsent(packageID: createdPackageID, enabled: true)
                            let ok = await model.testAppProvider(packageID: createdPackageID)
                            statusMessage = ok ? "harmless marker roundtrip 已通过。" : "测试未通过；请查看上方错误与 App Provider 日志。"
                        }
                    }
                    .disabled(createdPackageID.isEmpty)
                    Text("测试只向所选 AI App 提交随机 marker 并验证本轮响应绑定；不会发微信/BOSS 消息、点赞、删除、安装、退出账号或修改目标 App 数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let statusMessage {
                    Section("状态") {
                        Text(statusMessage)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("制作 App Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
            }
        }
    }

    private func loadMetadata(bundleID: String) async {
        guard let metadata = await model.inspectAppProviderBuilderMetadata(bundleID: bundleID) else {
            statusMessage = "未发现已安装 App 或无法读取静态元数据。"
            return
        }
        displayName = metadata.displayName
        self.bundleID = metadata.bundleID
        launchScheme = metadata.launchSchemes.first ?? launchScheme
        statusMessage = "已读取 \(metadata.displayName) · \(metadata.appVersion) · \(metadata.bundleID)。"
    }
}

private struct AppProviderShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AppProviderActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
