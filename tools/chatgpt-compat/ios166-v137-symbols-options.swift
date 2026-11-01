// Independent client: compile once against Apple and once against the candidate.
// Equality partitions expose request normalization without reading private storage.
import Foundation
#if IPA_HOST_CANDIDATE
import IPASymbolsCandidate
#else
import Symbols
#endif

@inline(never)
func genericEqual<T: Equatable>(_ left: T, _ right: T) -> Bool { left == right }

@main
struct OptionsDifferential {
    static func main() throws {
        let values: [(String, SymbolEffectOptions)] = [
            ("default", .default), ("speed1", .speed(1)), ("speed2", .speed(2)),
            ("speedHalf", .speed(0.5)), ("speed0", .speed(0)),
            ("speedNegative", .speed(-1)), ("speedInfinity", .speed(.infinity)),
            ("speedNaN", .speed(.nan)), ("speed2then1", .speed(2).speed(1)),
            ("repeating", .repeating), ("nonRepeating", .nonRepeating),
            ("repeatNil", .repeat(nil)), ("repeat0", .repeat(0)),
            ("repeat1", .repeat(1)), ("repeat2", .repeat(2)),
            ("repeatNegative", .repeat(-1)), ("continuous", .repeat(.continuous)),
            ("periodic", .repeat(.periodic)),
            ("periodicNil", .repeat(.periodic(nil, delay: nil))),
            ("periodicDelay0", .repeat(.periodic(nil, delay: 0))),
            ("periodicDelayNegative", .repeat(.periodic(nil, delay: -1))),
            ("periodicDelayInfinity", .repeat(.periodic(nil, delay: .infinity))),
            ("periodicDelayNaN", .repeat(.periodic(nil, delay: .nan))),
            ("periodic2DelayHalf", .repeat(.periodic(2, delay: 0.5))),
            ("periodic2Delay0", .repeat(.periodic(2, delay: 0))),
            ("speed2repeat2", .speed(2).repeat(2)),
            ("repeat2speed2", .repeat(2).speed(2)),
            ("continuousThenPeriodic", .repeat(.continuous).repeat(.periodic)),
            ("periodicThenContinuous", .repeat(.periodic).repeat(.continuous)),
            ("repeat2ThenNonRepeating", .repeat(2).nonRepeating),
            ("speedNegativeThen2", .speed(-1).speed(2)),
            ("repeatNegativeDelay0", .repeat(.periodic(-1, delay: 0))),
            ("repeat2ThenNil", .repeat(2).repeat(nil)),
            ("speed2Repeat2ThenNil", .speed(2).repeat(2).repeat(nil)),
            ("repeatNegative2", .repeat(-2)), ("speedNegative2", .speed(-2)),
            ("periodic2DelayNegative", .repeat(.periodic(2, delay: -1))),
            ("periodic2DelayInfinity", .repeat(.periodic(2, delay: .infinity))),
            ("periodic2DelayNaN", .repeat(.periodic(2, delay: .nan))),
            ("periodic2ThenNil", .repeat(.periodic(2, delay: 0.5)).repeat(nil)),
        ]
        var equalities: [String: Bool] = [:]
        var witnesses: [String: Bool] = [:]
        for (name, value) in values {
            // Compare dispatch paths, not an assumed reflexivity for NaN input.
            witnesses[name + ":generic"] = genericEqual(value, value) == (value == value)
            witnesses[name + ":existential"] = (AnyHashable(value) == AnyHashable(value)) == (value == value)
            for (otherName, other) in values {
                equalities[name + "==" + otherName] = value == other
            }
        }
        let report: [String: Any] = [
            "schema": "ipa-total-v136-symbols-behavior/1",
            "runtime_os": ProcessInfo.processInfo.operatingSystemVersionString,
            "semantic_equalities": equalities, "witness_calls": witnesses,
            "value_layouts": ["SymbolEffectOptions": [
                "size": MemoryLayout<SymbolEffectOptions>.size,
                "stride": MemoryLayout<SymbolEffectOptions>.stride,
                "alignment": MemoryLayout<SymbolEffectOptions>.alignment]],
            "rendering_tested": false, "official_app_tested": false
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
