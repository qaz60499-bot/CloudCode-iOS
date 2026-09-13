import SwiftUI
import UniformTypeIdentifiers
import CloudCodeCore
import UIKit

struct SpecializedSkillManagerView: View {
    @ObservedObject var model: CloudCodeViewModel
    var onOpenChat: (() -> Void)? = nil

    @State private var showImporter = false
    @State private var showCreator = false
    @State private var message: String?
    @State private var packages: [SpecializedSkillPackageSummary] = []
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var selectedPackage: SpecializedSkillPackageSummary?

    var body: some View {
        List {
            Section("添加") {
                Button("新建专项技能") { showCreator = true }
                Button("导入 / 更新技能包") { showImporter = true }
                Text("支持 xxx.skill.zip 或文件夹；必须包含 skill.json 和 SKILL.md。导入前会检查路径穿越、symlink、大小和 manifest。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Section("状态") { Text(message).font(.caption) }
            }

            Section("已安装") {
                if packages.isEmpty {
                    Text("暂无外部技能包")
                        .foregroundStyle(.secondary)
                }
                ForEach(packages) { package in
                    packageRow(package)
                }
            }

            Section("规则") {
                Text("技能包存放在 Application Support/CloudCode/Skills/Packages，属于 Data Container。覆盖安装 IPA 不会删除技能、启用状态或专项对话历史。同一个 Skill ID 更新时会原子替换包内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("专项技能管理")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip, .folder]) { result in
            importPackage(result)
        }
        .sheet(isPresented: $showCreator, onDismiss: { Task { await reloadPackages() } }) {
            NewSpecializedSkillView(model: model, isPresented: $showCreator, message: $message)
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportURL {
                SpecializedSkillShareSheet(items: [exportURL])
            }
        }
        .sheet(item: $selectedPackage) { package in
            NavigationStack {
                SpecializedSkillPackageDetailView(model: model, package: package, onOpenChat: onOpenChat)
            }
        }
        .task { await reloadPackages() }
    }

    @ViewBuilder
    private func packageRow(_ package: SpecializedSkillPackageSummary) -> some View {
        let enabled = model.isSpecializedSkillPackageEnabled(package.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(package.manifest.displayName).font(.headline)
                    Text("\(package.manifest.id) · \(package.manifest.revision)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.isSpecializedSkillPackageEnabled(package.id) },
                    set: { value in Task { await setEnabled(value, package: package) } }
                ))
                .labelsHidden()
            }

            if !package.manifest.semantic.requiredCapabilities.isEmpty {
                Text("能力：\(package.manifest.semantic.requiredCapabilities.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("来源：本地安装 · 存储：Data Container")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("打开 / 设置") { selectedPackage = package }
                Button("开始专项对话") {
                    if model.openSpecializedConversation(skillID: package.id) {
                        onOpenChat?()
                    }
                }
                .disabled(!enabled)

                Button("更新") { showImporter = true }
                Button("导出") { Task { await export(package) } }
                Button("卸载", role: .destructive) { Task { await remove(package) } }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func reloadPackages() async {
        packages = await model.specializedSkillPackages()
    }

    private func setEnabled(_ enabled: Bool, package: SpecializedSkillPackageSummary) async {
        await model.setSpecializedSkillPackageEnabled(enabled, skillID: package.id)
        await reloadPackages()
        message = enabled ? "已启用：\(package.manifest.displayName)" : "已停用：\(package.manifest.displayName)"
    }

    private func importPackage(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result { message = "选择失败：\(error.localizedDescription)" }
            return
        }
        Task {
            do {
                let package = try await model.importSpecializedSkillPackage(from: url)
                await reloadPackages()
                message = "已安装 / 更新：\(package.manifest.displayName)"
            } catch {
                message = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func export(_ package: SpecializedSkillPackageSummary) async {
        do {
            exportURL = try await model.exportSpecializedSkillPackage(skillID: package.id)
            showShareSheet = exportURL != nil
            message = "已生成技能包：\(package.id).skill.zip"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    private func remove(_ package: SpecializedSkillPackageSummary) async {
        do {
            try await model.removeSpecializedSkillPackage(skillID: package.id)
            await reloadPackages()
            message = "已卸载：\(package.manifest.displayName)"
        } catch {
            message = "卸载失败：\(error.localizedDescription)"
        }
    }
}

private struct SpecializedSkillPackageDetailView: View {
    @ObservedObject var model: CloudCodeViewModel
    let package: SpecializedSkillPackageSummary
    let onOpenChat: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("技能") {
                LabeledContent("名称", value: package.manifest.displayName)
                LabeledContent("Skill ID", value: package.manifest.id)
                LabeledContent("版本", value: package.manifest.revision)
                LabeledContent("来源", value: "本地技能包")
                Toggle("启用", isOn: Binding(
                    get: { model.isSpecializedSkillPackageEnabled(package.id) },
                    set: { value in Task { await model.setSpecializedSkillPackageEnabled(value, skillID: package.id) } }
                ))
            }
            Section("Runtime") {
                LabeledContent("目标", value: package.manifest.semantic.goal)
                LabeledContent("界面", value: package.manifest.semantic.requiredSurface)
                if let bundleID = package.manifest.targetApp?.bundleID, !bundleID.isEmpty {
                    LabeledContent("App", value: bundleID)
                }
                if package.manifest.semantic.requiredCapabilities.isEmpty {
                    Text("无额外声明能力")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(package.manifest.semantic.requiredCapabilities, id: \.self) { capability in
                        Text(capability).font(.caption.monospaced())
                    }
                }
            }
            Section("资源") {
                LabeledContent("规则", value: package.manifest.resources.instructions)
                if let workflow = package.manifest.resources.workflow { LabeledContent("工作流", value: workflow) }
                if let policy = package.manifest.resources.policy { LabeledContent("Policy", value: policy) }
                Text("脚本、selectors、assets 等资源只作为技能包数据存在；只有 manifest 声明且通过 Cloud Code Runtime/ToolRouter/PolicyEngine 的能力才可执行。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("开始专项对话") {
                    if model.openSpecializedConversation(skillID: package.id) {
                        dismiss()
                        onOpenChat?()
                    }
                }
                .disabled(!model.isSpecializedSkillPackageEnabled(package.id))
            }
        }
        .navigationTitle(package.manifest.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SpecializedSkillShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct NewSpecializedSkillView: View {
    @ObservedObject var model: CloudCodeViewModel
    @Binding var isPresented: Bool
    @Binding var message: String?
    @State private var name = ""
    @State private var skillID = "skill.custom."
    @State private var bundleID = ""
    @State private var goal = ""
    @State private var instructions = "# 专项技能\n\n填写业务规则、边界和执行要求。"
    @State private var workflow = "# 工作流\n\n填写观察、判断、执行和验证流程。"

    var body: some View {
        NavigationStack {
            Form {
                TextField("显示名称", text: $name)
                TextField("Skill ID", text: $skillID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("目标 Bundle ID（可选）", text: $bundleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("语义目标", text: $goal)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Section("SKILL.md") { TextEditor(text: $instructions).frame(minHeight: 140) }
                Section("WORKFLOW.md") { TextEditor(text: $workflow).frame(minHeight: 140) }
            }
            .navigationTitle("新建专项技能")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { create() }.disabled(!canCreate)
                }
            }
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && skillID.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("skill.")
            && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        Task {
            do {
                let package = try await model.createSpecializedSkillTemplate(
                    id: skillID,
                    displayName: name,
                    targetBundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bundleID,
                    semanticGoal: goal,
                    instructions: instructions,
                    workflow: workflow
                )
                message = "已创建：\(package.manifest.displayName)"
                isPresented = false
            } catch {
                message = "创建失败：\(error.localizedDescription)"
            }
        }
    }
}
