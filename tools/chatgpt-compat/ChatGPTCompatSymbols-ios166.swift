// IPA Total V115 - iOS16.6 Symbols SDK public-API parity candidate.
// Independent replacement subset for research: not Apple's Symbols.framework.
// Exact exported names, API shape, resilient layout and witness semantics are
// distinct tests. Do NOT install this in production or claim animations work.
import Foundation

// Internal surrogate. Apple SDK exposes no public members of this struct.
// Its true stored layout is still UNKNOWN; never claim ABI equivalence.
public struct SymbolEffectConfiguration: Hashable, Sendable {
    internal enum Kind: UInt8, Hashable, Sendable {
        case automatic = 0, replace = 1
    }
    internal var kind: Kind
    internal var scope: UInt8
    internal init(kind: Kind, scope: UInt8 = 0) {
        self.kind = kind
        self.scope = scope
    }
}

public protocol SymbolEffect: Hashable, Sendable {
    var configuration: SymbolEffectConfiguration { get }
}
public protocol ContentTransitionSymbolEffect: SymbolEffect {}

public struct ReplaceSymbolEffect: SymbolEffect, ContentTransitionSymbolEffect {
    public var configuration: SymbolEffectConfiguration

    // Constructed with the public zero-argument mangling expected by V070.
    public init() {
        self.configuration = SymbolEffectConfiguration(kind: .replace)
    }
    internal init(scope: UInt8) {
        self.configuration = SymbolEffectConfiguration(kind: .replace, scope: scope)
    }
    public var downUp: Self { Self(scope: 1) }
    public var offUp: Self { Self(scope: 2) }
    public var upUp: Self { Self(scope: 3) }
    public var byLayer: Self {
        var result = self
        result.configuration.scope |= 0x10
        return result
    }
    public var wholeSymbol: Self {
        var result = self
        result.configuration.scope &= ~0x10
        return result
    }
    public static var downUp: Self { Self(scope: 1) }
    public static var offUp: Self { Self(scope: 2) }
    public static var upUp: Self { Self(scope: 3) }
    public struct MagicReplace: SymbolEffect, ContentTransitionSymbolEffect {
        public let fallback: ReplaceSymbolEffect
        public var configuration: SymbolEffectConfiguration {
            fallback.configuration
        }
        public init(fallback: ReplaceSymbolEffect) {
            self.fallback = fallback
        }
    }
    public func magic(fallback: Self) -> MagicReplace {
        MagicReplace(fallback: fallback)
    }
}

public struct AutomaticSymbolEffect: SymbolEffect, ContentTransitionSymbolEffect {
    public var configuration: SymbolEffectConfiguration
    public init() {
        self.configuration = SymbolEffectConfiguration(kind: .automatic)
    }
}

public struct SymbolEffectOptions: Hashable, Sendable {
    // Internal representation models real user-visible repeat + speed requests,
    // but is NOT asserted to match Apple's private struct memory layout.
    internal var speedMultiplier: Double
    internal var repeatCount: Int?
    internal var indefinite: Bool

    internal init(speedMultiplier: Double = 1.0, repeatCount: Int? = nil,
                  indefinite: Bool = false) {
        self.speedMultiplier = speedMultiplier.isFinite && speedMultiplier > 0
            ? speedMultiplier : 1.0
        self.repeatCount = repeatCount
        self.indefinite = indefinite
    }

    public static var `default`: Self { Self() }
    public static func speed(_ value: Double) -> Self {
        Self(speedMultiplier: value)
    }
    public static var repeating: Self {
        Self(indefinite: true)
    }
    public var repeating: Self {
        var result = self
        result.indefinite = true
        result.repeatCount = nil
        return result
    }
    public static var nonRepeating: Self {
        Self(repeatCount: 1)
    }
    public var nonRepeating: Self {
        var result = self
        result.repeatCount = 1
        result.indefinite = false
        return result
    }
    public enum RepeatBehavior: Hashable, Sendable {
        case indefinite
        case once
        case count(Int)
    }
    public static func `repeat`(_ count: Int? = nil) -> Self {
        Self(repeatCount: count.map { max(0, $0) }, indefinite: count == nil)
    }
    public func `repeat`(_ count: Int? = nil) -> Self {
        var result = self
        result.repeatCount = count.map { max(0, $0) }
        result.indefinite = count == nil
        return result
    }
    public func `repeat`(_ behavior: RepeatBehavior) -> Self {
        switch behavior {
        case .indefinite: return self.repeating
        case .once: return self.nonRepeating
        case .count(let count): return self.`repeat`(count)
        }
    }
}

public extension SymbolEffect where Self == ReplaceSymbolEffect {
    static var replace: ReplaceSymbolEffect { ReplaceSymbolEffect() }
}
public extension SymbolEffect where Self == AutomaticSymbolEffect {
    static var automatic: AutomaticSymbolEffect { AutomaticSymbolEffect() }
}

// No mock finance authorization, app-distributor state, or system service hooks.
// Real iOS16 SwiftUI symbol animation integration has NOT been established.
