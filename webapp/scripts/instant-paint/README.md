# Instant Paint baselines

Measured warm-route timings for the Instant Paint rollout (C00+).

## Record a baseline

Prefer a **production** server (matches deploy; no Turbopack compile noise):

```bash
npm run build
npm run start
# other terminal:
npm run perf:instant-paint-baseline
```

Against the current server (dev or start):

```bash
BASE_URL=http://localhost:3000 SERVER_MODE=dev npm run perf:instant-paint-baseline
```

Output (gitignored): `.artifacts/instant-paint/baseline.json`

## Compare after a change

The script auto-compares to the existing `baseline.json` when present (Δttfb% / Δbytes%).

```bash
# After C01…C0n:
npm run perf:instant-paint-baseline
```

Or pin an older file:

```bash
COMPARE_BASELINE=.artifacts/instant-paint/baseline-c00.json npm run perf:instant-paint-baseline
```

## Gate rule

A commit “passes” Instant Paint only if:

1. Relevant unit/parity/e2e still green
2. Touched routes’ warm `ttfbMs` improve **or** stay within ~10% with a documented reason
3. No new blank shells (`looksBlankShell` stays false)

Do not stack the next Instant Paint commit on hypothesis alone.
