"""Run the Avana 1,000-user simulation against the final spec (decisions Q-001 to Q-278).

Deployment-topology comparison (design review, docs/audit/design-review/topology-options.md):

    docs/spec/05-verification/.venv/bin/python docs/audit/user-simulation/run_simulation.py --topology --seeds 8 --jobs 8

runs every topology (T1, T2, T3) in every scenario of avana_sim/world.py SCENARIOS (eth-crash only
for T3, the only topology with a WETH market) for 40 days per run, and writes summary JSON files and
aggregate.md to results/topology/.

    docs/spec/05-verification/.venv/bin/python docs/audit/user-simulation/run_simulation.py                 # base + variants
    docs/spec/05-verification/.venv/bin/python docs/audit/user-simulation/run_simulation.py --extra-seeds 4  # + 4 more base seeds
    docs/spec/05-verification/.venv/bin/python docs/audit/user-simulation/run_simulation.py --only base

Writes summary-<variant>-<seed>.json and tables-<variant>-<seed>.md to
results/final-spec/ (the run of 2026-11-09 against decisions up to Q-240 stays in
results/). Same seed -> identical output. --jobs runs the runs in parallel processes.
"""
import argparse
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from avana_sim.engine import Sim  # noqa: E402
from avana_sim.report import tables  # noqa: E402

VARIANTS = {
    'base': dict(profile='spec', repay_quote='deadline'),
    'mainnet-feeds': dict(profile='mainnet', repay_quote='deadline'),
    'literal-repay-quote': dict(profile='spec', repay_quote='literal'),
}


def one(job):
    name, seed, days, outdir = job
    t0 = time.time()
    res = Sim(seed=seed, days=days, **VARIANTS[name]).run()
    tag = '%s-%d' % (name, seed)
    blob = json.dumps(res, indent=1, sort_keys=True, default=str)
    with open(os.path.join(outdir, 'summary-%s.json' % tag), 'w') as f:
        f.write(blob)
    with open(os.path.join(outdir, 'tables-%s.md' % tag), 'w') as f:
        f.write(tables(res))
    return '%-22s seed %d  %5.1fs  sha256 %s  checks %d  liquidations %d  violations %s' % (
        name, seed, time.time() - t0, hashlib.sha256(blob.encode()).hexdigest()[:16], res['invariants']['checks'],
        res['liquidations']['calls'], res['invariants']['violations'] or 'none')


def one_topology(job):
    topo, scenario, seed, days, outdir = job
    t0 = time.time()
    res = Sim(seed=seed, days=days, topology=topo, scenario=scenario).run()
    blob = json.dumps(res, indent=1, sort_keys=True, default=str)
    with open(os.path.join(outdir, 'summary-%s-%s-%d.json' % (topo, scenario, seed)), 'w') as f:
        f.write(blob)
    return topo, scenario, seed, time.time() - t0, hashlib.sha256(blob.encode()).hexdigest()[:16], res


def topology_main(args):
    from avana_sim.world import SCENARIOS
    from avana_sim.report import topology_tables
    outdir = os.path.join(HERE, 'results', 'topology') if args.out == DEFAULT_OUT else args.out
    os.makedirs(outdir, exist_ok=True)
    seeds = [args.seed + i for i in range(args.seeds)]
    jobs = [(topo, sc, s, args.topology_days, outdir) for s in seeds for topo in ('T1', 'T2', 'T3') for sc in SCENARIOS
            if sc != 'eth-crash' or topo == 'T3']
    t0 = time.time()
    results = []
    if args.jobs > 1:
        from multiprocessing import Pool
        with Pool(args.jobs) as pool:
            for r in pool.imap_unordered(one_topology, jobs):
                results.append(r)
                print('%-3s %-13s seed %d  %5.1fs  sha256 %s  liquidations %d  violations %s' % (
                    r[0], r[1], r[2], r[3], r[4], r[5]['liquidations']['calls'], r[5]['invariants']['violations'] or 'none'), flush=True)
    else:
        for j in jobs:
            r = one_topology(j)
            results.append(r)
            print('%-3s %-13s seed %d  %5.1fs  sha256 %s' % (r[0], r[1], r[2], r[3], r[4]), flush=True)
    md, agg = topology_tables([r[5] for r in results])
    with open(os.path.join(outdir, 'aggregate.md'), 'w') as f:
        f.write(md)
    with open(os.path.join(outdir, 'aggregate.json'), 'w') as f:
        f.write(json.dumps(agg, indent=1, sort_keys=True))
    print('%d runs, wall %.1fs' % (len(results), time.time() - t0))


DEFAULT_OUT = os.path.join(HERE, 'results', 'final-spec')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', type=int, default=20261109)
    ap.add_argument('--days', type=int, default=90)
    ap.add_argument('--only', choices=list(VARIANTS), default=None)
    ap.add_argument('--extra-seeds', type=int, default=0, help='also run the base variant with N more seeds (seed+1..seed+N)')
    ap.add_argument('--out', default=DEFAULT_OUT)
    ap.add_argument('--jobs', type=int, default=1)
    ap.add_argument('--topology', action='store_true', help='run the deployment-topology comparison instead')
    ap.add_argument('--seeds', type=int, default=8, help='topology comparison: seeds seed..seed+N-1')
    ap.add_argument('--topology-days', type=int, default=40)
    args = ap.parse_args()
    if args.topology:
        return topology_main(args)
    os.makedirs(args.out, exist_ok=True)
    names = [args.only] if args.only else list(VARIANTS)
    runs = [(n, args.seed) for n in names] + [('base', args.seed + i) for i in range(1, args.extra_seeds + 1)]
    jobs = [(n, s, args.days, args.out) for n, s in runs]
    if args.jobs > 1:
        from multiprocessing import Pool
        with Pool(args.jobs) as pool:
            for line in pool.imap(one, jobs):
                print(line, flush=True)
    else:
        for j in jobs:
            print(one(j), flush=True)


if __name__ == '__main__':
    main()
