import Foundation
import CryptoKit

public enum BossRecruitmentSkillPackageError: Error, Equatable, Sendable {
    case resourceMissing(String)
    case unreadableResource(String)
    case policyHashMismatch(expected: String, actual: String)
}

public enum BossRecruitmentSkillPackage {
    public static let skillID = "skill.boss.recruitment.batch"
    public static let bundleID = "com.hpbr.bosszhipin"
    public static let displayName = "BOSS 招聘联系"
    public static let skillResourceRelativePath = "Skills/BOSSRecruitment/SKILL.md"
    public static let policyResourceRelativePath = "Skills/BOSSRecruitment/BOSS_CONTACT_POLICY.md"
    public static let workflowResourceRelativePath = "Skills/BOSSRecruitment/WORKFLOW.md"
    public static let manifestResourceRelativePath = "Skills/BOSSRecruitment/skill.json"
    public static let canonicalPolicySHA256 = "c3db99043a75842974a275688862d84f9b7811a8302099403472e44d3981840b"

    public static func loadSkillInstructions(from bundle: Bundle = .main) throws -> String {
        let url = try resourceURL(baseName: "SKILL", fileExtension: "md", bundle: bundle)
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            throw BossRecruitmentSkillPackageError.unreadableResource(skillResourceRelativePath)
        }
        return text
    }

    public static func loadCanonicalPolicy(from bundle: Bundle = .main) throws -> String {
        let url = try resourceURL(baseName: "BOSS_CONTACT_POLICY", fileExtension: "md", bundle: bundle)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw BossRecruitmentSkillPackageError.unreadableResource(policyResourceRelativePath)
        }
        let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualHash == canonicalPolicySHA256 else {
            throw BossRecruitmentSkillPackageError.policyHashMismatch(
                expected: canonicalPolicySHA256,
                actual: actualHash
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BossRecruitmentSkillPackageError.unreadableResource(policyResourceRelativePath)
        }
        return text
    }

    public static func loadWorkflow(from bundle: Bundle = .main) throws -> String {
        let url = try resourceURL(baseName: "WORKFLOW", fileExtension: "md", bundle: bundle)
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            throw BossRecruitmentSkillPackageError.unreadableResource(workflowResourceRelativePath)
        }
        return text
    }

    public static func loadManifestData(from bundle: Bundle = .main) throws -> Data {
        let url = try resourceURL(baseName: "skill", fileExtension: "json", bundle: bundle)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw BossRecruitmentSkillPackageError.unreadableResource(manifestResourceRelativePath)
        }
        return data
    }

    private static func resourceURL(baseName: String, fileExtension: String, bundle: Bundle) throws -> URL {
        if let nested = bundle.url(
            forResource: baseName,
            withExtension: fileExtension,
            subdirectory: "Skills/BOSSRecruitment"
        ) {
            return nested
        }
        // Xcode may flatten ordinary resource groups into the app bundle depending on project
        // generation. Keep one bounded fallback so the skill remains loadable in either layout.
        if let flattened = bundle.url(forResource: baseName, withExtension: fileExtension) {
            return flattened
        }
        throw BossRecruitmentSkillPackageError.resourceMissing(
            "Skills/BOSSRecruitment/\(baseName).\(fileExtension)"
        )
    }

    /// High-level orchestration knowledge only. It intentionally does not grant execution authority.
    /// ToolRouter, CapabilityProfile, PolicyEngine, confirmations, fresh observations and
    /// postcondition verification remain mandatory at runtime.
    public static let semanticSkill = SemanticSkillDefinition(
        id: skillID,
        semanticGoal: "run_boss_recruitment_batch",
        bundleID: bundleID,
        requiredSemanticSurface: "boss.recruitment",
        requiredCapabilities: [
            GUIAutomationFeature.openApp.capabilityID,
            GUIAutomationFeature.screenshot.capabilityID,
            GUIAutomationFeature.touch.capabilityID,
            GUIAutomationFeature.textInput.capabilityID,
            GUIAutomationFeature.gestures.capabilityID
        ],
        landmarks: [
            "job_search",
            "job_list",
            "job_detail",
            "recruiter_activity",
            "work_location",
            "chat_history",
            "message_composer",
            "send_control",
            "post_send_message"
        ],
        transitions: [
            .init(fromSurface: "boss.recruitment", toSurface: "boss.job.list", semanticAction: "discover_candidates"),
            .init(fromSurface: "boss.job.list", toSurface: "boss.job.detail", semanticAction: "open_candidate_detail"),
            .init(fromSurface: "boss.job.detail", toSurface: "boss.job.detail", semanticAction: "audit_candidate_against_canonical_policy"),
            .init(fromSurface: "boss.job.detail", toSurface: "boss.chat.conversation", semanticAction: "open_visible_communication_flow"),
            .init(fromSurface: "boss.chat.conversation", toSurface: "boss.chat.conversation", semanticAction: "reconcile_existing_contact"),
            .init(fromSurface: "boss.chat.conversation", toSurface: "boss.chat.composer", semanticAction: "prepare_message_once"),
            .init(fromSurface: "boss.chat.composer", toSurface: "boss.chat.conversation", semanticAction: "send_message_once"),
            .init(fromSurface: "boss.chat.conversation", toSurface: "boss.recruitment", semanticAction: "verify_and_commit_progress")
        ],
        verificationObligations: [
            "canonical_policy_loaded",
            "candidate_final_audit_passed",
            "permanent_dedup_checked",
            "chat_history_reconciled",
            "send_postcondition_verified",
            "ledger_commit_verified",
            "batch_progress_verified"
        ],
        allowedLocalRecovery: [
            "fresh_observation",
            "ax_first_then_local_roi_ocr",
            "screenshot_vision_last_resort",
            "reconcile_before_send_retry",
            "fail_closed_on_safety_gate"
        ],
        exactlyOnce: false,
        userSelectable: true
    )
}
