#!/usr/bin/env python3
"""Summarize asko JSONL metadata. Overlapping parent/child times are not additive."""
import argparse
import collections
import json
import math
import statistics
import sys


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', nargs='*', help='JSONL files, including rotations; default stdin')
    parser.add_argument('--kind', default='job', help='trace kind, or all (default job)')
    parser.add_argument('--job-id', type=int)
    args = parser.parse_args()
    stages = collections.defaultdict(list)
    models = collections.defaultdict(list)
    seen = set()
    malformed = 0
    def rows():
        for path in args.files or ['-']:
            stream = sys.stdin if path == '-' else open(path, encoding='utf-8')
            try:
                yield from stream
            finally:
                if stream is not sys.stdin:
                    stream.close()
    for line in rows():
        try:
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError('expected object')
        except (ValueError, TypeError):
            malformed += 1
            continue
        if args.kind != 'all' and row.get('kind') != args.kind:
            continue
        if args.job_id is not None and str(row.get('job_id')) != str(args.job_id):
            continue
        event = row.get('event')
        if event not in ('span_end', 'trace_end'):
            continue
        identity = (row.get('trace_id'), event, row.get('span_id'))
        if identity in seen:
            continue
        seen.add(identity)
        duration = row.get('duration_ms')
        if not isinstance(duration, (float, int)) or not math.isfinite(duration) or duration < 0:
            malformed += 1
            continue
        stage = 'trace:' + str(row.get('kind')) if event == 'trace_end' else row.get('stage', '?')
        stages[stage].append(row)
        if stage == 'model_request':
            models[row.get('model', '?')].append(row)
    print('Duration in ms. Nested and concurrent spans overlap; do not sum stage means.')
    print(f'{"stage":28} {"n":>6} {"mean":>10} {"p50":>10} {"p95":>10} {"max":>10} {"err/cancel":>11}')
    for stage, rows in sorted(stages.items()):
        values = [r['duration_ms'] for r in rows]
        errors = sum(r.get('status') == 'error' for r in rows)
        cancelled = sum(r.get('status') == 'cancelled' for r in rows)
        print(f'{stage:28} {len(rows):6} {statistics.mean(values):10.1f} {percentile(values,.5):10.1f} '
              f'{percentile(values,.95):10.1f} {max(values):10.1f} {str(errors)+"/"+str(cancelled):>11}')
    print('\nAPI-reported cost only; unknown costs are excluded from the subtotal.')
    for model, rows in sorted(models.items()):
        known = [r['cost_usd'] for r in rows if isinstance(r.get('cost_usd'), (int, float))
                 and math.isfinite(r['cost_usd']) and r['cost_usd'] >= 0]
        print(f'{model}: calls={len(rows)} known={len(known)} unknown={len(rows)-len(known)} '
              f'known_cost_usd={sum(known):.8f}')
    print(f'Ignored malformed records: {malformed}')


if __name__ == '__main__':
    main()
