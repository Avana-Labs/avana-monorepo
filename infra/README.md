# Infrastructure

Where the off-chain services run in production and what each needs: hosts, PostgreSQL, RPC endpoints, keeper signing keys in a cloud KMS and the standby keeper on a second cloud. This folder holds configuration templates and this description only. Nothing here creates a cloud resource, and no file holds a secret, key, password or endpoint URL with credentials: every value is a placeholder (`<...>`) filled in by the operator in the cloud's own secret store.

| File | Contents |
|---|---|
| [`hosts.yaml`](hosts.yaml) | Every host per chain: role, cloud, region, size, ports, who may reach them |
| [`rpc/endpoints.yaml`](rpc/endpoints.yaml) | RPC endpoints per service and chain: roles, independence rules, required methods, request budgets |
| [`postgres/indexer.conf`](postgres/indexer.conf) | PostgreSQL settings of the indexer database |
| [`kms/aws-keeper-key.json`](kms/aws-keeper-key.json) | AWS KMS key spec and key policy of a primary keeper's signer |
| [`kms/gcp-standby-key.yaml`](kms/gcp-standby-key.yaml) | Google Cloud KMS key spec and IAM binding of the standby keeper's signer |
| [`env/convex.env.example`](env/convex.env.example) | Names of the Convex deployment's environment variables |

The services' own variable names are in `services/indexer/.env.example`, `services/keeper/.env.example` and `services/monitor/.env.example`; the container images and the single-host compose file for testnets and rehearsals are in `services/` (`services/README.md`, Containers).

## Topology

Ethereum and Base are served the same way, and nothing in the layout depends on how many Hubs or markets a chain has: the indexer, the keepers and the monitor read every Hub, Spoke and market from the chain's verified release manifest and the Lens.

| Service | Where | Per chain | Why there |
|---|---|---|---|
| Indexer (Ponder) | Primary cloud, private subnet | One instance (both chains in one process) and one managed PostgreSQL | The export serves only finalized blocks, so a restart costs latency, not correctness |
| Convex | Convex cloud | One production deployment | Runs the app's queries, the export pull and the crons |
| Keeper, primaries | Primary cloud, private subnet | 2 shards, each with its own signer, helper and funding Safe | Independent nonce streams; a shard takes over the other's accounts after 2 Ethereum or 6 Base blocks |
| Keeper, standby | Second cloud, other region | 1, scans every block, sends after 60 s | Survives an outage of the primary cloud, its KMS or its RPC providers |
| Monitor | Second cloud | 1 | Keeps paging when the primary cloud or the app stack is down |
| Web app | Its own hosting | — | Public; reads Convex and its own RPC proxy only |

### Networks and access

- The indexer's export (`/export/v1/*`) and keeper stream (`/keeper/v1/*`) listen on the private network only. Convex reaches the export through a TLS endpoint restricted to Convex's egress addresses, with the HMAC keys of `INDEXER_EXPORT_KEYS`; the keepers reach it over the private network or a peering link with their own key IDs.
- The keeper's kill switch (mutual TLS, port 9443) accepts only the on-call client certificates; metrics (9464) and the monitor (9470) are scraped from the monitoring network only.
- No service has an inbound port on the public internet except the web app and the TLS endpoint above. Outbound traffic goes to the RPC providers, the KMS, Convex, Merkl and the paging provider.
- Each host runs as its own service identity (an IAM role or a service account), not with long-lived access keys.

## PostgreSQL (indexer)

- Managed PostgreSQL 17 (Amazon RDS or Cloud SQL), one primary and one synchronous standby in another zone, encrypted storage, TLS required (`sslmode=verify-full` in `DATABASE_URL`).
- Size: 4 vCPU, 16 GB, 500 GB gp3 storage with autoscaling to start; the backfill from the manifest start blocks is the peak load.
- Backups: point-in-time recovery for 7 days and a daily snapshot kept 30 days. The indexer can also rebuild from the chain, so a lost database costs a reindex (hours), not data.
- Each release that changes the schema or a handler runs under a new `DATABASE_SCHEMA` and reindexes beside the old one; traffic moves after `/ready` (`services/indexer/EXPORT.md`, Reindex). Drop the old schema one release later.
- One database user for the indexer with rights on its schemas only; the password lives in the cloud's secret store and is injected as `DATABASE_URL` at start.
- Settings: [`postgres/indexer.conf`](postgres/indexer.conf).

## RPC endpoints

Every service reads each chain through at least two independent providers (different companies, not two keys of one provider). The keepers add a WebSocket endpoint and private submission (builder RPCs on Ethereum, the sequencer endpoint on Base). The standby keeper and the monitor use providers different from the primaries', so one provider outage cannot blind both sides. The monitor's providers must allow `eth_call` with state overrides. Budgets and roles per service: [`rpc/endpoints.yaml`](rpc/endpoints.yaml). Convex uses its own pair (`RPC_MAINNET`, `RPC_MAINNET_FALLBACK`, `RPC_BASE`, `RPC_BASE_FALLBACK`), never the indexer's, because it checks the export's block hashes against them.

## Keeper signing keys

- Each keeper instance and chain has its own non-exportable secp256k1 key in a cloud KMS or HSM. The key never leaves it: the keeper sends a digest and receives a signature, under its own service identity, and every signing request is logged by the cloud's audit log (CloudTrail, Cloud Audit Logs).
- Primaries: AWS KMS, key spec `ECC_SECG_P256K1`, usage `SIGN_VERIFY` ([`kms/aws-keeper-key.json`](kms/aws-keeper-key.json)). Only the instance's role may call `kms:Sign` and `kms:GetPublicKey`; administrators may manage the key but not sign with it. `KEEPER_KMS_KEY_ID_<CHAIN>` holds the key's ARN.
- Standby: Google Cloud KMS, algorithm `EC_SIGN_SECP256K1_SHA256`, protection level `HSM` ([`kms/gcp-standby-key.yaml`](kms/gcp-standby-key.yaml)), so the standby keeps signing when AWS or its KMS is down. The keeper's signer takes any `KmsKey` implementation (`services/keeper/src/chain/signer.ts`); today only the AWS one exists, and a Cloud KMS implementation is needed before the standby can sign.
- Each signer address holds gas only, topped up to 7 days of its median spend; inventory sits in the instance's funding Safe. Rotation and compromise handling: `services/README.md`, Keeper, Keys.
- Tests and local rehearsals never use these keys: they use an encrypted Foundry keystore created at run time.

## Standby keeper

- Second cloud provider and region, its own RPC providers, KMS, monitoring and on-call rota; registered on chain as a committed operator like the primaries.
- It holds each chain's debt assets in its own funding Safe before any market's `activateMarket` executes, and sends for any account still liquidatable 60 s after it became so (5 Ethereum blocks, 30 Base blocks).
- It reads the indexer's keeper stream over a peering link when the primary cloud is up and falls back to its own RPC backfill when it is not; its decisions never depend on the indexer.
- A monthly drill stops one primary shard for an hour and checks the standby's takeover in the monitor (`M-09`).

## Hosts

Sizes, regions and ports: [`hosts.yaml`](hosts.yaml). Every host runs the image built from the release tag (`services/Dockerfile`), with the verified manifests mounted read-only and state on an encrypted volume. Hosts are replaced, not patched in place: a release or an OS update rolls out a new image and host.
