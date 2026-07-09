#!/usr/bin/env python3
"""Private compute tier for lib/stats-bootstrap.sh. Not user-facing - bash wrapper is the public API."""
import argparse, json, sys
import numpy as np
from scipy import stats as sps

def read_values(path: str) -> np.ndarray:
    raw = sys.stdin.read() if path == '-' else open(path).read()
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(float(line))
        except ValueError:
            obj = json.loads(line)
            out.append(float(obj['value']))
    return np.asarray(out, dtype=float)

def read_rows(path: str) -> list:
    raw = sys.stdin.read() if path == '-' else open(path).read()
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        out.append(json.loads(line))
    return out

def stat_mean(x): return float(np.mean(x))

def bca(x: np.ndarray, n: int, alpha: float, rng: np.random.Generator) -> dict:
    point = stat_mean(x)
    boots = np.array([stat_mean(rng.choice(x, size=len(x), replace=True)) for _ in range(n)])
    # A2-f6: scipy.stats.bootstrap uses (boots <= point).sum() / n (≤ with tie correction); we use
    # strict <. The divergence shifts z0 by at most ties/n and is dominated by Monte Carlo noise at
    # n_resamples=5000. The oracle equivalence test (T3 step 3 / T1 step 9) tolerates this via the
    # 1e-2 tolerance band on CI bounds. Documented as a known oracle-impl divergence; do not change
    # to <= without re-baselining the fixture against scipy.
    z0 = sps.norm.ppf((boots < point).sum() / n)
    # Degenerate guard: when all bootstrap samples equal the point (zero-variance data -
    # constant input, e.g. a workspace stratum where every session has identical cost),
    # z0 is -inf and the downstream quantile call raises ValueError. Return a degenerate
    # CI [point, point] with an explicit flag so callers can detect and discard rather
    # than publishing a meaningless interval.
    if not np.isfinite(z0):
        return {'point': point, 'ci_lower': point, 'ci_upper': point,
                'n_resamples': n, 'method': 'bca', 'alpha': alpha, 'degenerate': True}
    # acceleration via jackknife
    jk = np.array([stat_mean(np.delete(x, i)) for i in range(len(x))])
    jk_mean = jk.mean()
    num = ((jk_mean - jk) ** 3).sum()
    den = 6.0 * (((jk_mean - jk) ** 2).sum() ** 1.5)
    a = num / den if den != 0 else 0.0
    z_lo = sps.norm.ppf(alpha / 2)
    z_hi = sps.norm.ppf(1 - alpha / 2)
    a1 = sps.norm.cdf(z0 + (z0 + z_lo) / (1 - a * (z0 + z_lo)))
    a2 = sps.norm.cdf(z0 + (z0 + z_hi) / (1 - a * (z0 + z_hi)))
    # Secondary degenerate guard: if jackknife acceleration drives a1/a2 to NaN
    # (rare but possible on perfectly symmetric data), fall back to the degenerate CI.
    if not (np.isfinite(a1) and np.isfinite(a2)):
        return {'point': point, 'ci_lower': point, 'ci_upper': point,
                'n_resamples': n, 'method': 'bca', 'alpha': alpha, 'degenerate': True}
    lo = float(np.quantile(boots, a1))
    hi = float(np.quantile(boots, a2))
    return {'point': point, 'ci_lower': lo, 'ci_upper': hi, 'n_resamples': n, 'method': 'bca', 'alpha': alpha}

def studentized(x: np.ndarray, n: int, alpha: float, rng: np.random.Generator) -> dict:
    point = stat_mean(x)
    se = float(np.std(x, ddof=1) / np.sqrt(len(x)))
    t_boots = []
    for _ in range(n):
        sample = rng.choice(x, size=len(x), replace=True)
        m = stat_mean(sample)
        s = float(np.std(sample, ddof=1) / np.sqrt(len(sample)))
        if s > 0:
            t_boots.append((m - point) / s)
    t_arr = np.asarray(t_boots)
    # Degenerate guard (symmetric with bca): a size-1 or zero-variance stratum makes
    # se non-finite and leaves t_arr empty, so np.quantile has nothing to reduce
    # (raises IndexError on numpy>=2). Fall back to the point CI.
    if t_arr.size == 0 or not np.isfinite(se):
        return {'point': point, 'ci_lower': point, 'ci_upper': point,
                'n_resamples': n, 'method': 'studentized', 'alpha': alpha, 'degenerate': True}
    t_lo, t_hi = np.quantile(t_arr, [alpha / 2, 1 - alpha / 2])
    return {'point': point, 'ci_lower': float(point - t_hi * se), 'ci_upper': float(point - t_lo * se), 'n_resamples': n, 'method': 'studentized', 'alpha': alpha}

def block_length_auto(x: np.ndarray) -> int:
    # Politis & White (2004) spectral-density method, simplified: rule-of-thumb sqrt(n)
    # The full spectral estimator is implemented inline below for n>=50; for shorter series fall back to ceil(n**(1/3)).
    n = len(x)
    if n < 50:
        return max(1, int(np.ceil(n ** (1/3))))
    # Auto-correlation up to floor(2*sqrt(log10(n)))
    M = int(np.floor(2 * np.sqrt(np.log10(n))))
    M = max(M, 1)
    xc = x - x.mean()
    var = float((xc ** 2).mean())
    if var == 0:
        return 1
    g = lambda k: float((xc[:n-k] * xc[k:]).mean()) / var
    num = 0.0
    den = var
    for k in range(1, M + 1):
        lam = 1.0 if abs(k / M) < 0.5 else 2 * (1 - abs(k / M))
        num += 2 * lam * k * g(k)
        den += 2 * lam * g(k)
    g_hat = num
    # block length b = (2 * g_hat^2 / den^2)^(1/3) * n^(1/3); guard against degeneracy
    if den == 0:
        return max(1, int(np.ceil(n ** (1/3))))
    b = ((2 * g_hat ** 2) / (den ** 2)) ** (1/3) * n ** (1/3)
    return max(1, int(np.ceil(abs(b))))

def block(x: np.ndarray, n: int, alpha: float, rng: np.random.Generator, b: int) -> dict:
    point = stat_mean(x)
    L = len(x)
    boots = []
    for _ in range(n):
        sample = np.empty(L)
        i = 0
        while i < L:
            start = rng.integers(0, L)
            for k in range(b):
                if i + k >= L:
                    break
                sample[i + k] = x[(start + k) % L]
            i += b
        boots.append(stat_mean(sample))
    boots = np.asarray(boots)
    lo, hi = np.quantile(boots, [alpha / 2, 1 - alpha / 2])
    return {'point': point, 'ci_lower': float(lo), 'ci_upper': float(hi), 'n_resamples': n, 'method': 'block', 'alpha': alpha, 'block_length': b}

def cluster(rows: list, n: int, alpha: float, rng: np.random.Generator, cluster_key: str, value_key: str = 'value') -> dict:
    # Group values by cluster key; resample clusters with replacement;
    # statistic = mean over resampled-cluster-aggregated means.
    groups: dict = {}
    for r in rows:
        cid = r.get(cluster_key)
        if cid is None:
            continue
        groups.setdefault(cid, []).append(float(r[value_key]))
    cids = list(groups.keys())
    if not cids:
        return {'error': f'no rows with cluster key {cluster_key!r}'}
    cluster_means = np.array([float(np.mean(groups[c])) for c in cids])
    point = float(cluster_means.mean())
    boots = np.empty(n)
    n_c = len(cids)
    for i in range(n):
        idx = rng.integers(0, n_c, size=n_c)
        boots[i] = cluster_means[idx].mean()
    lo, hi = np.quantile(boots, [alpha / 2, 1 - alpha / 2])
    return {'point': point, 'ci_lower': float(lo), 'ci_upper': float(hi),
            'n_resamples': n, 'method': 'cluster', 'alpha': alpha,
            'n_clusters': n_c, 'cluster_key': cluster_key}

def cuped(rows: list, covariate_keys: list, value_key: str = 'value') -> dict:
    # F1: multi-covariate CUPED via stacked design matrix.
    # Numerical covariates: raw columns. Categorical: one-hot (drop first level).
    # Theta solved by OLS on the full design; CUPED adjustment is row-wise X_centered @ theta.
    # Target/mean-encoding is FORBIDDEN (post-treatment leakage of Y into X).
    y = np.array([float(r[value_key]) for r in rows], dtype=float)
    cols = []       # list of 1-D arrays
    col_names = []  # parallel list for diagnostics
    for ck in covariate_keys:
        vals = [r.get(ck) for r in rows]
        if any(isinstance(v, str) for v in vals):
            # One-hot expand, drop the first level for identifiability.
            levels = sorted({str(v) for v in vals})
            if len(levels) < 2:
                continue  # constant categorical contributes nothing
            for lvl in levels[1:]:
                cols.append(np.array([1.0 if str(v) == lvl else 0.0 for v in vals], dtype=float))
                col_names.append(f'{ck}={lvl}')
        else:
            arr = np.array(vals, dtype=float)
            if np.var(arr) == 0:
                continue  # constant numeric column contributes nothing
            cols.append(arr)
            col_names.append(ck)
    if not cols:
        return {'error': f'no usable covariates in {covariate_keys!r}'}
    X = np.column_stack(cols)                       # (n, p)
    X_centered = X - X.mean(axis=0, keepdims=True)
    y_centered = y - y.mean()
    # OLS via lstsq (handles rank-deficient cases via SVD).
    theta, *_rest = np.linalg.lstsq(X_centered, y_centered, rcond=None)
    y_cuped = y - X_centered @ theta
    var_y = float(np.var(y, ddof=1))
    var_y_cuped = float(np.var(y_cuped, ddof=1))
    # R^2 of the projection (analytic equivalent of variance reduction).
    ss_res = float(np.sum((y_centered - X_centered @ theta) ** 2))
    ss_tot = float(np.sum(y_centered ** 2))
    r_squared = 1.0 - ss_res / ss_tot if ss_tot > 0 else 0.0
    return {
        'point': float(y_cuped.mean()),
        'original_mean': float(y.mean()),
        'theta': theta.tolist(),
        'theta_columns': col_names,
        'r_squared': r_squared,
        'variance_original': var_y,
        'variance_cuped': var_y_cuped,
        'variance_reduction_ratio': 1.0 - var_y_cuped / var_y if var_y > 0 else 0.0,
        'covariate_keys': covariate_keys,
        'method': 'cuped',
        'citation': 'Deng et al. KDD 2013 - Improving the Sensitivity of Online Controlled Experiments by Utilizing Pre-Experiment Data',
    }

def main():
    p = argparse.ArgumentParser()
    p.add_argument('subcommand', choices=['bca', 'studentized', 'block', 'block-length-auto', 'cluster', 'cuped'])
    p.add_argument('--input', default='-', help='path to JSONL (one float or {"value": float} per line); - for stdin')
    p.add_argument('--n-resamples', type=int, default=10000)  # L0 §A5 line 69 production default
    p.add_argument('--alpha', type=float, default=0.05)
    p.add_argument('--seed', type=int, default=None)
    p.add_argument('--block-length', type=int, default=None, help='for block subcommand; if omitted, auto via Politis & White 2004')
    p.add_argument('--log', action='store_true', help='apply np.log to inputs before resampling; exp() back on point + CI bounds')
    p.add_argument('--cluster-key', default='session_id', help='row field to use as cluster identifier')
    p.add_argument('--value-key', default='value', help='row field for the numeric outcome value')
    p.add_argument('--covariate-keys', default=None, help='comma-separated covariate field names for cuped subcommand')
    args = p.parse_args()
    seed = args.seed if args.seed is not None else np.random.SeedSequence().entropy
    rng = np.random.default_rng(seed)

    def _exp_back(d):
        if not args.log:
            return d
        for k in ('point', 'ci_lower', 'ci_upper'):
            if k in d and isinstance(d[k], (int, float)) and np.isfinite(d[k]):
                d[k] = float(np.exp(d[k]))
        d['method'] = d.get('method', '') + '+log'
        return d

    if args.subcommand == 'cuped':
        rows = read_rows(args.input)
        if not args.covariate_keys:
            print(json.dumps({'error': '--covariate-keys is required for cuped (comma-separated)'}))
            sys.exit(1)
        keys = [k.strip() for k in args.covariate_keys.split(',') if k.strip()]
        print(json.dumps(cuped(rows, keys, args.value_key)))
        return

    if args.subcommand == 'cluster':
        rows = read_rows(args.input)
        if args.log:
            # --log on cluster requires per-row log-transform before cluster aggregation
            # AND exp() back-transform on the point + CI bounds. Apply both to honor the flag
            # rather than silently dropping it.
            value_key = args.value_key
            for r in rows:
                v = float(r[value_key])
                if v <= 0:
                    print(json.dumps({'error': f'--log requires positive values; got {v}'}))
                    sys.exit(1)
                r[value_key] = float(np.log(v))
            result = cluster(rows, args.n_resamples, args.alpha, rng, args.cluster_key, value_key)
            result = _exp_back(result)
        else:
            result = cluster(rows, args.n_resamples, args.alpha, rng, args.cluster_key, args.value_key)
        print(json.dumps(result))
        return

    # Scalar-valued subcommands - read plain values, support --log
    if args.subcommand == 'block-length-auto':
        x = read_values(args.input)
        if len(x) == 0:
            print(json.dumps({'error': 'empty input'}))
            sys.exit(1)
        print(json.dumps({'block_length': block_length_auto(x)}))
        return

    x = read_values(args.input)
    if len(x) == 0:
        print(json.dumps({'error': 'empty input'}))
        sys.exit(1)

    if args.log:
        if np.any(x <= 0):
            print(json.dumps({'error': 'log transform requires strictly positive values'}))
            sys.exit(1)
        x = np.log(x)

    if args.subcommand == 'bca':
        result = bca(x, args.n_resamples, args.alpha, rng)
    elif args.subcommand == 'studentized':
        result = studentized(x, args.n_resamples, args.alpha, rng)
    elif args.subcommand == 'block':
        b = args.block_length if args.block_length is not None else block_length_auto(x)
        result = block(x, args.n_resamples, args.alpha, rng, b)

    print(json.dumps(_exp_back(result)))

if __name__ == '__main__':
    main()
