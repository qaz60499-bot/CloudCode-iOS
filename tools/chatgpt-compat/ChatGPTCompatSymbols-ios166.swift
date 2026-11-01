// IPA Total V136 - iOS16.6 Symbols public-API subset candidate.
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
public protocol ContentTransitionSymbolEffect {}
public protocol TransitionSymbolEffect {}

public struct ReplaceSymbolEffect: SymbolEffect, ContentTransitionSymbolEffect {
    public var configuration: SymbolEffectConfiguration

    // Constructed with the public zero-argument mangling expected by V070.
    public init() {
        self.configuration = SymbolEffectConfiguration(kind: .replace)
    }
    internal init(scope: UInt8) {
        self.configuration = SymbolEffectConfiguration(kind: .replace, scope: scope)
    }
    // Direction and explicit layer selection compose independently. These are
    // surrogate bits, NOT Apple's private representation. V136 native Apple
    // equality tests distinguish unspecified, byLayer and wholeSymbol requests.
    internal func withDirection(_ direction: UInt8) -> Self {
        var result = self
        result.configuration.scope = (result.configuration.scope & 0xF0) | direction
        return result
    }
    public var downUp: Self { withDirection(1) }
    public var offUp: Self { withDirection(2) }
    public var upUp: Self { withDirection(3) }
    public var byLayer: Self {
        var result = self
        result.configuration.scope = (result.configuration.scope & ~0x30) | 0x10
        return result
    }
    public var wholeSymbol: Self {
        var result = self
        result.configuration.scope = (result.configuration.scope & ~0x30) | 0x20
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

public struct AutomaticSymbolEffect: SymbolEffect, ContentTransitionSymbolEffect, TransitionSymbolEffect {
    public var configuration: SymbolEffectConfiguration
    public init() {
        self.configuration = SymbolEffectConfiguration(kind: .automatic)
    }
}

public struct SymbolEffectOptions: Hashable, Sendable {
    // Internal representation models real user-visible repeat + speed requests,
    // but is NOT asserted to match Apple's private struct memory layout.
    internal var speedMultiplier: Double
    internal var repeatRequest: RepeatRequest?

    internal init(speedMultiplier: Double = 1.0, repeatRequest: RepeatRequest? = nil) {
        self.speedMultiplier = speedMultiplier.isFinite && speedMultiplier > 0
            ? speedMultiplier : 1.0
        self.repeatRequest = repeatRequest
    }

    public static var `default`: Self { Self() }
    public static func speed(_ value: Double) -> Self {
        Self.default.speed(value)
    }
    public func speed(_ value: Double) -> Self {
        var result = self
        result.speedMultiplier = value.isFinite && value > 0 ? value : 1.0
        return result
    }
    public static var repeating: Self {
        Self.default.repeating
    }
    public var repeating: Self {
        self.`repeat`(.periodic)
    }
    public static var nonRepeating: Self {
        Self.default.nonRepeating
    }
    public var nonRepeating: Self {
        self.`repeat`(.periodic(1))
    }
    // The SDK's nested type is a struct, not the previous guessed enum.
    // Preserve periodic and continuous requests distinctly. No renderer or
    // equivalence to Apple's resilient value layout is implied by these fields.
    internal struct RepeatRequest: Hashable, Sendable {
        internal enum Kind: UInt8, Hashable, Sendable {
            case periodic, continuous
        }
        internal var kind: Kind
        internal var count: Int?
        internal var delay: Double?

        internal init(kind: Kind, count: Int? = nil, delay: Double? = nil) {
            self.kind = kind
            self.count = count.map { max(0, $0) }
            self.delay = delay.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
    }
    public struct RepeatBehavior {
        // Apple does not expose Hashable/Sendable conformances for this type.
        // Keep comparable/sendable storage in the internal request instead.
        internal var request: RepeatRequest
        internal init(request: RepeatRequest) { self.request = request }
        public static var continuous: Self { Self(request: RepeatRequest(kind: .continuous)) }
        public static var periodic: Self { Self(request: RepeatRequest(kind: .periodic)) }
        public static func periodic(_ count: Int? = nil, delay: Double? = nil) -> Self {
            Self(request: RepeatRequest(kind: .periodic, count: count, delay: delay))
        }
    }
    public static func `repeat`(_ count: Int? = nil) -> Self {
        Self.default.`repeat`(count)
    }
    public func `repeat`(_ count: Int? = nil) -> Self {
        self.`repeat`(.periodic(count))
    }
    public static func `repeat`(_ behavior: RepeatBehavior) -> Self {
        Self.default.`repeat`(behavior)
    }
    public func `repeat`(_ behavior: RepeatBehavior) -> Self {
        var result = self
        result.repeatRequest = behavior.request
        return result
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
