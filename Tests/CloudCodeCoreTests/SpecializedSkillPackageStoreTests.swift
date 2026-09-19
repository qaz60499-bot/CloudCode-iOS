import XCTest
@testable import CloudCodeCore

final class SpecializedSkillPackageStoreTests: XCTestCase {
    func testDirectoryPackageInstallsAndFeedsSelectedSkillContext() async throws {
        let support = temporaryDirectory("support-installed")
        let root = support.appendingPathComponent("Skills/Packages", isDirectory: true)
        let source = temporaryDirectory("source")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: source)
        }

        let manifest = makeManifest(id: "skill.demo.operations", revision: "r1")
        try writePackage(manifest: manifest, root: source, instructionMarker: "DEMO_INSTRUCTION_R1")

        let store = SpecializedSkillPackageStore(rootURL: root)
        let installed = try await store.install(from: source)
        XCTAssertEqual(installed.manifest.id, "skill.demo.operations")
        XCTAssertEqual(installed.manifest.displayName, "Demo Operations")

        let definitions = try await store.definitions()
        XCTAssertEqual(definitions.count, 1)
        XCTAssertEqual(definitions[0].origin, .installed)
        XCTAssertEqual(definitions[0].displayName, "Demo Operations")
        XCTAssertEqual(definitions[0].bundleID, "com.example.demo")

        let indexURL = support.appendingPathComponent("Index/semantic-skills.json")
        let registry = SemanticSkillRegistry(fileURL: indexURL)
        try await registry.replaceInstalledSkills(definitions)
        let hint = await registry.selectedSkillHint(skillID: "skill.demo.operations")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("DEMO_INSTRUCTION_R1") == true)
        XCTAssertTrue(hint?.contains("DEMO_WORKFLOW") == true)
        XCTAssertTrue(hint?.contains("DEMO_POLICY") == true)
    }

    func testUpdatingSameSkillIDUsesNewPackageWhileSessionBindingStaysStable() async throws {
        let support = temporaryDirectory("support")
        let packages = support.appendingPathComponent("Skills/Packages", isDirectory: true)
        let sourceOne = temporaryDirectory("source-r1")
        let sourceTwo = temporaryDirectory("source-r2")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: sourceOne)
            try? FileManager.default.removeItem(at: sourceTwo)
        }

        let id = "skill.demo.stable"
        try writePackage(manifest: makeManifest(id: id, revision: "r1"), root: sourceOne, instructionMarker: "RULE_R1")
        try writePackage(manifest: makeManifest(id: id, revision: "r2"), root: sourceTwo, instructionMarker: "RULE_R2")

        let store = SpecializedSkillPackageStore(rootURL: packages)
        _ = try await store.install(from: sourceOne)
        let session = AgentSession(title: "Demo", specializedSkillID: id)
        _ = try await store.install(from: sourceTwo)
        XCTAssertEqual(session.specializedSkillID, id)

        let definitions = try await store.definitions()
        let registry = SemanticSkillRegistry(fileURL: support.appendingPathComponent("Index/semantic-skills.json"))
        try await registry.replaceInstalledSkills(definitions)
        let hint = await registry.selectedSkillHint(skillID: id)
        XCTAssertTrue(hint?.contains("RULE_R2") == true)
        XCTAssertFalse(hint?.contains("RULE_R1") == true)
    }

    func testExportedSkillZipIsDetectedAndCanBeReimported() async throws {
        let source = temporaryDirectory("zip-source")
        let installedRoot = temporaryDirectory("zip-installed")
        let secondRoot = temporaryDirectory("zip-second")
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCodeSkillExport-\(UUID().uuidString).skill.zip")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: installedRoot)
            try? FileManager.default.removeItem(at: secondRoot)
            try? FileManager.default.removeItem(at: exportURL)
        }

        let manifest = makeManifest(id: "skill.demo.export", revision: "r9")
        try writePackage(manifest: manifest, root: source, instructionMarker: "EXPORT_RULE")
        let store = SpecializedSkillPackageStore(rootURL: installedRoot)
        _ = try await store.install(from: source)
        _ = try await store.export(skillID: manifest.id, to: exportURL)

        XCTAssertTrue(try SpecializedSkillPackageStore.archiveContainsSkillManifest(exportURL))
        let secondStore = SpecializedSkillPackageStore(rootURL: secondRoot)
        let imported = try await secondStore.install(from: exportURL)
        XCTAssertEqual(imported.manifest.id, manifest.id)
        XCTAssertEqual(imported.manifest.revision, "r9")
    }

    func testUniqueHighConfidenceRouterLoadsExactlyOneInstalledUserSkill() async throws {
        let support = temporaryDirectory("router-support")
        let source = temporaryDirectory("router-source")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: source)
        }
        let manifest = makeManifest(id: "skill.demo.router", revision: "r1")
        try writePackage(manifest: manifest, root: source, instructionMarker: "ROUTER_RULE")
        let store = SpecializedSkillPackageStore(rootURL: support.appendingPathComponent("Skills/Packages"))
        _ = try await store.install(from: source)
        let registry = SemanticSkillRegistry(fileURL: support.appendingPathComponent("Index/semantic-skills.json"))
        try await registry.replaceInstalledSkills(try await store.definitions())

        let matched = await registry.uniqueHighConfidenceUserSkill(for: "请使用 Demo Operations 完成这个任务")
        let unmatched = await registry.uniqueHighConfidenceUserSkill(for: "帮我随便看看这个页面")
        XCTAssertEqual(matched?.id, manifest.id)
        XCTAssertNil(unmatched)
    }

    func testInstalledPackageCannotOverrideBuiltInSkillID() async throws {
        let root = temporaryDirectory("installed-reserved")
        let source = temporaryDirectory("source-reserved")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }

        let manifest = makeManifest(id: BossRecruitmentSkillPackage.skillID, revision: "override")
        try writePackage(manifest: manifest, root: source, instructionMarker: "SHOULD_NOT_INSTALL")
        let store = SpecializedSkillPackageStore(rootURL: root)
        do {
            _ = try await store.install(from: source)
            XCTFail("reserved built-in skill ID must be rejected")
        } catch let error as SpecializedSkillPackageError {
            XCTAssertEqual(error, .reservedSkillID(BossRecruitmentSkillPackage.skillID))
        }
    }

    func testRemovingInstalledPackagePrunesValidatedOverlay() async throws {
        let support = temporaryDirectory("support-prune")
        let packages = support.appendingPathComponent("Skills/Packages", isDirectory: true)
        let source = temporaryDirectory("source-prune")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: source)
        }

        let id = "skill.demo.prune"
        try writePackage(manifest: makeManifest(id: id, revision: "r1"), root: source, instructionMarker: "PRUNE_ME")
        let store = SpecializedSkillPackageStore(rootURL: packages)
        _ = try await store.install(from: source)

        let registry = SemanticSkillRegistry(fileURL: support.appendingPathComponent("Index/semantic-skills.json"))
        try await registry.replaceInstalledSkills(try await store.definitions())
        try await registry.recordExplicitValidation(
            skillID: id,
            bundleID: "com.example.demo",
            environment: AppActionEnvironment(),
            success: true
        )
        let installedSkill = await registry.skill(id: id)
        XCTAssertNotNil(installedSkill)

        try await store.remove(skillID: id)
        try await registry.replaceInstalledSkills(try await store.definitions())
        let removedSkill = await registry.skill(id: id)
        XCTAssertNil(removedSkill)
    }

    private func makeManifest(id: String, revision: String) -> SpecializedSkillPackageManifest {
        SpecializedSkillPackageManifest(
            revision: revision,
            id: id,
            displayName: "Demo Operations",
            targetApp: .init(name: "Demo", bundleID: "com.example.demo"),
            semantic: .init(
                goal: "operate_demo",
                requiredSurface: "demo.home",
                requiredCapabilities: ["gui.screenshot", "gui.touch"],
                landmarks: ["home", "result"],
                transitions: [
                    .init(fromSurface: "demo.home", toSurface: "demo.result", semanticAction: "perform_demo")
                ],
                verificationObligations: ["result_verified"],
                allowedLocalRecovery: ["fresh_observation"]
            ),
            resources: .init(
                instructions: "SKILL.md",
                workflow: "WORKFLOW.md",
                policy: "POLICY.md"
            )
        )
    }

    private func writePackage(
        manifest: SpecializedSkillPackageManifest,
        root: URL,
        instructionMarker: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: root.appendingPathComponent("skill.json"), options: .atomic)
        try "# Skill\n\n\(instructionMarker)".write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# Workflow\n\nDEMO_WORKFLOW".write(to: root.appendingPathComponent("WORKFLOW.md"), atomically: true, encoding: .utf8)
        try "# Policy\n\nDEMO_POLICY".write(to: root.appendingPathComponent("POLICY.md"), atomically: true, encoding: .utf8)
    }

    private func temporaryDirectory(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCodeSkillTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
