// Native host checks of the compatibility candidate's request composition only.
// These do not run Apple's Symbols or establish binary layout/rendering parity.
import Foundation

@main
struct OptionsCompositionCheck {
    static func main() {
        let periodic = SymbolEffectOptions.RepeatBehavior.periodic(3, delay: 0.25)
        let first = SymbolEffectOptions.repeat(periodic).speed(2.0)
        precondition(first.speedMultiplier == 2.0)
        precondition(first.repeatRequest == periodic.request)
        let second = SymbolEffectOptions.speed(2.0).repeat(periodic)
        precondition(first == second)
        precondition(SymbolEffectOptions.repeat(.continuous).repeatRequest !=
                     SymbolEffectOptions.repeat(.periodic).repeatRequest)
        precondition(SymbolEffectOptions.repeat(4).repeatRequest?.count == 4)
        precondition(SymbolEffectOptions.repeat(nil).repeatRequest == nil)
        precondition(first.repeat(nil).repeatRequest == nil)
        precondition(first.repeat(nil).speedMultiplier == 2.0)
        precondition(SymbolEffectOptions.default.repeatRequest == nil)
        let changed = first.speed(0.5)
        precondition(changed.speedMultiplier == 0.5)
        precondition(changed.repeatRequest?.count == 3)
        precondition(changed.repeatRequest?.delay == 0.25)
        precondition(first.speedMultiplier == 2.0)
        let once = first.nonRepeating
        precondition(once.speedMultiplier == 2.0)
        precondition(once.repeatRequest?.kind == .periodic)
        precondition(once.repeatRequest?.count == 1)
        precondition(once.repeatRequest?.delay == nil)
        let forever = once.repeating
        precondition(forever.speedMultiplier == 2.0)
        precondition(forever.repeatRequest?.count == nil)
        precondition(forever.repeatRequest?.kind == .periodic)
        // V137: match observed Apple requests; no invented normalization.
        precondition(first.speed(.nan).speedMultiplier.isNaN)
        precondition(first.speed(0).speedMultiplier == 0)
        precondition(first.speed(-1).speedMultiplier == -1)
        precondition(first.speed(.infinity).speedMultiplier == .infinity)
        precondition(first.speed(-1).repeatRequest == periodic.request)
        precondition(SymbolEffectOptions.RepeatBehavior.periodic(-2, delay: .infinity).request.count == -2)
        precondition(SymbolEffectOptions.RepeatBehavior.periodic(-2, delay: .infinity).request.delay == .infinity)
        precondition(SymbolEffectOptions.RepeatBehavior.periodic(1, delay: -1).request.delay == -1)
        print("CANDIDATE_OPTIONS_COMPOSITION_PASS_NOT_APPLE_RENDERER_OR_ABI_PROOF")
    }
}
