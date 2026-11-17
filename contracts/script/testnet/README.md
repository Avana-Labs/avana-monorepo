# Test networks

These scripts deploy Avana on Sepolia and Base Sepolia exactly as the local stack ([script/local](../local/README.md)) deploys its two chains. Each chain gets the same base config, world, Hub files and step sequence, and its market values come from the same source, `script/local/test-values.json`.

- `testnet.ts` runs the whole deploy of one test network. It covers every step, both Hub releases, the timelock operations and the explorer verification. A step that passed is never run again. It also publishes the feeds' rounds.
- `keys.ts` reads the signers and role addresses from a private config file outside the repository (`test-network-config.example` shows its keys). Every signer is an encrypted keystore, and no key is written anywhere.
- `rehearse.ts` runs the same deploy on local nodes with the networks' chain IDs, signed only by throwaway keystores.
- `testnet.test.ts` checks that a test network's config matches the local stack's in everything but its roles, release and timelock delays.
