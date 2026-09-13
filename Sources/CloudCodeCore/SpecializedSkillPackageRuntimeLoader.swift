import Foundation

public enum SpecializedSkillPackageRuntimeLoader {
    private static let maxManifestBytes = 256 * 1024
    private static let maxTextBytes = 1024 * 1024

    public static func loadContext(rootURL: URL, skillID: String) throws -> String? {
        let packageURL = rootURL.appendingPathComponent(directoryName(for: skillID), isDirectory: true)
        let manifestURL = packageURL.appendingPathComponent("skill.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        guard manifestData.count <= maxManifestBytes,
              let manifest = try? JSONDecoder().decode(SpecializedSkillPackageManifest.self, from: manifestData),
              manifest.id == skillID else {
            throw SpecializedSkillPackageError.manifestInvalid
        }

        var parts = [
            "Installed specialist skill package: \(manifest.id)",
            "revision=\(manifest.revision)",
            "displayName=\(manifest.displayName)"
        ]
        let instructions = try readText(manifest.resources.instructions, packageRoot: packageURL)
        parts.append("Selected Codex-style SKILL.md instructions:\n\(instructions)")
        if let workflow = manifest.resources.workflow, !workflow.isEmpty {
            parts.append("Selected specialist workflow reference:\n\(try readText(workflow, packageRoot: packageURL))")
        }
        if let policy = manifest.resources.policy, !policy.isEmpty {
            parts.append("Selected specialist policy reference:\n\(try readText(policy, packageRoot: packageURL))")
        }
        return parts.joined(separator: "\n\n")
    }

    private static func readText(_ relativePath: String, packageRoot: URL) throws -> String {
        guard validRelativePath(relativePath) else { throw SpecializedSkillPackageError.manifestInvalid }
        let root = packageRoot.standardizedFileURL
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: target.path) else {
            throw SpecializedSkillPackageError.resourceMissing(relativePath)
        }
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0,
              size <= maxTextBytes,
              let text = try? String(contentsOf: target, encoding: .utf8),
              !text.isEmpty else {
            throw SpecializedSkillPackageError.resourceMissing(relativePath)
        }
        return text
    }

    private static func validRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 240, !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.contains(":") else { return false }
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        return !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func directoryName(for skillID: String) -> String {
        Data(skillID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
