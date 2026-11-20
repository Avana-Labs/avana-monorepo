## What and why

<!-- One paragraph: what changes and the reason. -->

## Checklist

- [ ] Design changes are recorded in the contract's `DESIGN.md`.
- [ ] `script/check-core-size.sh` passes (each core contract ≤ 800 lines, core ≤ 4,000).
- [ ] `forge fmt --check`, `forge build -D warnings`, `forge test` and `script/security-fast.sh` pass locally.
- [ ] Gas: `make gas` was run and the changed `contracts/snapshots/*.json` are committed, or no gas suite changed.
- [ ] Contract sizes: `script/check-sizes.sh` passes; any margin change in `security/size-margins.json` gives its reason.
- [ ] Upgradeable contracts: the storage-layout diff (`security/storage-layout/`) was reviewed.
- [ ] Each change to a `contracts/security/*-triage.json` entry gives its reason.
- [ ] `deployments/verified/` and `packages/protocol/sol/` are unchanged, or this is a deployment PR and the address library was regenerated.
- [ ] `CHANGELOG.md` has an entry under "Unreleased".
