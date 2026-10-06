import Foundation
import CloudCodeCore

extension CloudCodeViewModel {
    static let disabledSpecializedSkillIDsDefaultsKey = "skills.specialized.disabledIDs"

    private var specializedSkillPackagesRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("CloudCode", isDirectory: true)
            .appendingPathComponent("Skills/Packages", isDirectory: true)
    }

    public func specializedSkillPackages() async -> [SpecializedSkillPackageSummary] {
        let store = SpecializedSkillPackageStore(rootURL: specializedSkillPackagesRoot)
        return (try? await store.all()) ?? []
    }

    public func isSpecializedSkillPackageEnabled(_ skillID: String) -> Bool {
        let disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledSpecializedSkillIDsDefaultsKey) ?? [])
        return !disabled.contains(skillID)
    }

    public func setSpecializedSkillPackageEnabled(_ enabled: Bool, skillID: String) async {
        var disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledSpecializedSkillIDsDefaultsKey) ?? [])
        if enabled { disabled.remove(skillID) } else { disabled.insert(skillID) }
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.disabledSpecializedSkillIDsDefaultsKey)
        await reloadSemanticSkills()
    }

    public func isSkillPackageArchive(_ sourceURL: URL) -> Bool {
        (try? SpecializedSkillPackageStore.archiveContainsSkillManifest(sourceURL)) == true
    }

    @discardableResult
    public func importSpecializedSkillPackage(from sourceURL: URL) async throws -> SpecializedSkillPackageSummary {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        let store = SpecializedSkillPackageStore(rootURL: specializedSkillPackagesRoot)
        let package = try await store.install(from: sourceURL)
        await reloadSemanticSkills()
        return package
    }

    @discardableResult
    public func createSpecializedSkillTemplate(
        id: String,
        displayName: String,
        targetBundleID: String?,
        semanticGoal: String,
        instructions: String,
        workflow: String
    ) async throws -> SpecializedSkillPackageSummary {
        let store = SpecializedSkillPackageStore(rootURL: specializedSkillPackagesRoot)
        let package = try await store.createTemplate(
            id: id,
            displayName: displayName,
            targetBundleID: targetBundleID,
            semanticGoal: semanticGoal,
            instructions: instructions,
            workflow: workflow
        )
        await reloadSemanticSkills()
        return package
    }

    public func exportSpecializedSkillPackage(skillID: String) async throws -> URL {
        let store = SpecializedSkillPackageStore(rootURL: specializedSkillPackagesRoot)
        let safeName = skillID.replacingOccurrences(of: "/", with: "-")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).skill.zip", isDirectory: false)
        return try await store.export(skillID: skillID, to: destination)
    }

    public func removeSpecializedSkillPackage(skillID: String) async throws {
        let store = SpecializedSkillPackageStore(rootURL: specializedSkillPackagesRoot)
        try await store.remove(skillID: skillID)
        var disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledSpecializedSkillIDsDefaultsKey) ?? [])
        disabled.remove(skillID)
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.disabledSpecializedSkillIDsDefaultsKey)
        await reloadSemanticSkills()
    }
}
