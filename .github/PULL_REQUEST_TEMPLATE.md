## What and why

<!-- One paragraph: what changes and the reason. Name the spec IDs (REQ-…, INV-…, Q-…) the change implements or touches. -->

## Checklist

- [ ] Spec first: where code and spec disagreed, the spec page and its Z3/SymPy/Hypothesis model changed in this PR, and `trace.py` reports 0 errors with `traceability.md` regenerated.
- [ ] Every new or changed function carries `/// @custom:spec` IDs; every new test carries a `TEST-NNN verifies:` tag.
- [ ] `forge fmt --check`, `forge build -D warnings`, `forge test` and `script/security-fast.sh` pass locally.
- [ ] Gas: `make gas` was run and the changed `contracts/snapshots/*.json` are committed, or no gas suite changed.
- [ ] Contract sizes: `script/check-sizes.sh` passes; any margin change in `security/size-margins.json` gives its reason.
- [ ] Upgradeable contracts: the storage-layout diff (`security/storage-layout/`) was reviewed.
- [ ] Each change to a `contracts/security/*-triage.json` entry gives its reason.
- [ ] `deployments/verified/` and `packages/protocol/sol/` are unchanged, or this is a deployment PR and the address library was regenerated.
- [ ] `CHANGELOG.md` has an entry under "Unreleased".
