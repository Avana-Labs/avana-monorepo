// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// JSON Schema (draft 2020-12) of the release manifest, the same shape as types.ts, and a validator for the subset of
// the schema language it uses (type, const, enum, pattern, minimum, properties, required, additionalProperties false,
// items, minItems, maxItems, $ref to $defs, anyOf). `deployments/release-manifest.schema.json` is written from this object by the CLI
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
const upgradeableProps = { address, codeHash: hash, implementation: address, implementationCodeHash: hash, startBlock: block };
const tick: Schema = { type: "integer", minimum: -887272, maximum: 887272 };
const lossLayer = obj({ ...immutableProps, hub: address, hubLabel: { type: "string" }, asset: address, symbol: { type: "string" }, minimum: decimal });

/** The manifest's top-level properties; `uniswapV4` is the only optional one (a chain without a v4 integration). */
const manifestProps: Record<string, Schema> = {
  schemaVersion: { const: 2 },
  chainId: { type: "integer", minimum: 1 },
  network: { type: "string", pattern: "^(anvil|sepolia|base-sepolia|ethereum|base)$" },
  release: { type: "string", pattern: "^v[0-9]+\\.[0-9]+\\.[0-9]+(-[a-z0-9.]+)?$" },
  commit: { type: "string", pattern: "^[0-9a-f]{7,40}$" },
  abiHash: hash,
  deployer: address,
  create3Factory: address,
  feeRecipient: address,
  sequencerFeed: nullable(address),
  avana: obj({
    accessManager: ref("immutable"),
    integrations: arr(
      obj({
        integrationId: { type: "integer", minimum: 1 },
        kind: { enum: ["uniswap-v3", "slipstream", "uniswap-v4"] },
        lpVault: ref("immutable"),
        riskModule: ref("immutable"),
        liquidationModule: ref("immutable"),
        aaveAdapter: ref("immutable"),
        flashloanRepay: ref("immutable"),
      }),
    ),
    flashLiquidators: arr(obj({ ...immutableProps, integrationId: { type: "integer", minimum: 1 }, operator: address })),
  }),
  markets: arr(ref("market")),
  debtReserves: arr(ref("debtReserve")),
  coverage: obj({ firstLossReserves: arr(lossLayer), daoDeficitOffsets: arr(lossLayer) }),
  aave: obj({
    hubs: arr(obj({ ...upgradeableProps, label: { type: "string" }, tier: { type: "integer", minimum: 1, maximum: 3 } })),
    borrowSpokes: arr(ref("labelledUpgradeable")),
    lendSpokes: arr(ref("labelledUpgradeable")),
    v3Pool: ref("upgradeable"),
    accessManager: address,
  }),
  roles: obj({
    aaveGovernanceExecutor: address,
    governanceSafe: address,
    emergencyGuardian: address,
    aaveProtocolGuardian: address,
    jointConfigSafe: address,
    keepers: arr(address),
    keeperTopUpWallet: nullable(address),
  }),
  external: arr(
    obj({
      name: { type: "string" },
      group: { enum: ["aave-v4", "aave-v3", "uniswap-v3", "uniswap-v4", "slipstream", "token", "feed", "safe"] },
      address,
      codeHash: hash,
      implementation: nullable(address),
      standIn: { type: "boolean" },
    }),
  ),
  uniswapV4: obj({ poolManager: ref("immutable") }),
};

export const releaseManifestSchema: Schema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  $id: "https://github.com/Avana-Labs/avana-monorepo/deployments/release-manifest.schema.json",
  title: "Avana release manifest",
  $defs: {
    immutable: obj(immutableProps),
    upgradeable: obj(upgradeableProps),
    labelledUpgradeable: obj({ ...upgradeableProps, label: { type: "string" } }),
    market: obj({
      marketId: decimal,
      name: { type: "string" },
      integrationId: { type: "integer", minimum: 1 },
      kind: { enum: ["full-range", "custom-range"] },
      pool: hash,
      spoke: address,
      hub: address,
      vaultToken: ref("immutable"),
      lpOracle: ref("immutable"),
      reserveId: decimal,
      tokens: { ...arr(address), minItems: 2, maxItems: 2 },
      bandLower: tick,
      bandUpper: tick,
      ltvBps: { type: "integer", minimum: 1, maximum: 10000 },
      unitDecimals: { type: "integer", minimum: 0, maximum: 36 },
      feeds: feedList,
    }),
    debtReserve: obj({
      spoke: address,
      debtReserveId: decimal,
      asset: address,
      decimals: { type: "integer", minimum: 0, maximum: 36 },
      isGho: { type: "boolean" },
      firstLossReserve: address,
      feeds: feedList,
    }),
  },
  ...obj(manifestProps, { required: Object.keys(manifestProps).filter((k) => k !== "uniswapV4") }),
};

/** One validation failure: the JSON path and what is wrong there. */
export interface SchemaError {
  readonly path: string;
  readonly message: string;
}

/** Validates `value` against `schema` (the subset above); returns every failure, empty when valid. */
export function validate(value: unknown, schema: Schema = releaseManifestSchema, root: Schema = schema, path = "$"): SchemaError[] {
  const errors = validateShape(value, schema, root, path);
  if (schema === releaseManifestSchema && path === "$") errors.push(...crossChecks(value as ReleaseManifest));
  return errors;
}

/** What the shape cannot say: each market names a listed integration, a pool has at most one market of each kind,
 * both markets of a pool share the LTV, and a Custom band lies inside the full range. */
function crossChecks(m: ReleaseManifest): SchemaError[] {
  const errors: SchemaError[] = [];
  if (!Array.isArray(m?.markets) || !Array.isArray(m?.avana?.integrations)) return errors;
  const ids = new Set(m.avana.integrations.map((i) => i.integrationId));
  const byPool = new Map<string, { kind: string; ltvBps: number; i: number }[]>();
  m.markets.forEach((mk, i) => {
    if (!ids.has(mk.integrationId)) errors.push({ path: `$.markets[${i}].integrationId`, message: `names no integration in avana.integrations` });
    if (mk.bandLower >= mk.bandUpper) errors.push({ path: `$.markets[${i}].bandUpper`, message: "must be above bandLower" });
    const key = `${mk.integrationId}:${String(mk.pool).toLowerCase()}`;
    const list = byPool.get(key) ?? [];
    for (const o of list) {
      if (o.kind === mk.kind) errors.push({ path: `$.markets[${i}].kind`, message: `pool ${mk.pool} already has a ${mk.kind} market (markets[${o.i}])` });
      if (o.ltvBps !== mk.ltvBps) errors.push({ path: `$.markets[${i}].ltvBps`, message: `differs from markets[${o.i}] of the same pool` });
    }
    list.push({ kind: mk.kind, ltvBps: mk.ltvBps, i });
    byPool.set(key, list);
  });
  return errors;
}

function validateShape(value: unknown, schema: Schema, root: Schema, path: string): SchemaError[] {
  const errors: SchemaError[] = [];
  const fail = (message: string) => errors.push({ path, message });
  if (typeof schema.$ref === "string") {
    const name = schema.$ref.replace("#/$defs/", "");
    const target = (root.$defs as Record<string, Schema> | undefined)?.[name];
    if (!target) return [{ path, message: `unknown $ref ${schema.$ref}` }];
    return validateShape(value, target, root, path);
  }
  if (Array.isArray(schema.anyOf)) {
    const ok = (schema.anyOf as Schema[]).some((s) => validateShape(value, s, root, path).length === 0);
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
      if (typeof schema.minItems === "number" && value.length < schema.minItems) fail(`must have at least ${schema.minItems} items`);
      if (typeof schema.maxItems === "number" && value.length > schema.maxItems) fail(`must have at most ${schema.maxItems} items`);
      value.forEach((v, i) => errors.push(...validateShape(v, schema.items as Schema, root, `${path}[${i}]`)));
      break;
    case "object": {
      if (typeof value !== "object" || value === null || Array.isArray(value)) return [{ path, message: "must be an object" }];
      const props = (schema.properties ?? {}) as Record<string, Schema>;
      const rec = value as Record<string, unknown>;
      for (const key of (schema.required ?? []) as string[]) if (!(key in rec)) errors.push({ path: `${path}.${key}`, message: "is required" });
      for (const [key, v] of Object.entries(rec)) {
        if (key === "$schema") continue;
        const sub = props[key];
        if (sub) errors.push(...validateShape(v, sub, root, `${path}.${key}`));
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
