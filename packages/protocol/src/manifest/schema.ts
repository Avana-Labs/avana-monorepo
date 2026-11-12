// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// JSON Schema (draft 2020-12) of the release manifest, the same shape as types.ts, and a validator for the subset of
// the schema language it uses (type, const, enum, pattern, minimum, properties, required, additionalProperties false,
// items, $ref to $defs, anyOf). `deployments/release-manifest.schema.json` is written from this object by the CLI
// (`npm run manifest -- schema`), so the file and the validator never disagree.

import type { ReleaseManifest } from "./types.ts";

type Schema = Readonly<Record<string, unknown>>;

const address: Schema = { type: "string", pattern: "^0x[0-9a-fA-F]{40}$" };
const hash: Schema = { type: "string", pattern: "^0x[0-9a-f]{64}$" };
const block: Schema = { type: "integer", minimum: 0 };
const decimal: Schema = { type: "string", pattern: "^[0-9]+$" };
const ref = (name: string): Schema => ({ $ref: `#/$defs/${name}` });
const obj = (properties: Record<string, Schema>, extra: Partial<Record<string, unknown>> = {}): Schema => ({
  type: "object",
  properties,
  required: Object.keys(properties),
  additionalProperties: false,
  ...extra,
});
const arr = (items: Schema): Schema => ({ type: "array", items });
const nullable = (s: Schema): Schema => ({ anyOf: [s, { type: "null" }] });
const feedList = arr(obj({ feed: address, heartbeatSeconds: { type: "integer", minimum: 1 } }));

const immutableProps = { address, codeHash: hash, startBlock: block, artifact: nullable({ type: "string" }) };
const upgradeableProps = {
  address,
  codeHash: hash,
  implementation: address,
  implementationCodeHash: hash,
  implementationArtifact: { type: "string" },
  logics: arr(obj({ name: { type: "string" }, address, codeHash: hash, artifact: { type: "string" } })),
  startBlock: block,
};

export const releaseManifestSchema: Schema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  $id: "https://github.com/Avana-Labs/avana-monorepo/deployments/release-manifest.schema.json",
  title: "Avana release manifest",
  $defs: {
    immutable: obj(immutableProps),
    upgradeable: obj(upgradeableProps),
    labelledUpgradeable: obj({ ...upgradeableProps, label: { type: "string" } }),
    hub: obj({ ...upgradeableProps, label: { type: "string" }, tier: { type: "integer", minimum: 1, maximum: 3 } }),
    market: obj({
      marketId: decimal,
      integrationId: { type: "integer", minimum: 1 },
      spoke: address,
      vaultToken: ref("immutable"),
      lpOracle: ref("upgradeable"),
      reserveId: decimal,
      pool: address,
      tokens: arr(address),
      feeds: feedList,
      routes: arr(ref("immutable")),
    }),
    debtReserve: obj({
      spoke: address,
      debtReserveId: decimal,
      asset: address,
      decimals: { type: "integer", minimum: 0, maximum: 36 },
      isGho: { type: "boolean" },
      debtOracle: nullable(ref("upgradeable")),
      feeds: feedList,
    }),
  },
  ...obj({
    schemaVersion: { const: 1 },
    chainId: { type: "integer", minimum: 1 },
    network: { type: "string", pattern: "^(anvil|tenderly-[a-z0-9-]+|sepolia|base-sepolia|ethereum|base)$" },
    release: { type: "string", pattern: "^v[0-9]+\\.[0-9]+\\.[0-9]+(-[a-z0-9.]+)?$" },
    commit: { type: "string", pattern: "^[0-9a-f]{7,40}$" },
    abiHash: hash,
    deployer: address,
    create3Factory: address,
    feeRecipient: address,
    sequencerFeed: nullable(address),
    avana: obj({
      aaveAdapter: ref("upgradeable"),
      lpVaultSwap: ref("upgradeable"),
      marketRegistry: ref("upgradeable"),
      parameterStore: ref("upgradeable"),
      riskModule: ref("upgradeable"),
      timelock: ref("immutable"),
      proxyManager: ref("immutable"),
      collateralization: ref("immutable"),
      vaultTokenFactory: ref("immutable"),
      payoutEscrow: ref("immutable"),
      lock: ref("immutable"),
      lens: ref("immutable"),
      lensModules: arr(ref("immutable")),
      lensAaveSizing: ref("immutable"),
      flashSource: ref("immutable"),
      flashLiquidator: ref("immutable"),
      operatorHelpers: arr(obj({ ...immutableProps, signer: address, fundingSafe: address })),
      lpVaults: arr(obj({ ...immutableProps, integrationId: { type: "integer", minimum: 1 }, kind: { enum: ["uniswap-v3", "slipstream"] } })),
      coverageSpokes: arr(obj({ ...immutableProps, asset: address, hub: address })),
      debtOracleImplementation: ref("immutable"),
      clOraclePricing: nullable(ref("immutable")),
      proxyCreationCodeHash: hash,
    }),
    markets: arr(ref("market")),
    debtReserves: arr(ref("debtReserve")),
    aave: obj({
      hubs: arr(ref("hub")),
      borrowSpokes: arr(ref("labelledUpgradeable")),
      lendSpokes: arr(ref("labelledUpgradeable")),
      v3Pool: ref("upgradeable"),
      accessManager: address,
    }),
    roles: obj({
      timelock: obj({
        proposers: arr(address),
        executors: arr(address),
        cancellers: arr(address),
        daoCancellers: arr(address),
        normalDelay: { type: "integer", minimum: 345600, maximum: 432000 },
        publicExecution: { type: "boolean" },
      }),
      governanceSafe: address,
      emergencyGuardian: address,
      aaveProtocolGuardian: address,
      aaveGovernanceExecutor: address,
      jointConfigSafe: address,
      marketRegistryGuardians: arr(address),
      parameterStorePauseGuardians: arr(address),
      riskStewards: arr(address),
      keepers: arr(address),
    }),
    external: arr(
      obj({
        name: { type: "string" },
        group: { enum: ["aave-v4", "aave-v3", "uniswap-v3", "slipstream", "token", "feed", "safe"] },
        address,
        codeHash: hash,
        implementation: nullable(address),
        standIn: { type: "boolean" },
      }),
    ),
  }),
};

/** One validation failure: the JSON path and what is wrong there. */
export interface SchemaError {
  readonly path: string;
  readonly message: string;
}

/** Validates `value` against `schema` (the subset above); returns every failure, empty when valid. */
export function validate(value: unknown, schema: Schema = releaseManifestSchema, root: Schema = schema, path = "$"): SchemaError[] {
  const errors: SchemaError[] = [];
  const fail = (message: string) => errors.push({ path, message });
  if (typeof schema.$ref === "string") {
    const name = schema.$ref.replace("#/$defs/", "");
    const target = (root.$defs as Record<string, Schema> | undefined)?.[name];
    if (!target) return [{ path, message: `unknown $ref ${schema.$ref}` }];
    return validate(value, target, root, path);
  }
  if (Array.isArray(schema.anyOf)) {
    const ok = (schema.anyOf as Schema[]).some((s) => validate(value, s, root, path).length === 0);
    return ok ? [] : [{ path, message: "matches no allowed form" }];
  }
  if ("const" in schema && value !== schema.const) fail(`must be ${JSON.stringify(schema.const)}`);
  if (Array.isArray(schema.enum) && !schema.enum.includes(value)) fail(`must be one of ${JSON.stringify(schema.enum)}`);
  switch (schema.type) {
    case "string":
      if (typeof value !== "string") return [{ path, message: "must be a string" }];
      if (typeof schema.pattern === "string" && !new RegExp(schema.pattern).test(value)) fail(`must match ${schema.pattern}`);
      break;
    case "integer":
    case "number":
      if (typeof value !== "number" || (schema.type === "integer" && !Number.isInteger(value))) {
        return [{ path, message: `must be an ${schema.type}` }];
      }
      if (typeof schema.minimum === "number" && value < schema.minimum) fail(`must be ≥ ${schema.minimum}`);
      if (typeof schema.maximum === "number" && value > schema.maximum) fail(`must be ≤ ${schema.maximum}`);
      break;
    case "boolean":
      if (typeof value !== "boolean") fail("must be a boolean");
      break;
    case "null":
      if (value !== null) fail("must be null");
      break;
    case "array":
      if (!Array.isArray(value)) return [{ path, message: "must be an array" }];
      value.forEach((v, i) => errors.push(...validate(v, schema.items as Schema, root, `${path}[${i}]`)));
      break;
    case "object": {
      if (typeof value !== "object" || value === null || Array.isArray(value)) return [{ path, message: "must be an object" }];
      const props = (schema.properties ?? {}) as Record<string, Schema>;
      const rec = value as Record<string, unknown>;
      for (const key of (schema.required ?? []) as string[]) if (!(key in rec)) errors.push({ path: `${path}.${key}`, message: "is required" });
      for (const [key, v] of Object.entries(rec)) {
        if (key === "$schema") continue;
        const sub = props[key];
        if (sub) errors.push(...validate(v, sub, root, `${path}.${key}`));
        else if (schema.additionalProperties === false) errors.push({ path: `${path}.${key}`, message: "is not allowed" });
      }
      break;
    }
  }
  return errors;
}

/** Parses and validates a manifest; throws with every failure listed. */
export function parseManifest(json: string, source = "manifest"): ReleaseManifest {
  const value: unknown = JSON.parse(json);
  const errors = validate(value);
  if (errors.length > 0) {
    throw new Error(`${source} does not match the release manifest schema:\n${errors.map((e) => `  ${e.path}: ${e.message}`).join("\n")}`);
  }
  return value as ReleaseManifest;
}
