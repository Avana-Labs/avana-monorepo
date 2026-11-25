# test/invariant/medusa

Harnesses that only Medusa runs. Every harness in [`../echidna/`](../echidna/) already runs under both Echidna and Medusa; a harness belongs here when it needs a Medusa feature Echidna lacks, such as Medusa cheatcodes in a property or a per-harness `predeployedContracts` layout.

The conventions are those of `../echidna/README.md`: one contract named `<Subject>Properties` per file, `property_` functions for properties, every other state-changing function an assertion entry point. `script/security-slow.sh medusa` runs every `*Properties` contract in both folders with `medusa.json`, and `script/security-slow.sh hevm` proves the assertion entry points of both folders.

Medusa's settings in `medusa.json`:

- **Panics that fail a test.** Assertion failures (`0x01`), division by zero, out-of-range enum conversion, invalid storage access, pop on an empty array, out-of-bounds array access, oversized memory allocation and calls to an uninitialized function pointer. Arithmetic overflow (`0x11`) does not: solc 0.8 reverts on it by design, and each harness asserts its arithmetic bounds explicitly.
- **Optimization tests** are off; no harness maximizes a value.
- **Compilation** reads the build of `script/security-slow.sh build` (`--foundry-ignore-compile`), so Medusa never cleans or rebuilds `out/`.
