import Foundation

public protocol MutableAPIKeyVault: APIKeyVault {
    func set(_ value: String, for reference: String) throws
    func remove(_ reference: String) throws
}

public extension MutableAPIKeyVault {
    func optionalKey(for reference: String) async throws -> String? {
        do {
            return try await key(for: reference)
        } catch let error as ProviderError where error == .missingAPIKey {
            return nil
        }
    }
}

public struct ProviderKeyMutation: Sendable, Equatable {
    public var reference: String
    public var secret: String

    public init(reference: String, secret: String) {
        self.reference = reference
        self.secret = secret
    }
}

public enum ProviderKeyProvisioningError: Error, Equatable, CustomStringConvertible {
    case emptyMutation
    case duplicateReference(String)
    case verificationFailed(String)
    case rollbackFailed(String)

    public var description: String {
        switch self {
        case .emptyMutation:
            return "Provider Key provisioning has no mutations"
        case .duplicateReference(let reference):
            return "Provider Key provisioning contains duplicate reference: \(reference)"
        case .verificationFailed(let reference):
            return "Provider Key verification failed for reference: \(reference)"
        case .rollbackFailed(let reference):
            return "Provider Key rollback failed for reference: \(reference)"
        }
    }
}

public enum ProviderKeyProvisioner {
    public static func apply(
        _ mutations: [ProviderKeyMutation],
        vault: MutableAPIKeyVault,
        finalizer: @Sendable () async throws -> Void = {}
    ) async throws -> Int {
        guard !mutations.isEmpty else { throw ProviderKeyProvisioningError.emptyMutation }

        var seen = Set<String>()
        for mutation in mutations {
            guard !mutation.reference.isEmpty, !mutation.secret.isEmpty else { throw ProviderError.missingAPIKey }
            guard seen.insert(mutation.reference).inserted else {
                throw ProviderKeyProvisioningError.duplicateReference(mutation.reference)
            }
        }

        var snapshots: [(reference: String, previous: String?)] = []
        snapshots.reserveCapacity(mutations.count)
        for mutation in mutations {
            snapshots.append((mutation.reference, try await vault.optionalKey(for: mutation.reference)))
        }

        do {
            for mutation in mutations {
                try vault.set(mutation.secret, for: mutation.reference)
            }
            for mutation in mutations {
                let stored = try await vault.key(for: mutation.reference)
                guard stored == mutation.secret else {
                    throw ProviderKeyProvisioningError.verificationFailed(mutation.reference)
                }
            }
            try await finalizer()
            return mutations.count
        } catch {
            var rollbackFailure: String?
            for snapshot in snapshots.reversed() {
                do {
                    if let previous = snapshot.previous {
                        try vault.set(previous, for: snapshot.reference)
                    } else {
                        try vault.remove(snapshot.reference)
                    }
                } catch {
                    rollbackFailure = rollbackFailure ?? snapshot.reference
                }
            }
            if let rollbackFailure {
                throw ProviderKeyProvisioningError.rollbackFailed(rollbackFailure)
            }
            throw error
        }
    }
}
