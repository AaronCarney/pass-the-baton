#!/usr/bin/env python3
"""Private compute for tools/retry-intent-promote.sh - kappa + accuracy + macro-F1."""
import argparse, csv, json, sys
from sklearn.metrics import cohen_kappa_score, accuracy_score, f1_score


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--input', default='-')
    args = p.parse_args()
    f = sys.stdin if args.input == '-' else open(args.input)
    reader = csv.DictReader(f)
    rows = list(reader)
    pairs = [(r['human_a'].strip(), r['human_b'].strip()) for r in rows if r.get('human_a', '').strip() and r.get('human_b', '').strip()]
    a = [p[0] for p in pairs]
    b = [p[1] for p in pairs]
    kappa = float(cohen_kappa_score(a, b)) if len(pairs) >= 2 else 0.0
    # majority/agreement subset
    judge_pairs = []
    majority = []
    for r in rows:
        ha = r.get('human_a', '').strip()
        hb = r.get('human_b', '').strip()
        jl = r.get('judge_label', '').strip()
        if ha and hb and jl and ha == hb:
            majority.append(ha)
            judge_pairs.append(jl)
    acc = float(accuracy_score(majority, judge_pairs)) if majority else 0.0
    macro_f1 = float(f1_score(majority, judge_pairs, average='macro', zero_division=0)) if majority else 0.0
    out = {
        'kappa': kappa,
        'accuracy': acc,
        'macro_f1': macro_f1,
        'n_human_pairs': len(pairs),
        'n_agreement': len(majority),
        'n_judge_labeled': sum(1 for r in rows if r.get('judge_label', '').strip()),
    }
    print(json.dumps(out))


if __name__ == '__main__':
    main()
