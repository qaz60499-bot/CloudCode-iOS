// Compiled as a separate client against Apple Symbols and the candidate.
// This tests real generic/existential calls, not metadata-name presence.
import Foundation
#if IPA_HOST_CANDIDATE
import IPASymbolsCandidate
#else
import Symbols
#endif

@inline(never)
func genericConfiguration<T: SymbolEffect>(_ effect: T) -> SymbolEffectConfiguration {
    effect.configuration
}

@inline(never)
func existentialConfiguration(_ effect: any SymbolEffect) -> SymbolEffectConfiguration {
    effect.configuration
}

func layout<T>(_ type: T.Type) -> [String: Int] {
    ["size": MemoryLayout<T>.size, "stride": MemoryLayout<T>.stride,
     "alignment": MemoryLayout<T>.alignment]
}

@main
struct SymbolsBehaviorCheck {
    static func main() throws {
        let base: ReplaceSymbolEffect = .replace
        let automatic: AutomaticSymbolEffect = .automatic
        let values: [(String, ReplaceSymbolEffect)] = [
            ("base", base), ("byLayer", base.byLayer), ("wholeSymbol", base.wholeSymbol),
            ("downUp", base.downUp), ("offUp", base.offUp), ("upUp", base.upUp),
            ("downUp_byLayer", base.downUp.byLayer), ("byLayer_downUp", base.byLayer.downUp),
            ("offUp_byLayer", base.offUp.byLayer), ("byLayer_offUp", base.byLayer.offUp),
            ("upUp_byLayer", base.upUp.byLayer), ("byLayer_upUp", base.byLayer.upUp),
            ("downUp_wholeSymbol", base.downUp.wholeSymbol),
            ("wholeSymbol_downUp", base.wholeSymbol.downUp),
            ("byLayer_downUp_offUp", base.byLayer.downUp.offUp),
            ("byLayer_offUp_downUp", base.byLayer.offUp.downUp),
            ("byLayer_wholeSymbol", base.byLayer.wholeSymbol),
            ("wholeSymbol_byLayer", base.wholeSymbol.byLayer)
        ]
        var equalities: [String: Bool] = [:]
        var witnesses: [String: Bool] = [:]
        for (name, value) in values {
            witnesses[name + ":generic"] = genericConfiguration(value) == value.configuration
            witnesses[name + ":existential"] = existentialConfiguration(value) == value.configuration
            witnesses[name + ":hashable"] = AnyHashable(value) == AnyHashable(value)
            for (otherName, otherValue) in values {
                equalities[name + "==" + otherName] = value == otherValue
                equalities[name + ":configuration==" + otherName] =
                    value.configuration == otherValue.configuration
            }
        }
        witnesses["automatic:generic"] = genericConfiguration(automatic) == automatic.configuration
        witnesses["automatic:existential"] = existentialConfiguration(automatic) == automatic.configuration
        let report: [String: Any] = [
            "schema": "ipa-total-v136-symbols-behavior/1",
            "runtime_os": ProcessInfo.processInfo.operatingSystemVersionString,
            "semantic_equalities": equalities,
            "witness_calls": witnesses,
            "value_layouts": [
                "ReplaceSymbolEffect": layout(ReplaceSymbolEffect.self),
                "AutomaticSymbolEffect": layout(AutomaticSymbolEffect.self),
                "SymbolEffectConfiguration": layout(SymbolEffectConfiguration.self),
                "SymbolEffectOptions": layout(SymbolEffectOptions.self)
            ],
            "rendering_tested": false, "official_app_tested": false
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
