import Foundation
import CloudCodeCore

enum ProviderSanitizer {
    private static let trigger = "--provider-sanitize-once"
    private static let retainedBuiltInProviderIDs: Set<String> = [
        "https-agentrouter-org",
        "https-api-justwoker-icu",
    ]
    private static let obsoleteBuiltInKeyReferences: [String] = {
        var refs: [String] = []
        func append(_ providerID: String, _ count: Int) {
            for index in 1...count {
                refs.append(ProviderCatalog.keyReference(providerID: providerID, keySlotID: "slot-\(index)"))
            }
        }
        append("tabitoken", 5)
        append("https-ai-fsykk-cn", 1)
        append("ccs-7bdd07431575", 5)
        append("https-api-denxio-top", 1)
        append("https-sharellm-cn", 2)
        append("https-sirthisway-icu", 5)
        append("https-vyceai-com", 1)
        append("https-free-supxh-xin", 1)
        return refs
    }()
    private static let migrationPath = "/var/mobile/Media/Downloads/CloudCode-Cline-Migration.json"
    private static let statusPath = "/var/mobile/Media/Downloads/CloudCode-Provider-Sanitize-Status.json"

    private struct MigrationPayload: Codable {
        let schemaVersion: Int
        let providers: [MigrationProvider]
    }

    private struct MigrationProvider: Codable {
        let profile: ProviderProfile
        let keysBySlotID: [String: String]
    }

    private struct SanitizeStatus: Codable {
        let ok: Bool
        let clineProviders: Int
        let exportedKeys: Int
        let removedKeyReferences: Int
        let removedCustomProviders: Int
        let retainedProviderIDs: [String]
        let error: String?
    }

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(trigger) else { return }

        do {
            try await run()
        } catch {
            writeStatus(
                SanitizeStatus(
                    ok: false,
                    clineProviders: 0,
                    exportedKeys: 0,
                    removedKeyReferences: 0,
                    removedCustomProviders: 0,
                    retainedProviderIDs: retainedBuiltInProviderIDs.sorted(),
                    error: error.localizedDescription
                )
            )
        }
    }

    private static func run() async throws {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "ProviderSanitizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application Support unavailable"])
        }

        let customURL = support.appendingPathComponent("Provider/custom-providers.json")
        let liveCatalogURL = support.appendingPathComponent("Provider/live-model-catalogs.json")
        let customProviders = loadCustomProviders(from: customURL)
        let clineProviders = customProviders.filter(isClineProvider)
        guard !clineProviders.isEmpty else {
            throw NSError(domain: "ProviderSanitizer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cline provider not found; cleanup aborted"])
        }

        let vault = KeychainAPIKeyVault()
        var migrationProviders: [MigrationProvider] = []
        var exportedKeyCount = 0
        for provider in clineProviders {
            var keys: [String: String] = [:]
            for slot in provider.keySlots {
                let reference = ProviderCatalog.keyReference(providerID: provider.id, keySlotID: slot.id)
                let key = try await vault.key(for: reference)
                guard !key.isEmpty else {
                    throw NSError(domain: "ProviderSanitizer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cline Key is empty; cleanup aborted"])
                }
                keys[slot.id] = key
                exportedKeyCount += 1
            }
            guard !keys.isEmpty else {
                throw NSError(domain: "ProviderSanitizer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cline provider has no readable Key; cleanup aborted"])
            }
            migrationProviders.append(MigrationProvider(profile: provider, keysBySlotID: keys))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let migrationData = try encoder.encode(MigrationPayload(schemaVersion: 1, providers: migrationProviders))
        let migrationURL = URL(fileURLWithPath: migrationPath)
        try migrationData.write(to: migrationURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: migrationURL.path)

        var removedReferences = 0
        for reference in obsoleteBuiltInKeyReferences {
            try vault.remove(reference)
            removedReferences += 1
        }

        let retainedCustomIDs = Set(clineProviders.map(\.id))
        for provider in customProviders where !retainedCustomIDs.contains(provider.id) {
            for slot in provider.keySlots {
                let reference = ProviderCatalog.keyReference(providerID: provider.id, keySlotID: slot.id)
                try vault.remove(reference)
                removedReferences += 1
            }
        }

        try fileManager.createDirectory(
            at: customURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(clineProviders).write(to: customURL, options: .atomic)

        for providerID in [
            "tabitoken", "https-ai-fsykk-cn", "ccs-7bdd07431575", "https-api-denxio-top",
            "https-sharellm-cn", "https-sirthisway-icu", "https-vyceai-com", "https-free-supxh-xin",
        ] {
            try? ProviderLiveModelCatalogCache.remove(providerID: providerID, from: liveCatalogURL)
        }

        let defaults = UserDefaults.standard
        let hiddenIDs = ProviderCatalog.desktopSnapshot
            .map(\.id)
            .filter { !retainedBuiltInProviderIDs.contains($0) }
            .sorted()
        defaults.set(hiddenIDs, forKey: "provider.hidden.ids")

        let retainedIDs = retainedBuiltInProviderIDs.union(retainedCustomIDs)
        let manualOverrides = defaults.stringArray(forKey: "provider.key.manualOverrides") ?? []
        defaults.set(
            manualOverrides.filter { reference in
                retainedIDs.contains { reference.hasPrefix("provider.\($0).key.") }
            },
            forKey: "provider.key.manualOverrides"
        )

        let customModelOverrides = defaults.stringArray(forKey: "provider.model.explicitCustomOverrides") ?? []
        defaults.set(
            customModelOverrides.filter { identity in
                retainedIDs.contains { identity.hasPrefix($0 + "\u{001F}") }
            },
            forKey: "provider.model.explicitCustomOverrides"
        )

        let selectedID = defaults.string(forKey: "provider.selected.id") ?? ""
        if !retainedIDs.contains(selectedID),
           let agentRouter = ProviderCatalog.desktopSnapshot.first(where: { $0.id == ProviderCatalog.agentRouterID }),
           let slot = agentRouter.keySlots.first {
            defaults.set(agentRouter.id, forKey: "provider.selected.id")
            defaults.set(slot.id, forKey: "provider.selected.keySlot")
            defaults.set(slot.models.first ?? agentRouter.models.first ?? "", forKey: "provider.selected.model")
        }

        writeStatus(
            SanitizeStatus(
                ok: true,
                clineProviders: clineProviders.count,
                exportedKeys: exportedKeyCount,
                removedKeyReferences: removedReferences,
                removedCustomProviders: max(0, customProviders.count - clineProviders.count),
                retainedProviderIDs: retainedIDs.sorted(),
                error: nil
            )
        )
    }

    private static func loadCustomProviders(from url: URL) -> [ProviderProfile] {
        guard let data = try? Data(contentsOf: url),
              let providers = try? JSONDecoder().decode([ProviderProfile].self, from: data) else {
            return []
        }
        return providers.filter { $0.source == .custom }
    }

    private static func isClineProvider(_ provider: ProviderProfile) -> Bool {
        let label = provider.displayName.lowercased()
        let host = (provider.baseURL.host ?? "").lowercased()
        return label == "cline" || label.contains("cline") || host.contains("cline")
    }

    private static func writeStatus(_ status: SanitizeStatus) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(status)
            let url = URL(fileURLWithPath: statusPath)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best effort only. The migration payload is the fail-closed gate.
        }
    }
}
