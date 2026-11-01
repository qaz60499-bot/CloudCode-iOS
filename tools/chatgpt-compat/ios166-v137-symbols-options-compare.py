"""Validate full V137 option coverage and an Apple-compiled host client swap."""
import argparse
import importlib.util
import json
from pathlib import Path

CASES = tuple('''default speed1 speed2 speedHalf speed0 speedNegative speedInfinity
speedNaN speed2then1 repeating nonRepeating repeatNil repeat0 repeat1 repeat2
repeatNegative continuous periodic periodicNil periodicDelay0 periodicDelayNegative
periodicDelayInfinity periodicDelayNaN periodic2DelayHalf periodic2Delay0
speed2repeat2 repeat2speed2 continuousThenPeriodic periodicThenContinuous
repeat2ThenNonRepeating speedNegativeThen2 repeatNegativeDelay0 repeat2ThenNil
speed2Repeat2ThenNil repeatNegative2 speedNegative2 periodic2DelayNegative
periodic2DelayInfinity periodic2DelayNaN periodic2ThenNil'''.split())


def validate(report):
    expected = {a + '==' + b for a in CASES for b in CASES}
    witnesses = {a + ':' + b for a in CASES for b in ('generic', 'existential')}
    if not isinstance(report, dict) or set(report.get('semantic_equalities', {})) != expected:
        raise ValueError('incomplete V137 option coverage')
    if set(report.get('witness_calls', {})) != witnesses:
        raise ValueError('incomplete V137 witness coverage')
    if not isinstance(report.get('runtime_os'), str) or not report['runtime_os']:
        raise ValueError('missing runtime identity')
    layouts = report.get('value_layouts')
    if not isinstance(layouts, dict) or set(layouts) != {'SymbolEffectOptions'}:
        raise ValueError('missing option layout')
    layout = layouts['SymbolEffectOptions']
    if not isinstance(layout, dict) or set(layout) != {'size', 'stride', 'alignment'}:
        raise ValueError('invalid option layout')
    if any(type(v) is not int or v <= 0 or v > 4096 for v in layout.values()):
        raise ValueError('invalid layout dimension')
    if layout['size'] > layout['stride'] or layout['stride'] % layout['alignment']:
        raise ValueError('invalid layout geometry')


def compare(apple, candidate, swapped, execution):
    for report in (apple, candidate, swapped):
        validate(report)
    if len({r['runtime_os'] for r in (apple, candidate, swapped)}) != 1:
        raise ValueError('native runtime differs')
    if (type(execution.get('returncode')) is not int or execution['returncode'] != 0
            or execution.get('timed_out') is not False or execution.get('stderr') != ''):
        raise ValueError('Apple-compiled swapped client did not exit cleanly')
    path = Path(__file__).with_name('ios166-v136-symbols-behavior-compare.py')
    spec = importlib.util.spec_from_file_location('v136_comparator', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    behavior = module.compare(apple, candidate)
    swap = module.compare(candidate, swapped)
    passed = (behavior['status'] == swap['status'] == 'PASS_SELECTED_NATIVE_CALLS_ONLY'
              and candidate['value_layouts'] == swapped['value_layouts'])
    return {
        'schema': 'ipa-total-v137-symbols-options-comparison/1',
        'status': 'PASS_SELECTED_OPTIONS_AND_HOST_BINARY_SWAP' if passed else 'FAIL',
        'semantic_comparisons': len(apple['semantic_equalities']),
        'behavior_mismatches': behavior['behavior_mismatches'],
        'failed_witness_calls': behavior['failed_witness_calls'],
        'apple_compiled_swap_mismatches': swap['behavior_mismatches'],
        'apple_compiled_swap_witness_failures': swap['failed_witness_calls'],
        'apple_compiled_swap_layout_matches_candidate': candidate['value_layouts'] == swapped['value_layouts'],
        'host_layout_observations': behavior['layout_observations'],
        # Resilient Swift types may use runtime value-witness geometry. Host
        # substitution tests establish selected calls, never global iOS ABI.
        'ios16_abi_gate': 'BLOCKED_NEEDS_TARGET_RUNTIME_AND_OFFICIAL_CALLS',
        'ios16_device_execution_proven': False, 'rendering_proven': False,
        'official_boot_plaintext': '0/6', 'official_features': '0/5',
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('apple', 'candidate', 'swapped', 'execution', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    result = compare(*(json.loads(getattr(args, n).read_text())
                       for n in ('apple', 'candidate', 'swapped', 'execution')))
    args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['status'].startswith('PASS_') else 1)
