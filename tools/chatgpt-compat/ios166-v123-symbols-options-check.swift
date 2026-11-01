// Native host checks of the compatibility candidate's request composition only.
// These do not run Apple's Symbols or establish binary layout/rendering parity.
import Foundation

@main
struct OptionsCompositionCheck {
    static func main() {
        let periodic = SymbolEffectOptions.RepeatBehavior.periodic(3, delay: 0.25)
        let first = SymbolEffectOptions.repeat(periodic).speed(2.0)
        precondition(first.speedMultiplier == 2.0)
        precondition(first.repeatBehavior == periodic)
        let second = SymbolEffectOptions.speed(2.0).repeat(periodic)
        precondition(first == second)
        precondition(SymbolEffectOptions.repeat(.continuous).repeatBehavior !=
                     SymbolEffectOptions.repeat(.periodic).repeatBehavior)
        precondition(SymbolEffectOptions.repeat(4).repeatBehavior?.count == 4)
        precondition(SymbolEffectOptions.repeat().repeatBehavior?.count == nil)
        precondition(SymbolEffectOptions.default.repeatBehavior == nil)
        let changed = first.speed(0.5)
        precondition(changed.speedMultiplier == 0.5)
        precondition(changed.repeatBehavior?.count == 3)
        precondition(changed.repeatBehavior?.delay == 0.25)
        precondition(first.speedMultiplier == 2.0)
        let once = first.nonRepeating
        precondition(once.speedMultiplier == 2.0)
        precondition(once.repeatBehavior?.kind == .periodic)
        precondition(once.repeatBehavior?.count == 1)
        precondition(once.repeatBehavior?.delay == nil)
        let forever = once.repeating
        precondition(forever.speedMultiplier == 2.0)
        precondition(forever.repeatBehavior?.count == nil)
        precondition(forever.repeatBehavior?.kind == .periodic)
        // Explicit candidate normalization, not an assertion about Apple limits.
        precondition(first.speed(.nan).speedMultiplier == 1.0)
        precondition(first.speed(-1).repeatBehavior == periodic)
        precondition(SymbolEffectOptions.RepeatBehavior.periodic(-2, delay: .infinity).count == 0)
        precondition(SymbolEffectOptions.RepeatBehavior.periodic(1, delay: -1).delay == nil)
        print("CANDIDATE_OPTIONS_COMPOSITION_PASS_NOT_APPLE_RENDERER_OR_ABI_PROOF")
    }
}
