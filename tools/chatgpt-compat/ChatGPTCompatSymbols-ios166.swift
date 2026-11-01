// IPA Total V112 - independent iOS16.6 candidate for subset of Symbols APIs.
// NOT Apple's original Symbols framework. NOT an application.
// Does not independently animate SF Symbols or prove Apple ABI equivalence.
import Foundation

@frozen
public struct SymbolEffectConfiguration: Hashable, Sendable {
    public enum Kind: UInt8, Hashable, Sendable {
        case automatic = 0
        case replace = 1
    }
    public var kind: Kind
    public var scope: UInt8

    public init(kind: Kind, scope: UInt8 = 0) {
        self.kind = kind
        self.scope = scope
    }
}

public protocol SymbolEffect: Hashable, Sendable {
    var configuration: SymbolEffectConfiguration { get }
}
public protocol ContentTransitionSymbolEffect: SymbolEffect {}

@frozen
public struct ReplaceSymbolEffect: SymbolEffect, ContentTransitionSymbolEffect {
    public var configuration: SymbolEffectConfiguration

    public init() {
        self.configuration = SymbolEffectConfiguration(kind: .replace)
    }

    public var byLayer: Self {
        var result = self
        result.configuration.scope = 1
        return result
    }

    public var wholeSymbol: Self {
        var result = self
        result.configuration.scope = 2
        return result
    }
}

@frozen
public struct AutomaticSymbolEffect: SymbolEffect, ContentTransitionSymbolEffect {
    public var configuration: SymbolEffectConfiguration

    public init() {
        self.configuration = SymbolEffectConfiguration(kind: .automatic)
    }
}

@frozen
public struct SymbolEffectOptions: Hashable, Sendable {
    public var speedMultiplier: Double
    public var repeats: Bool

    public init(speedMultiplier: Double = 1.0, repeats: Bool = false) {
        self.speedMultiplier = speedMultiplier.isFinite && speedMultiplier > 0
            ? speedMultiplier : 1.0
        self.repeats = repeats
    }

    public static var `default`: Self { Self() }
    public static func speed(_ value: Double) -> Self {
        Self(speedMultiplier: value)
    }

    public var repeating: Self {
        var result = self
        result.repeats = true
        return result
    }
}

// No fake FinanceKit/MarketplaceKit: no invented authorization or store state.
