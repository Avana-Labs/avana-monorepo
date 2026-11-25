// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One network's section of each address book page, in the pages' format (docs/address-book/README.md): a `## ` group that
// opens with `- network:`, `### ` sections, GFM tables and `> ` notes. Sections, tables and columns follow the site's
// pages one to one; the rows come from the model, so a network shows only what its deployment has.

import { KIND_ORDER, type Kind, type Model, VENUE } from "./model.ts";

export type Page = "addresses" | "parameters" | "access-controls";
export const PAGES: readonly Page[] = ["addresses", "parameters", "access-controls"];

// ─── Formatting ───

/** A whole number with thousands separators; a value the model could not read renders as MISSING (a reported problem). */
function int(n: number | string): string {
  try {
    return BigInt(n).toLocaleString("en-US");
  } catch {
    return "MISSING";
  }
}
/** Basis points as a percentage: 8000 → 80%, 650 → 6.5%, 8889 → 88.89%, 1 → 0.01%. */
export const pct = (bps: number) => `${Number((bps / 100).toFixed(2))}%`;
/** Seconds, with days or hours when whole: 432000 → "432,000 s (5 days)", 60 → "60 s". */
export function seconds(s: number): string {
  const unit = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;
  if (s >= 86_400 && s % 86_400 === 0) return `${int(s)} s (${unit(s / 86_400, "day")})`;
  if (s >= 3_600 && s % 3_600 === 0) return `${int(s)} s (${unit(s / 3_600, "hour")})`;
  return `${int(s)} s`;
}
/** Raw token units in whole tokens: ("1000000000000", 6) → "1,000,000", ("1500000000000000000", 18) → "1.5". */
export function units(raw: string, decimals: number | undefined): string {
  if (decimals === undefined || !/^[0-9]+$/.test(raw)) return "MISSING";
  const v = BigInt(raw);
  const one = 10n ** BigInt(decimals);
  const frac = (v % one).toString().padStart(decimals, "0").replace(/0+$/, "");
  return `${(v / one).toLocaleString("en-US")}${frac ? `.${frac}` : ""}`;
}
const list = (xs: readonly string[]) => (xs.length <= 1 ? (xs[0] ?? "") : `${xs.slice(0, -1).join(", ")} and ${xs.at(-1)}`);
const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;
/** A table cell's text with backslashes escaped first, then pipes, so a literal `\|` cannot end the cell. */
export const cell = (s: string) => s.replace(/\\/g, "\\\\").replace(/\|/g, "\\|");

function table(headers: readonly string[], rows: readonly (readonly string[])[]): string {
  const line = (cells: readonly string[]) => `| ${cells.map(cell).join(" | ")} |`;
  return [line(headers), `| ${headers.map(() => "---").join(" | ")} |`, ...rows.map(line)].join("\n");
}

const link = (m: Model, page: Page, anchor?: string) => `/developers/reference/${page}?network=${m.net.id}${anchor ? `#${anchor}` : ""}`;
const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
const ZERO = /^0x0{40}$/;

function header(m: Model): string[] {
  const meta = [`- network: ${m.net.id}`, `- chainId: ${m.net.chainId}`];
  if (m.net.explorer) meta.push(`- explorer: ${m.net.explorer}`);
  return [`## ${m.net.title}`, ...meta, ""];
}

/** Where the section's values come from, and what a local chain is. */
function provenance(m: Model): string {
  const from = `Generated from release \`${m.manifest.release}\` (commit \`${m.manifest.commit.slice(0, 8)}\`) and its deploy output.`;
  if (m.net.kind !== "local") return from;
  return `A local development chain (chain ID ${m.net.chainId}) that the local stack deploys from scratch; its addresses change with each new deployment. ${from}`;
}

/** Integrations in the pages' AMM order, each in the manifest's order within its AMM. */
const byKind = (m: Model) => KIND_ORDER.flatMap((k) => m.integrations.filter((x) => x.kind === k));
const venueOf = (m: Model, integrationId: number) => VENUE[m.integrations.find((x) => x.id === integrationId)?.kind ?? "uniswap-v3"];
const standIn = (s: boolean) => (s ? " A test stand-in." : "");

// ─── Contract Addresses ───

/** Descriptions of the third-party contracts the deployment names, by manifest group and name. */
function externalText(group: string, name: string): string | undefined {
  const gen = /^(.+) generation (\d+)$/.exec(name);
  const fixed: Record<string, Record<string, string>> = {
    "aave-v4": {
      hubConfigurator: "Aave DAO payloads configure the Hubs through it.",
      spokeConfigurator: "Aave DAO payloads configure the Spokes through it; the Aave Protocol Guardian freezes and pauses reserves through it, one way.",
      treasurySpoke: "Fee receiver of every Hub asset the deployment AIP lists.",
      liquidationLogic: "Aave V4's external LiquidationLogic library, called by the Spokes.",
    },
    "aave-v3": {
      PoolAddressesProvider: "Address registry of the Aave V3 Pool.",
      PoolConfigurator: "Configures the Aave V3 Pool's reserves.",
      ACLManager: "Grants `FLASH_BORROWER` to the FlashLiquidators (`AvanaFlashBorrowers` AIP).",
      AaveOracle: "Price oracle of the Aave V3 Pool.",
    },
    "uniswap-v3": {
      UniswapV3Factory: "The Uniswap v3 LPVault accepts positions only of pools this factory created.",
      NonfungiblePositionManager: "Issues the Uniswap v3 position NFTs users pledge; the Uniswap v3 LPVault holds them.",
    },
    "uniswap-v4": {
      PoolManager: "Holds every Uniswap v4 pool; the Uniswap v4 LPVault reads positions through it.",
      PositionManager: "Issues the Uniswap v4 position NFTs users pledge; the Uniswap v4 LPVault changes liquidity through it.",
      Permit2: "Token approvals of the Uniswap v4 PositionManager.",
      StateView: "Read-only views of the Uniswap v4 PoolManager.",
    },
    slipstream: {
      "Aerodrome Voter": "Part of the Aerodrome deployment; the Slipstream LPVault never calls it.",
      "Aerodrome FactoryRegistry": "Part of the Aerodrome deployment; the Slipstream LPVault never calls it.",
      AERO: "Aerodrome's reward token; the Slipstream LPVault never handles it.",
    },
  };
  if (fixed[group]?.[name]) return fixed[group][name];
  if (group === "aave-v4") {
    const o = /^AaveOracle (.+)$/.exec(name);
    if (o) return `AaveOracle of Spoke ${o[1]}: the price source of each of that Spoke's reserves.`;
    const ir = /^Interest-rate strategy (.+)$/.exec(name);
    if (ir) return `Interest-rate strategy of Hub ${ir[1]}: the rate curve of each of its assets.`;
  }
  if (group === "slipstream" && gen) {
    const g = gen[2];
    if (gen[1] === "CLFactory") return `Pool factory of generation ${g}; the Slipstream LPVault accepts positions only of pools a listed generation's factory created.`;
    if (gen[1] === "NonfungiblePositionManager") return `Issues the Slipstream position NFTs of generation ${g} that users pledge.`;
    if (gen[1] === "CLGaugeFactory") return `Gauge factory of generation ${g}; the Slipstream LPVault never calls a gauge.`;
  }
  return undefined;
}

/** An external's row name: the manifest's name, after its venue when the name does not carry it. */
function displayName(group: string, name: string): string {
  const venue: Record<string, string> = { "aave-v4": "Aave V4", "aave-v3": "Aave V3", "uniswap-v3": "Uniswap v3", "uniswap-v4": "Uniswap v4", slipstream: "Aerodrome Slipstream" };
  const v = venue[group];
  return !v || /^(Aave|Aerodrome|AERO)/.test(name) ? name : `${v} ${name}`;
}

/** The manifest groups each integration kind depends on. */
const GROUP_OF: Record<Kind, string> = { "uniswap-v3": "uniswap-v3", "uniswap-v4": "uniswap-v4", slipstream: "slipstream" };

const integrationText: Record<string, (v: string) => string> = {
  lpVault: (v) =>
    `Holds every ${v} position NFT pledged through this integration, one record per position with its floor credit, and changes or unwinds its liquidity on withdrawal and liquidation. Not upgradeable; only this integration's RiskModule, AaveAdapter and LiquidationModule can call its restricted functions.`,
  riskModule: () =>
    "Avana's rules for this integration: pool listings as a Full range and a Custom range market, the Aave check at activation, eligibility and floor credit, First-Loss coverage of draw caps, the fee and the keeper registry. Not upgradeable; the AccessManager restricts every setter.",
  liquidationModule: () =>
    "Partial liquidation in kind, open to anyone: Aave's `liquidationCall`, then an unwind of only the liquidity worth the seized vault tokens, paid out in both pool tokens with Avana's fee share split off. Not upgradeable, no admin.",
  aaveAdapter: () =>
    "The only entry point for users: pledge, add liquidity, withdraw, borrow, repay and collect fees, through each wallet's AccountProxy in the market, whose Aave position manager it is. Not upgradeable, no admin.",
  flashloanRepay: () =>
    "Repays a wallet's debt with part of its pledged position in one call, borrowing the debt asset from the Aave V3 Pool; the wallet opens the call through `AaveAdapter.allowWithdraw`. Not upgradeable, no admin.",
};
const INTEGRATION_ROWS = [
  ["lpVault", "LPVault"],
  ["riskModule", "RiskModule"],
  ["liquidationModule", "LiquidationModule"],
  ["aaveAdapter", "AaveAdapter"],
  ["flashloanRepay", "FlashloanRepay"],
] as const;

export function renderAddresses(m: Model, problems: string[]): string {
  const out: string[] = header(m);
  const pools = new Set(m.markets.map((x) => `${x.integrationId}:${x.pool.toLowerCase()}`)).size;
  out.push(
    `${plural(m.hubs.length, "Hub")} with ${plural(m.lendSpokes.length, "Lend Spoke")} and ${plural(m.cdpSpokes.length, "CDP Spoke")}, and ${plural(m.markets.length, "market")} on ${plural(pools, "pool")} (a Full range and a Custom range market per pool). Market bands and listing values are on [Market Parameters](${link(m, "parameters")}).`,
    "",
    provenance(m),
    "",
    "### Hubs",
    "",
    table(
      ["Name", "Description", "Address"],
      m.hubs.map((h) => [
        h.label,
        `Aave V4 Hub, tier ${h.tier}. It holds the lent assets and the vault-token collateral of its Spokes. Upgradeable by the Aave DAO, which owns its proxy.`,
        h.address,
      ]),
    ),
    "",
    "### CDP Spokes",
    "",
    table(
      ["Name", "Hub", "Description", "Address"],
      m.cdpSpokes.map((s) => {
        const borrow = s.borrowable.length ? `for borrowing ${list(s.borrowable)}` : "with no debt reserve registered yet";
        const text = s.kind
          ? `Aave V4 CDP Spoke where ${VENUE[s.kind]} positions are collateral ${borrow}. Users act on it through the ${VENUE[s.kind]} AaveAdapter, its position manager.`
          : `Aave V4 CDP Spoke with no Avana market yet, ${borrow}.`;
        return [s.label, s.hub ?? "—", `${text} Upgradeable by the Aave DAO, which owns its proxy.`, s.address];
      }),
    ),
    "",
    "### Lend Spokes",
    "",
    table(
      ["Name", "Description", "Address"],
      m.lendSpokes.map((s) => [
        s.label,
        "Supply-only Aave V4 Spoke where lenders supply its Hub's debt assets for Avana borrowers to draw through the CDP Spokes; it draws nothing itself. Upgradeable by the Aave DAO, which owns its proxy.",
        s.address,
      ]),
    ),
    "",
    "> Each Spoke has its own AaveOracle; read its address from the Spoke's `ORACLE()`. A vault-token reserve's price source is its market's LPOracle.",
    "",
  );

  const core: string[][] = [
    [
      "AccessManager",
      "OpenZeppelin AccessManager, the authority of every Avana core contract on this chain: it maps each restricted function to a role and holds each holder's execution delay. Its admin is the Aave governance executor. Not upgradeable.",
      m.manifest.avana.accessManager.address,
    ],
  ];
  for (const x of byKind(m)) {
    const v = VENUE[x.kind];
    for (const [key, name] of INTEGRATION_ROWS) {
      const address = x[key];
      if (key === "flashloanRepay" && ZERO.test(address)) {
        core.push([`${v} ${name}`, "Not deployed on this network: the chain has no Aave V3 Pool.", "—"]);
        continue;
      }
      core.push([`${v} ${name}`, integrationText[key](v), address]);
    }
  }
  for (const l of m.lossLayers) {
    core.push(
      [
        `First-Loss Reserve, ${l.symbol} (${l.hub} Hub)`,
        `Avana's first-loss capital for ${l.symbol} on the ${l.hub} Hub, held as Hub added shares: it covers deficits the Hub records on its allowed CDP Spokes before any other layer. Funded by Avana Labs. Not upgradeable; governed through the Aave AccessManager.`,
        l.firstLossReserve,
      ],
      [
        `DAO deficit offset, ${l.symbol} (${l.hub} Hub)`,
        `Second loss layer for ${l.symbol} on the ${l.hub} Hub, funded by the Aave DAO treasury: it pays only the part of a deficit beyond what the ${l.symbol} First-Loss Reserve holds while that reserve is active. The same FirstLossReserve contract; not upgradeable; governed through the Aave AccessManager.`,
        l.daoDeficitOffset,
      ],
    );
  }
  core.push(["AvanaCreate3Factory", "Deploys Avana contracts at addresses that depend only on the deployer and a salt, so every address is known before deployment. Immutable.", m.manifest.create3Factory]);
  out.push(
    "### Avana core",
    "",
    "The contracts Avana deploys on this chain: the AccessManager, one core stack per AMM integration, and both loss layers of each (Hub, debt asset). None is upgradeable; a new version is a new deployment.",
    "",
    table(["Name", "Description", "Address"], core),
    "",
    "> Each wallet has one AccountProxy per market, deployed by the market's AaveAdapter at an address fixed by the wallet and the market (`predictAccount`). It holds no tokens and has no functions of its own.",
    "",
    "### Markets",
    "",
    "Each market has its own vault token, the ERC-20 a pledge mints and the CDP Spoke holds as collateral, and its own LPOracle, which prices the vault token from Aave V4's prices of the two pool tokens. Both are immutable.",
    "",
    table(
      ["Spoke", "Market ID", "Market", "Range", "Pair", "Vault token", "LPOracle"],
      byKind(m).flatMap((x) => m.markets.filter((mk) => mk.integrationId === x.id).map((mk) => [mk.spoke, mk.marketId, mk.name, mk.range, mk.pair, mk.vaultToken, mk.lpOracle])),
    ),
    "",
  );

  const periphery = m.manifest.avana.flashLiquidators.map((f, i, all) => [
    all.length > 1 ? `FlashLiquidator ${i + 1} (${venueOf(m, f.integrationId)})` : `FlashLiquidator (${venueOf(m, f.integrationId)})`,
    `Avana's liquidation bot's flash liquidation helper for the ${venueOf(m, f.integrationId)} LiquidationModule: it borrows the debt asset from the Aave V3 Pool, liquidates and sells the pool tokens in one call. Only its \`OPERATOR\` can call it. Not upgradeable, no admin.`,
    f.address,
  ]);
  if (periphery.length) out.push("### Periphery", "", table(["Name", "Description", "Address"], periphery), "");

  const x = m.manifest;
  const ext: string[][] = [
    ["Aave V4 AccessManager", "Holds the Aave V4 roles of this chain and is the authority of every First-Loss Reserve and DAO deficit offset.", x.aave.accessManager],
  ];
  const groups = ["aave-v4", "aave-v3", ...KIND_ORDER.filter((k) => m.integrations.some((y) => y.kind === k)).map((k) => GROUP_OF[k])];
  for (const group of groups) {
    for (const e of x.external.filter((y) => y.group === group)) {
      // Hubs and Spokes are listed above; the Aave V4 AccessManager and the Aave V3 Pool have their own rows.
      if (group === "aave-v4" && (/^(Hub|Spoke) /.test(e.name) || same(e.address, x.aave.accessManager))) continue;
      if (group === "aave-v3" && same(e.address, x.aave.v3Pool.address)) continue;
      if (group === "uniswap-v4" && x.uniswapV4 && same(e.address, x.uniswapV4.poolManager.address)) continue;
      const text = externalText(group, e.name);
      if (!text) problems.push(`external ${group} "${e.name}" has no description here; add it to render.ts`);
      ext.push([displayName(group, e.name), `${text ?? "MISSING"}${standIn(e.standIn)}`, e.address]);
    }
    if (group === "aave-v3") ext.push(["Aave V3 Pool", "Lends the debt asset to FlashloanRepay and the FlashLiquidators for one call.", x.aave.v3Pool.address]);
    if (group === "uniswap-v4") {
      if (!x.uniswapV4) problems.push("missing: uniswapV4.poolManager (a Uniswap v4 integration is deployed)");
      else ext.push([displayName("uniswap-v4", "PoolManager"), externalText("uniswap-v4", "PoolManager") ?? "", x.uniswapV4.poolManager.address]);
    }
  }
  ext.push(
    ["Aave governance executor", "Admin of Avana's AccessManager; sends the Aave payloads that configure the Hubs, the Spokes and the loss layers.", x.roles.aaveGovernanceExecutor],
    ["Aave Protocol Guardian", "Holds the one-way `freezeReserve` and `pauseReserve` of the SpokeConfigurator (`AVANA_RESERVE_GUARDIAN_ROLE` on the Aave AccessManager).", x.roles.aaveProtocolGuardian],
  );
  const read = new Set([...m.markets.flatMap((y) => y.feeds), ...m.debtReserves.flatMap((y) => y.feeds)].map((f) => f.feed.toLowerCase()));
  for (const e of x.external.filter((y) => y.group === "feed")) {
    ext.push([
      e.name,
      `${read.has(e.address.toLowerCase()) ? "A price source Aave V4 reads for a market's pool token or a debt reserve (Price sources on Market Parameters)." : "Recorded with the deployment; Aave V4 reads it for no market or debt reserve of this deployment."}${standIn(e.standIn)}`,
      e.address,
    ]);
  }
  if (x.sequencerFeed) ext.push(["Chainlink L2 sequencer uptime feed", "Recorded in the release manifest; no Avana contract reads it.", x.sequencerFeed]);
  const extIntro = {
    main: "Contracts Avana relies on but does not deploy.",
    test: "Contracts Avana relies on but does not deploy. On the test networks some are test stand-ins deployed from the pinned sources.",
    local: "Contracts Avana relies on but does not deploy on a live network. On this local development chain the local stack deploys them from the pinned sources, some as test stand-ins.",
  }[m.net.kind];
  out.push("### External dependencies", "", extIntro, "", table(["Name", "Description", "Address"], ext), "");

  const assets: string[][] = m.tokens.map((t) => {
    const parts: string[] = [];
    const pooled = [...new Set(m.markets.filter((mk) => mk.tokens.includes(t.symbol)).map((mk) => mk.spoke))];
    if (pooled.length) parts.push(`pool token of markets on ${list(pooled)}`);
    const borrow = [...new Set(m.debtReserves.filter((r) => same(r.asset, t.address)).map((r) => r.spoke))];
    if (borrow.length) parts.push(`debt asset borrowable on ${list(borrow)}`);
    if (!parts.length) parts.push("no market or debt reserve of this deployment uses it");
    const text = parts.join("; ");
    return [t.symbol, `${text[0].toUpperCase()}${text.slice(1)}.${standIn(t.standIn)}`, t.address];
  });
  const assetsIntro = { main: "", test: " On the test networks these are test tokens.", local: " On this local development chain these are test tokens." }[m.net.kind];
  out.push("### Assets", "", `The ERC-20 tokens the release manifest records for this chain.${assetsIntro}`, "", table(["Name", "Description", "Address"], assets));
  return out.join("\n");
}

// ─── Market Parameters ───

export function renderParameters(m: Model): string {
  const out: string[] = header(m);
  const feedName = (a: string) => m.manifest.external.find((e) => e.group === "feed" && same(e.address, a))?.name ?? "Price source";
  out.push(
    `Each pool is listed as two markets with one LTV: Full range, whose band is the pool's usable tick range, and Custom range, a band around the listing price. Hub, Spoke and market addresses are on [Contract Addresses](${link(m, "addresses")}).`,
    "",
    provenance(m),
    "",
    "### Markets",
    "",
    "Each market's band (ticks, fixed for life), LTV, the max liquidation bonus Aave lists its vault-token reserve with, and the reserve's add cap in whole vault tokens, as listed.",
    "",
    table(
      ["Spoke", "Market ID", "Market", "Range", "Pool", "Band", "LTV", "Max liquidation bonus", "Add cap", "Vault-token decimals"],
      byKind(m).flatMap((x) =>
        m.markets
          .filter((mk) => mk.integrationId === x.id)
          .map((mk) => [
            mk.spoke,
            mk.marketId,
            `${mk.name} (${mk.pair})`,
            mk.range,
            mk.pool,
            `${mk.bandLower} to ${mk.bandUpper}`,
            pct(mk.ltvBps),
            pct(mk.maxLiquidationBonus - 10_000),
            int(mk.addCap),
            String(mk.unitDecimals),
          ]),
      ),
    ),
    "",
    "> A Uniswap v4 market's Pool is its PoolId. Each vault-token reserve has the market's LTV as its collateral factor, a draw cap of 0, a liquidation fee of 0, is not borrowable and does not take share transfers; `RiskModule.activateMarket` checks all of these.",
    "",
    "### Debt reserves",
    "",
    `The reserves each CDP Spoke lends, each with the First-Loss Reserve its RiskModule registered for it (under Avana core on [Contract Addresses](${link(m, "addresses", "avana-core")})).`,
    "",
    table(
      ["Spoke", "Hub", "Asset", "Reserve ID", "Decimals", "First-Loss Reserve"],
      m.debtReserves.map((r) => [r.spoke, r.hub, r.symbol, r.reserveId, String(r.decimals), r.firstLossReserve]),
    ),
    "",
    "### Loss layers",
    "",
    "The minimum funded balance of each (Hub, debt asset)'s First-Loss Reserve and DAO deficit offset, in whole tokens.",
    "",
    table(
      ["Hub", "Asset", "First-Loss Reserve minimum", "DAO deficit offset minimum"],
      m.lossLayers.map((l) => [l.hub, l.symbol, `${units(l.minimum, l.decimals)} ${l.symbol}`, `${units(l.offsetMinimum, l.decimals)} ${l.symbol}`]),
    ),
    "",
  );

  const feeds = new Map<string, { feed: string; heartbeat: number; readFor: string[] }>();
  const addFeed = (f: { feed: string; heartbeatSeconds: number }, what: string) => {
    const k = f.feed.toLowerCase();
    const e = feeds.get(k) ?? { feed: f.feed, heartbeat: f.heartbeatSeconds, readFor: [] };
    if (!e.readFor.includes(what)) e.readFor.push(what);
    feeds.set(k, e);
  };
  for (const mk of m.markets) for (const f of mk.feeds) addFeed(f, `${mk.spoke} market ${mk.marketId}`);
  for (const r of m.debtReserves) for (const f of r.feeds) addFeed(f, `${r.symbol} on ${r.spoke}`);
  out.push(
    "### Price sources",
    "",
    "The sources Aave V4's AaveOracles read for the pool tokens of each market (on its CDP Spoke's price Spoke) and for each debt reserve when the release manifest was produced. Aave governance may change a source; the next manifest records it.",
    "",
    table(
      ["Source", "Address", "Heartbeat", "Read for"],
      [...feeds.values()].map((f) => [feedName(f.feed), f.feed, seconds(f.heartbeat), f.readFor.join(", ")]),
    ),
    "",
  );

  const r = m.manifest.roles;
  const settings: string[][] = [
    [
      "Governance delay",
      seconds(m.governanceDelay),
      "Execution delay of the governance Safe's `AVANA_GOVERNANCE_ROLE`: listings, activations, debt reserves, the fee, the coverage ratio, Custom range widths and keeper additions wait it.",
    ],
    ["Keepers", String(r.keepers.length), "Liquidation bots registered in every RiskModule's keeper registry; borrowing stops while none is."],
  ];
  if (r.keeperTopUp) {
    settings.push([
      "Keeper top-up",
      `${units(r.keeperTopUp.minBalanceWei, 18)} to ${units(r.keeperTopUp.targetBalanceWei, 18)} ETH`,
      "A keeper signer below the first balance is refilled to the second from the keeper top-up wallet (`11_FundKeepers`).",
    ]);
  }
  if (m.manifest.sequencerFeed) {
    settings.push([
      "Sequencer uptime feed",
      "Chainlink L2 sequencer uptime feed",
      `Recorded in the release manifest; no Avana contract reads it. Its address is on [Contract Addresses](${link(m, "addresses", "external-dependencies")}).`,
    ]);
  } else {
    settings.push([
      "Sequencer uptime feed",
      "None",
      m.net.layer2 ? "No sequencer uptime feed is recorded on this network." : "Ethereum has no sequencer, so no uptime feed is recorded.",
    ]);
  }
  out.push("### Chain settings", "", table(["Parameter", "Value", "Description"], settings));
  return out.join("\n");
}

// ─── Access Control ───

export function renderAccessControls(m: Model): string {
  const r = m.manifest.roles;
  const flash = m.manifest.avana.flashLiquidators;
  const addr = (anchor: string) => link(m, "addresses", anchor);
  const kind = (address: string, safe: string, intended: string) => (m.isSafe(address) ? safe : `On this network a single account, not a Safe; the intended holder is ${intended}.`);
  const rows: string[][] = [
    [
      `[Aave governance executor](${addr("external-dependencies")})`,
      "`ADMIN_ROLE` of Avana's AccessManager: grants and revokes every Avana role, maps functions to roles and, as the default guardian of every role, cancels any scheduled operation. Sends the Aave payloads and the vault-token role operation. On the Aave AccessManager it holds the loss layers' reserve-admin role, their withdraw role (14-day delay) and, unless the loss-layers AIP names another caller, their coverage role.",
      "On Contract Addresses",
    ],
    [
      `[Aave Protocol Guardian](${addr("external-dependencies")})`,
      "`AVANA_RESERVE_GUARDIAN_ROLE` on the Aave AccessManager: the SpokeConfigurator's one-way `freezeReserve` and `pauseReserve`. No role on Avana's AccessManager.",
      "On Contract Addresses",
    ],
    [
      "Governance Safe",
      `${kind(r.governanceSafe, "4-of-7 Safe.", "a 4-of-7 Safe")} \`AVANA_GOVERNANCE_ROLE\` at the governance delay and \`AVANA_TIGHTEN_ROLE\` at 12 hours on Avana's AccessManager: it schedules every listing, activation, debt-reserve, fee, coverage-ratio and keeper change and executes it once the delay has passed. Not the AccessManager's admin.`,
      r.governanceSafe,
    ],
    [
      "Joint Configuration Safe",
      `${kind(r.jointConfigSafe, "2-of-3 Safe.", "a 2-of-3 Safe")} The risk steward: \`AVANA_TIGHTEN_ROLE\` with no delay, so it can remove a debt reserve or a keeper at once. No other role.`,
      r.jointConfigSafe,
    ],
    [
      "Emergency Guardian",
      `${kind(r.emergencyGuardian, "3-of-5 Safe.", "a 3-of-5 Safe")} Recorded in the release manifest; the deploy scripts grant it no role on Avana's AccessManager or on the Aave AccessManager.`,
      r.emergencyGuardian,
    ],
    ["Fee recipient (treasury)", "The RiskModules' `feeRecipient`: receives Avana's share of each liquidation. Holds no role; changed only by `setFee` at the governance delay.", m.manifest.feeRecipient],
  ];
  r.keepers.forEach((k, i) => {
    const ops = flash.filter((f) => same(f.operator, k)).map((f) => `the ${venueOf(m, f.integrationId)} FlashLiquidator`);
    rows.push([
      r.keepers.length > 1 ? `Liquidation keeper ${i + 1}` : "Liquidation keeper",
      `Registered in the keeper registry of every RiskModule; borrowing stops while no keeper is. The registry gates no call: liquidation is open to anyone.${ops.length ? ` Also the \`OPERATOR\` of ${list(ops)}.` : ""}`,
      k,
    ]);
  });
  for (const f of flash.filter((y) => !r.keepers.some((k) => same(k, y.operator)))) {
    rows.push(["FlashLiquidator operator", `The \`OPERATOR\` of the ${venueOf(m, f.integrationId)} FlashLiquidator, its only caller. Not a registered keeper.`, f.operator]);
  }
  if (r.keeperTopUp) {
    rows.push([
      "Keeper top-up wallet",
      `${m.isSafe(r.keeperTopUp.wallet) ? "" : "On this network an account, not a Safe. "}Refills each keeper signer below ${units(r.keeperTopUp.minBalanceWei, 18)} ETH to ${units(r.keeperTopUp.targetBalanceWei, 18)} ETH (\`11_FundKeepers\`). Holds no role.`,
      r.keeperTopUp.wallet,
    ]);
  }
  const out = header(m);
  out.push(
    provenance(m),
    "",
    "### Role holders",
    "",
    "Contracts link to their address on Contract Addresses. Safes and keeper accounts are listed here.",
    "",
    table(["Holder", "Roles and permissions", "Address"], rows),
    "",
    "### Governance delay",
    "",
    "The execution delay the governance Safe's governance role carries on this network.",
    "",
    table(
      ["Setting", "Value", "Description"],
      [["Governance delay (`AVANA_GOVERNANCE_ROLE`)", seconds(m.governanceDelay), "Wait between scheduling a governance call and executing it; the governance Safe schedules, any of its scheduled calls can be cancelled by the Aave governance executor."]],
    ),
  );
  return out.join("\n");
}

export function renderPage(page: Page, m: Model, problems: string[]): string {
  if (page === "addresses") return renderAddresses(m, problems);
  if (page === "parameters") return renderParameters(m);
  return renderAccessControls(m);
}
