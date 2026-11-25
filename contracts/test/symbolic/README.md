# test/symbolic

hevm symbolic tests: Foundry test contracts whose `prove_<behavior>` functions hevm proves for every input (`hevm test`). `script/security-slow.sh hevm` builds the workspace with `forge build --ast` into an isolated root under `out-security/hevm/root/` and runs `hevm test` on every `prove_` function; with none present the step reports that it skipped `hevm test`.

The same step also runs `hevm symbolic` without any test file:

- on each assertion entry point of every property harness in `test/invariant/echidna/` and `test/invariant/medusa/`, which must reach QED; a partial exploration fails the run;
- on the runtime code of every contract and library compiled from `src/`, which fails on any reachable assertion violation (Panic `0x01`).

`FixedArrayEntries.sol` holds the fixed-length wrappers of the `src/` entry points that take a dynamic array (`AaveAdapter.multicall`, `AaveAdapter.collectFees`, `FlashloanRepay.executeOperation`): hevm 0.58 has no symbolic ABI encoding for `bytes[]` or `address[]`, so the step runs these wrappers, which build the array and delegatecall the analysed code, instead of the raw entry points.

Halmos `check_` tests belong in `test/halmos/`; a property belongs here when it needs hevm's cheatcodes or its solver back ends.

Kontrol is not part of this folder: it needs the K framework, installed through `kup` and Nix, and hevm and Halmos already prove Foundry tests symbolically.
