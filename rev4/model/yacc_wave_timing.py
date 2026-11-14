"""Measure YACC handshake timing from a VCS VCD, without modifying the wave."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


SIGNALS = ('clk rst_n commit_trigger commit_mask commit_bank commit_busy '
           'drain_valid drain_bank drain_yield yb_valid yb_ready yb_last '
           'dut.cstate dut.cmask_left dut.lane_sel dut.row_sel dut.we0 dut.we1 '
           'dut.dstate dut.v_set_req').split()


def edges(path):
    """Yield (ps, pre-edge values, settled values); selected signals only.

    VCD delta order is not a sampling contract. The pre-edge snapshot is taken
    before *all* changes at a rising-edge timestamp, and post is after all of
    them. This bench drives stimulus at falling edges.
    """
    scope, symbols, values = [], {}, {}
    with Path(path).open() as stream:
        for line in stream:
            words = line.split()
            if not words:
                continue
            if words[0] == '$scope':
                scope.append(words[2])
            elif words[0] == '$upscope':
                scope.pop()
            elif words[0] == '$var':
                name = '.'.join(scope + [words[4]])
                relative = name[len('tb_yacc_v4.'):] if name.startswith('tb_yacc_v4.') else name
                if relative in SIGNALS:
                    symbols.setdefault(words[3], []).append(relative)
            elif words[0] == '$enddefinitions':
                break
        found = set(name for names in symbols.values() for name in names)
        if found != set(SIGNALS):
            raise ValueError('missing signals: ' + ', '.join(sorted(set(SIGNALS)-found)))
        timestamp, before = None, {}
        for line in stream:
            line = line.strip()
            if not line:
                continue
            if line.startswith('#'):
                if timestamp is not None and before.get('clk') == 0 and values.get('clk') == 1:
                    yield timestamp, before, dict(values)
                timestamp = int(line[1:])
                before = dict(values)
            elif line[0] in '01xXzZbB':
                if line[0] in 'bB':
                    bits, symbol = line[1:].split()
                else:
                    bits, symbol = line[0], line[1:]
                if symbol in symbols:
                    value = None if any(c in bits.lower() for c in 'xz') else int(bits, 2)
                    for name in symbols[symbol]:
                        values[name] = value
        if timestamp is not None and before.get('clk') == 0 and values.get('clk') == 1:
            yield timestamp, before, dict(values)


def measure(path):
    commits, drains = [], []
    commit, drain = None, None
    yields = 0
    previous_time, period = None, None
    for cycle, (time, pre, post) in enumerate(edges(path)):
        if previous_time is not None:
            delta = time - previous_time
            if period is None:
                period = delta
            elif period != delta:
                raise ValueError('nonuniform clock')
        previous_time = time
        if pre.get('rst_n') != 1:
            if commit or drain:
                raise ValueError('reset interrupted transaction')
            continue
        if any(pre.get(key) is None for key in SIGNALS):
            raise ValueError('unknown selected signal at cycle {}'.format(cycle))
        if pre['commit_trigger'] and pre['dut.cstate'] == 0:
            if commit:
                raise ValueError('overlapping commit records')
            commit = dict(trigger=cycle, mask=pre['commit_mask'], bank=pre['commit_bank'],
                          row_reads=[], writes=[], publications=[])
        if commit:
            if pre['dut.cstate'] == 1 and pre['dut.cmask_left'] & (1 << pre['dut.lane_sel']):
                commit['row_reads'].append(dict(cycle=cycle, lane=pre['dut.lane_sel'], row=pre['dut.row_sel']))
            if pre['dut.we0'] or pre['dut.we1']:
                commit['writes'].append(cycle)
            if pre['dut.v_set_req']:
                commit['publications'].append(cycle)
            if post['commit_busy'] == 0:
                commit['idle_visible'] = cycle
                commits.append(commit)
                commit = None
        if pre['drain_valid'] and pre['dut.dstate'] == 0:
            if drain:
                raise ValueError('overlapping drain records')
            drain = dict(accept=cycle, bank=pre['drain_bank'], beats=[], yields=0)
        if pre['drain_yield']:
            yields += 1
            if drain:
                drain['yields'] += 1
        if pre['yb_valid'] and pre['yb_ready']:
            if drain is None:
                raise ValueError('beat without drain')
            drain['beats'].append(cycle)
            if pre['yb_last']:
                drains.append(drain)
                drain = None
    if commit or drain or not commits or not drains:
        raise ValueError('incomplete or empty waveform')
    intervals = Counter()
    for item in commits:
        for left, right in zip(item['row_reads'], item['row_reads'][1:]):
            if left['lane'] == right['lane']:
                intervals[right['cycle']-left['cycle']] += 1
    return dict(clock_period_vcd_units=period, commits=commits, drains=drains,
                summary=dict(commits=len(commits), drains=len(drains),
                             rows=sum(len(c['writes']) for c in commits),
                             beats=sum(len(d['beats']) for d in drains),
                             yield_cycles=yields, row_intervals=dict(intervals)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('vcd', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--check-commit', action='store_true')
    args = parser.parse_args()
    result = measure(args.vcd)
    result['source'] = dict(path=str(args.vcd.resolve()), bytes=args.vcd.stat().st_size,
                           sha256=hashlib.sha256(args.vcd.read_bytes()).hexdigest())
    result['scope'] = 'YACC waveform timing only; no whole-tile calibration or physical PPA'
    if args.check_commit:
        import tile_cycles
        mismatches = []
        for index, commit in enumerate(result['commits']):
            predicted = tile_cycles.yacc_commit_schedule(commit['mask'], commit['trigger'])
            for field, value in predicted.items():
                if commit[field] != value:
                    mismatches.append(dict(commit=index, field=field,
                                           expected=value, actual=commit[field]))
        result['commit_comparison'] = dict(status='failed' if mismatches else 'passed',
            transactions=len(result['commits']), mismatches=mismatches,
            observed_masks=sorted(set(c['mask'] for c in result['commits'])),
            model_sha256=hashlib.sha256(Path(tile_cycles.__file__).read_bytes()).hexdigest())
    result['analyzer_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    with args.out.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps(result['summary'], indent=2))
    if args.check_commit:
        print(json.dumps(result['commit_comparison'], indent=2))
        if mismatches:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
