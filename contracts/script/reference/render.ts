// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One network's section of each reference page, in the pages' format (docs/reference/README.md): a `## ` group that
// opens with `- network:`, `### ` sections, GFM tables and `> ` notes. Sections, tables and columns follow the site's
// pages one to one; the rows come from the model, so a network shows only what its deployment has.

import { KIND_ORDER, type Market, type Model, type Spoke, TWAP_WINDOW, VENUE } from "./model.ts";

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
const bps = (n: number) => `${int(n)} bps`;
const usd = (n: number | string) => `$${int(n)}`;
/** Seconds, with days or hours when whole: 432000 → "432,000 s (5 days)", 60 → "60 s". */
export function seconds(s: number): string {
  const unit = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;
  if (s >= 86_400 && s % 86_400 === 0) return `${int(s)} s (${unit(s / 86_400, "day")})`;
  if (s >= 3_600 && s % 3_600 === 0) return `${int(s)} s (${unit(s / 3_600, "hour")})`;
  return `${int(s)} s`;
}
const list = (xs: readonly string[]) => (xs.length <= 1 ? (xs[0] ?? "") : `${xs.slice(0, -1).join(", ")} and ${xs.at(-1)}`);
const cell = (s: string) => s.replace(/\|/g, "\\|");

function table(headers: readonly string[], rows: readonly (readonly string[])[]): string {
  const line = (cells: readonly string[]) => `| ${cells.map(cell).join(" | ")} |`;
  return [line(headers), `| ${headers.map(() => "---").join(" | ")} |`, ...rows.map(line)].join("\n");
}

const link = (m: Model, page: Page, anchor?: string) => `/developers/reference/${page}?network=${m.net.id}${anchor ? `#${anchor}` : ""}`;

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

/** CDP Spokes by collateral risk, lowest first (the Parameters page's order). */
function byRisk(m: Model): Spoke[] {
  const risk = (s: Spoke) => Math.min(...s.markets.map((x) => x.collateralRisk), Number.MAX_SAFE_INTEGER);
  return m.spokes.map((s, i) => ({ s, i })).sort((a, b) => risk(a.s) - risk(b.s) || a.i - b.i).map((x) => x.s);
}
/** CDP Spokes grouped by AMM, each in the Hub files' order (the Addresses page's order). */
const byKind = (m: Model) => KIND_ORDER.flatMap((k) => m.spokes.filter((s) => s.kind === k));
const allMarkets = (m: Model) => m.spokes.flatMap((s) => s.markets);
const kindsWithMarkets = (m: Model) => KIND_ORDER.filter((k) => allMarkets(m).some((x) => x.kind === k));
const fixedAssets = (m: Model) => m.debtAssets.filter((a) => a.fixedPrice);

/** Tokens in the Addresses page's order: the Hub's lend assets (fixed-price last), then the listed pool tokens. */
function pageTokens(m: Model): string[] {
  const lend = [...m.debtAssets.filter((a) => !a.fixedPrice), ...fixedAssets(m)].map((a) => a.symbol);
  return [...lend, ...m.tokens.map((t) => t.symbol).filter((s) => !lend.includes(s))];
}

const SLIP_GENERATIONS = ["Initial", "Gauge Caps", "Gauges V3", "Aero"];

function spokePools(s: Spoke): string {
  const c = s.category.replace("Gov-DeFi", "Gov/DeFi");
  const slip = s.kind === "slipstream";
  const phrase =
    {
      Stable: "in stablecoin pools",
      "Blue-chip": s.kind === "uniswap-v3" ? "in ETH and BTC pools against stablecoins" : "in ETH and BTC pools",
      "Correlated ETH": "in pools of ETH staking tokens against WETH",
      "Correlated BTC": "in pools of BTC tokens",
      "Gov/DeFi": slip ? "in governance and DeFi token pools" : "in pools of governance and DeFi tokens against WETH",
      Stocks: "in tokenized-stock pools against USDC",
    }[c] ?? `in ${c} pools`;
  return s.kind === "uniswap-v4" ? `in hookless ${phrase.slice(3)}` : phrase;
}

const lpVaultText: Record<string, (m: Model) => string> = {
  "uniswap-v3": () => "Holds every Uniswap v3 position pledged on this chain and unwinds it on exit or liquidation. Immutable, with no owner.",
  "uniswap-v4": () => "Holds every pledged position of a hookless Uniswap v4 pool on this chain and unwinds it on exit or liquidation. Immutable, with no owner.",
  slipstream: (m) => {
    const n = m.manifest.external.filter((e) => e.group === "slipstream" && /^CLFactory generation \d+$/.test(e.name)).length;
    const words = ["no", "one", "two", "three", "four", "five", "six"];
    return `Holds every unstaked Aero Slipstream position pledged on this chain, across the ${words[n] ?? n} factory generations, and unwinds it on exit or liquidation. Immutable, with no owner.`;
  },
};

const LENS_MODULES: [string, string][] = [
  ["LensAccountModule", "Account views and close-account sizing. Immutable."],
  ["LensMarketModule", "Views of one market. Immutable."],
  ["LensPriceModule", "Price, debt-price and pause-state views and deleverage sizing. Immutable."],
  ["LensLiquidationModule", "Liquidation preview. Immutable."],
  ["LensRiskModule", "Risk and Hub-asset views. Immutable."],
  ["LensPreviewModule", "Action previews. Immutable."],
  ["LensMarketsModule", "Market list and fee views. Immutable."],
  ["LensPositionsModule", "Position views, available actions and maximum-withdraw sizing. Immutable."],
  ["LensSpeedModule", "Speed-limit views: how much a borrow can take now under the RiskModule's speed windows. Immutable."],
];

// ─── Contract Addresses ───

export function renderAddresses(m: Model, problems: string[]): string {
  const a = m.manifest.avana;
  const markets = allMarkets(m);
  const kinds = kindsWithMarkets(m);
  const out: string[] = header(m);
  out.push(
    `One Hub with the Lend Spoke and ${m.spokes.length} CDP Spokes listing ${markets.length} markets. Market pools and risk parameters are on [Market Parameters](${link(m, "parameters")}).`,
    "",
    provenance(m),
    "",
    "### Hub",
    "",
    table(
      ["Name", "Description", "Address"],
      [
        [
          m.hub.name,
          "Standard Aave V4 Hub, the only Avana Hub on this chain. It holds the lent assets and the vault-token collateral of every Spoke below, and each Spoke sets its own risk parameters. Upgradeable by the Aave DAO, which owns its proxy.",
          m.hub.address,
        ],
      ],
    ),
    "",
  );
  for (const k of KIND_ORDER) {
    const spokes = m.spokes.filter((s) => s.kind === k);
    if (!spokes.length) continue;
    out.push(
      `### ${VENUE[k]} Spokes`,
      "",
      table(
        ["Name", "Description", "Address"],
        spokes.map((s) => [
          s.name,
          `Aave V4 CDP Spoke where ${VENUE[k]} positions ${spokePools(s)} are collateral for borrowing ${list(s.borrowable)}. Borrowers reach it only through the AaveAdapter. Upgradeable by the Aave DAO, which owns its proxy.`,
          s.address,
        ]),
      ),
      "",
    );
  }
  out.push(
    "### Lend Spoke",
    "",
    table(
      ["Name", "Description", "Address"],
      [
        [
          "Lend Spoke",
          `Supply-only Aave V4 Spoke where lenders supply ${list(m.debtAssets.map((d) => d.symbol))} for Avana borrowers to draw through the CDP Spokes. Upgradeable by the Aave DAO, which owns its proxy.`,
          m.lendSpoke.address,
        ],
      ],
    ),
    "",
    "> Each Spoke has its own AaveOracle, created with the Spoke; read its address from the Spoke's `ORACLE()`. Each vault-token reserve also names the Aave treasury Spoke as its fee receiver, with add and draw caps of 0, so it never holds vault tokens.",
    "",
  );

  const fixed = fixedAssets(m).map((d) => d.symbol);
  const fixedNote = fixed.length ? ` ${list(fixed)} ${fixed.length > 1 ? "are" : "is"} priced at a fixed $1 and ${fixed.length > 1 ? "need" : "needs"} none.` : "";
  const core: string[][] = [
    ["AvanaTimelock", "Owns and upgrades every Avana contract on this chain. Each change waits out a delay; only the governance Safe and the Aave governance executor can propose one. Immutable.", a.timelock.address],
    ["MarketRegistry", "Records every Hub, CDP Spoke, AMM integration, market, debt reserve and swap route Avana lists on this chain, and holds each Hub's pause switch. Upgradeable through the AvanaTimelock.", a.marketRegistry.address],
    ["ParameterStore", "Stores every Avana risk parameter on this chain with its hard bounds and the direction in which it may change. Upgradeable through the AvanaTimelock.", a.parameterStore.address],
    ["RiskModule", "Runs every Avana risk check (caps, circuit breakers, price freshness, Aave configuration drift) on pledges, borrows and withdrawals; holds no funds. Upgradeable through the AvanaTimelock.", a.riskModule.address],
    ["AaveAdapter", "The single entry point for borrowers: pledge, borrow, repay, withdraw, repay with collateral and fee collection go through it to the user's PositionProxy. Upgradeable through the AvanaTimelock.", a.aaveAdapter.address],
    ["LPVaultSwap", "Runs every liquidation of an Avana account on this chain and is the only address that can receive seized vault tokens. Upgradeable through the AvanaTimelock.", a.lpVaultSwap.address],
    ["Lock", "Shared reentrancy lock of the AaveAdapter and LPVaultSwap. Immutable.", a.lock.address],
    ["Collateralization", "Backing ledger of every pledged position, so every vault token stays fully backed. Immutable.", a.collateralization.address],
    ["VaultTokenFactory", "Registers each AMM integration's LPVault and deploys one vault token per CDP Spoke and market. Immutable.", a.vaultTokenFactory.address],
    ["ProxyManager", "Creates each user's PositionProxy, one per wallet, CDP Spoke and market, at an address fixed by those three values. Immutable.", a.proxyManager.address],
    ["PayoutEscrow", "Holds a liquidation payout that could not be sent to its recipient until the recipient claims it. Immutable.", a.payoutEscrow.address],
  ];
  for (const d of m.debtAssets) {
    core.push(
      [
        `Avana First-Loss Reserve, ${d.symbol}`,
        `Avana's first-loss capital for ${d.symbol} on this Hub: it covers deficits Aave records on Avana CDP Spokes before any other layer. Immutable; the Aave DAO controls it through its AccessManager.`,
        d.firstLossReserve,
      ],
      [
        `DAO deficit offset, ${d.symbol}`,
        `Second loss layer for ${d.symbol} on this Hub, funded by the Aave DAO treasury; it pays only once the ${d.symbol} First-Loss Reserve is empty or deactivated. Immutable; deployed and controlled by the Aave DAO.`,
        d.daoDeficitOffset,
      ],
    );
  }
  for (const d of m.debtAssets) {
    if (d.debtOracle) {
      core.push([
        `DebtOracle, ${d.symbol}`,
        `Price source of the ${d.symbol} debt reserve on every CDP Spoke's AaveOracle, with failover to an alternate and a standby route.${fixedNote} Upgradeable through the AvanaTimelock.`,
        d.debtOracle,
      ]);
    }
  }
  for (const d of m.debtAssets) {
    if (d.fixedPriceSource) {
      core.push([
        `Fixed $1 price source, ${d.symbol}`,
        `Answers a fixed $1 for ${d.symbol} on every Spoke's AaveOracle of this network, in place of Aave's fixed ${d.symbol} price. A test stand-in the listing deploys. Immutable.`,
        d.fixedPriceSource,
      ]);
    }
  }
  core.push(["AvanaCreate3Factory", "Deploys Avana contracts at addresses that depend only on the deployer and a salt, so every address is known before deployment. Immutable.", m.manifest.create3Factory]);
  out.push(
    "### Avana core",
    "",
    "The contracts Avana deploys on this chain. For an upgradeable contract the address is its fixed proxy; the current implementation and logic contracts are recorded in the release manifest.",
    "",
    table(["Name", "Description", "Address"], core),
    "",
    "> Each market's vault token and LPOracle proxy are under Markets. Its swap routes, a primary and a backup route per pool token and debt asset, belong to the market and are recorded in the MarketRegistry and the release manifest.",
    "",
    "### Markets",
    "",
    "Each market has its own vault token, the ERC-20 a pledge mints and the Spoke holds as collateral, and its own LPOracle proxy, which prices the vault token for the Spoke's AaveOracle. Vault tokens are immutable; each LPOracle is upgradeable through the AvanaTimelock.",
    "",
    table(
      ["Spoke", "Market", "Market ID", "Vault token", "LPOracle"],
      byKind(m).flatMap((s) => s.markets.map((x) => [s.name, x.pair, x.marketId, x.vaultToken, x.lpOracle])),
    ),
    "",
  );

  const periphery: string[][] = [
    ["Lens", "The read-only contract apps, keepers and monitoring call for account, market, price, risk and liquidation state in one call. No Avana contract depends on it. Immutable; replaced by a new deployment.", a.lens.address],
  ];
  for (const k of kinds) {
    const v = a.lpVaults.find((x) => x.kind === k);
    if (!v) problems.push(`missing: avana.lpVaults[kind=${k}] (markets use it)`);
    periphery.push([`${VENUE[k]} integration (LPVault)`, lpVaultText[k](m), v?.address ?? "MISSING"]);
  }
  periphery.push(
    ["AaveV3FlashSource", "Lends LPVaultSwap the debt asset from the Aave V3 Pool for one call so a borrower can repay with collateral. Immutable; the AvanaTimelock can replace it.", a.flashSource.address],
    ["FlashLiquidator", "Public flash liquidation helper: anyone can liquidate an account without holding the debt asset. Immutable.", a.flashLiquidator.address],
  );
  a.operatorHelpers.forEach((h, i) => {
    periphery.push([
      a.operatorHelpers.length > 1 ? `OperatorFlashLiquidator ${i + 1}` : "OperatorFlashLiquidator",
      "Avana's keeper's own flash liquidation helper; only its signer can call it. Immutable.",
      h.address,
    ]);
  });
  periphery.push([
    "AvanaGasVault",
    "Holds the chain's native gas token and refills Avana's own keeper signers up to a per-signer cap over any 24 hours. Immutable.",
    a.gasVault ? a.gasVault.address : "Not deployed on this network",
  ]);
  const modules = a.lensModules.map((x) => ({ name: (x.artifact ?? "").split(":").at(-1) ?? "", address: x.address }));
  const moduleRows: string[][] = [];
  for (const [name, text] of LENS_MODULES) {
    const x = modules.find((y) => y.name === name);
    if (!x) problems.push(`missing: avana.lensModules[artifact=${name}]`);
    moduleRows.push([name, text, x?.address ?? "MISSING"]);
  }
  for (const x of modules) if (!LENS_MODULES.some(([n]) => n === x.name)) problems.push(`Lens module ${x.name || x.address} has no description here; add it to render.ts`);
  moduleRows.push(["LensAaveSizing", "Aave V4's liquidation sizing, compiled from the pinned Aave V4 release, used by the liquidation preview. Immutable.", a.lensAaveSizing.address]);
  out.push(
    "### Periphery",
    "",
    table(["Name", "Description", "Address"], periphery),
    "",
    "#### Lens modules (called only through Lens)",
    "",
    "The Lens forwards each view to one of these read-only contracts. Call the Lens, not these.",
    "",
    table(["Name", "Description", "Address"], moduleRows),
    "",
  );

  const x = m.external;
  const ext: string[][] = [
    ["Aave V4 AccessManager", "Holds the Aave V4 roles of this chain and is the authority of every First-Loss Reserve and DAO deficit offset.", m.manifest.aave.accessManager],
    ["Aave V4 HubConfigurator", "Aave DAO payloads configure the Hub through it.", x("aave-v4", "hubConfigurator")],
    ["Aave V4 SpokeConfigurator", "Aave DAO payloads configure the Spokes through it; the Aave Protocol Guardian freezes or pauses reserves through it.", x("aave-v4", "spokeConfigurator")],
    ["Aave governance executor", "Owns every Hub and Spoke of this chain, and can propose and cancel AvanaTimelock operations.", m.manifest.roles.aaveGovernanceExecutor],
    ["Aave Protocol Guardian", "Can freeze and pause Avana reserves on Aave, and holds Avana's pause, freeze and cancel roles.", m.manifest.roles.aaveProtocolGuardian],
    ["Aave V3 Pool", "Lends the debt asset to the AaveV3FlashSource and the flash liquidation helpers.", m.manifest.aave.v3Pool.address],
    ["Aave V3 ACLManager", "Grants the flash borrower role that lets the AaveV3FlashSource and the FlashLiquidator borrow without a fee.", x("aave-v3", "ACLManager")],
  ];
  const v3 = kinds.includes("uniswap-v3");
  const v4 = kinds.includes("uniswap-v4");
  ext.push([
    "Uniswap v3 Factory",
    v3
      ? `Avana derives each Uniswap v3 market's pool from it and refuses any pool it did not create${v4 ? "; it also creates the v3 reference pools of the Uniswap v4 markets" : ""}.`
      : v4
        ? "Creates the v3 reference pools of the Uniswap v4 markets and the pools the liquidation swap routes of this chain use."
        : "Creates the Uniswap v3 pools the liquidation swap routes of this chain use.",
    x("uniswap-v3", "UniswapV3Factory"),
  ]);
  if (v3) {
    ext.push([
      "Uniswap v3 NonfungiblePositionManager",
      "Issues the Uniswap v3 position NFTs users pledge; the Uniswap v3 LPVault accepts positions of this contract only.",
      x("uniswap-v3", "NonfungiblePositionManager"),
    ]);
  }
  if (v4) {
    const pm = m.manifest.uniswapV4?.poolManager.address;
    if (!pm) problems.push("missing: uniswapV4.poolManager (Uniswap v4 markets are listed)");
    ext.push(
      ["Uniswap v4 PoolManager", "Holds every Uniswap v4 pool; the Uniswap v4 LPVault reads positions and removes liquidity through it.", pm ?? "MISSING"],
      ["Uniswap v4 PositionManager", "Issues the Uniswap v4 position NFTs users pledge.", x("uniswap-v4", "PositionManager")],
    );
  }
  if (kinds.includes("slipstream")) {
    const gens = m.manifest.external
      .map((e) => /^CLFactory generation (\d+)$/.exec(e.name)?.[1])
      .filter((g): g is string => isDefined(g))
      .map(Number)
      .sort((p, q) => p - q);
    for (const g of gens) {
      const label = SLIP_GENERATIONS[g] ?? `generation ${g}`;
      ext.push(
        [`Aero Slipstream CLFactory (${label})`, `Pool factory of the ${label} generation; Avana derives a market's pool from the factory of that market's generation.`, x("slipstream", `CLFactory generation ${g}`)],
        [`Aero Slipstream position manager (${label})`, `Issues the Slipstream position NFTs of the ${label} generation that users pledge.`, x("slipstream", `NonfungiblePositionManager generation ${g}`)],
      );
    }
  }
  if (m.manifest.sequencerFeed) {
    ext.push(["Chainlink L2 sequencer uptime feed", "While it reports the sequencer down, borrow-side prices fail closed and liquidation pauses.", m.manifest.sequencerFeed]);
  }
  for (const sym of pageTokens(m)) {
    const fixed = m.debtAssets.find((d) => d.symbol === sym)?.fixedPrice;
    ext.push([
      `${sym} / USD price feed`,
      fixed ? `Primary ${sym} feed, used for monitoring only; ${sym} is priced at a fixed $1.` : `Primary USD price feed of ${sym}, read by the Avana oracles that price it.`,
      x("feed", `${sym} / USD (primary)`),
    ]);
  }
  const extIntro = {
    main: "Contracts Avana relies on but does not deploy.",
    test: "Contracts Avana relies on but does not deploy. On the test networks some are test stand-ins deployed from the pinned sources.",
    local: "Contracts Avana relies on but does not deploy on a live network. On this local development chain the local stack deploys them from the pinned sources, some as test stand-ins.",
  }[m.net.kind];
  out.push(
    "### External dependencies",
    "",
    extIntro,
    "",
    table(["Name", "Description", "Address"], ext),
    "",
    "> Each token also has an alternate route, a standby route and an independent second price source; their addresses are in the release manifest. The RiskModule also reads `paused()` on USDC and `basisPointsRate()` on USDT for its issuer-action circuit breaker.",
    "",
  );

  const assets: string[][] = pageTokens(m).map((sym) => {
    const parts: string[] = [];
    const pools = byKind(m).filter((s) => s.markets.some((mk) => mk.tokens.includes(sym)));
    if (pools.length) {
      const stock = pools.every((s) => s.category === "Stocks");
      parts.push(`${stock ? "Tokenized stock; pool token" : "Pool token"} on the ${pools.map((s) => s.name).join(", ")} Spoke${pools.length > 1 ? "s" : ""}`);
    }
    if (m.debtAssets.some((d) => d.symbol === sym)) parts.push("supplied on the Lend Spoke");
    const borrow = m.spokes.filter((s) => s.borrowable.includes(sym));
    if (borrow.length) parts.push(borrow.length === m.spokes.length ? "borrowable on every CDP Spoke" : `borrowable on the ${borrow.map((s) => s.name).join(", ")} Spoke${borrow.length > 1 ? "s" : ""}`);
    if (!parts.length) parts.push("Listed in the MarketRegistry; no market on this chain uses it as a pool token");
    const text = parts.join("; ");
    return [sym, `${text[0].toUpperCase()}${text.slice(1)}.`, m.tokenAddress(sym)];
  });
  const assetsIntro = { main: "", test: " On the test networks these are test tokens.", local: " On this local development chain these are test tokens." }[m.net.kind];
  out.push("### Assets", "", `The ERC-20 tokens this chain's markets, Lend Spoke and debt reserves use.${assetsIntro}`, "", table(["Name", "Description", "Address"], assets));
  return out.join("\n");
}

function isDefined<T>(v: T | undefined): v is T {
  return v !== undefined;
}

// ─── Market Parameters ───

function feeText(x: Market): string {
  return x.kind === "slipstream" ? `Tick spacing ${x.tickSpacing}` : pct((x.fee ?? Number.NaN) / 100);
}

/** One value per Spoke, or each market's when they differ. */
function perSpoke(s: Spoke, f: (x: Market) => string): string {
  const vals = [...new Set(s.markets.map(f))];
  return vals.length <= 1 ? (vals[0] ?? "—") : s.markets.map((x) => `${f(x)} (${x.pair})`).join(", ");
}

export function renderParameters(m: Model, problems: string[]): string {
  const spokes = byRisk(m);
  const markets = allMarkets(m);
  const hasV4 = markets.some((x) => x.kind === "uniswap-v4");
  const slip = markets.some((x) => x.kind === "slipstream");
  const lendSyms = m.debtAssets.map((d) => d.symbol);
  const out: string[] = header(m);
  out.push(
    `Every Spoke here is on the ${m.hub.name}; Hub and Spoke addresses are on [Contract Addresses](${link(m, "addresses")}). Spokes are listed by collateral risk, lowest first. Reserves are the debt assets the Hub lists (${lendSyms.join(", ")}) and one LP collateral reserve per market. \`—\` means the setting does not apply.${slip ? " Aero Slipstream pools use dynamic fees, so each market is named by its tick spacing." : ""}`,
    "",
    provenance(m),
    "",
    "### Interest rate curves",
    "",
    `One curve per debt asset on the ${m.hub.name}. LP reserves are collateral only and have no curve.`,
    "",
    table(
      ["Hub", "Reserve", "Base drawn rate", "Rate growth before optimal", "Rate growth after optimal", "Optimal usage ratio", "Liquidity fee"],
      m.debtAssets.map((d) => [
        m.hub.name,
        d.symbol,
        pct(d.rate.baseDrawnRateBps),
        pct(d.rate.rateGrowthBeforeOptimalBps),
        pct(d.rate.rateGrowthAfterOptimalBps),
        pct(d.rate.optimalUsageBps),
        pct(d.liquidityFeeBps),
      ]),
    ),
    "",
    "### Credit lines",
    "",
    "The Aave DAO funds each borrowable asset by supplying it to the Hub through the Lend Spoke, up to the credit line the MarketRegistry records.",
    "",
    table(
      ["Origin", "Target Hub", "Reserve", "Credit line size"],
      m.debtAssets.filter((d) => d.listed).map((d) => ["Aave DAO, through the Lend Spoke", m.hub.name, d.symbol, `${int(d.creditLineWhole ?? Number.NaN)} ${d.symbol}`]),
    ),
    "",
  );

  const caps: string[][] = m.debtAssets.map((d) => ["Lend Spoke", d.symbol, "Max", "0"]);
  for (const s of spokes) {
    for (const d of m.debtAssets) caps.push([s.name, d.symbol, "0", int(d.drawCap)]);
    for (const x of s.markets) caps.push([s.name, `${x.pair} LP`, "Max", "0"]);
  }
  out.push(
    "### Add and draw caps",
    "",
    "Caps in whole tokens. The Lend Spoke takes supply and draws nothing; CDP Spokes draw the borrowable assets and take LP collateral. Avana's own market caps (under LP market parameters) bound LP collateral further.",
    "",
    table(["Spoke", "Reserve", "Add cap", "Draw cap"], caps),
    "",
    "> `Max` is Aave V4's largest Spoke cap (`MAX_ALLOWED_SPOKE_CAP`). A debt asset that is not borrowable on a CDP Spoke keeps its draw cap but cannot be drawn.",
    "",
  );

  const risk: string[][] = m.debtAssets.map((d) => ["Lend Spoke", d.symbol, "0%", "—", "Yes", "—", "0%", "Max", "No"]);
  for (const s of spokes) {
    for (const x of s.markets) risk.push([s.name, `${x.pair} LP`, pct(x.collateralFactorBps), pct(x.maxLiquidationBonus - 10_000), "No", bps(x.collateralRisk), "0%", "Max", "No"]);
    for (const d of m.debtAssets) risk.push([s.name, d.symbol, "0%", "—", s.borrowable.includes(d.symbol) ? "Yes" : "No", "—", "0%", "Max", "No"]);
  }
  out.push(
    "### Risk parameters",
    "",
    "LP reserves are collateral only. Debt reserves are never collateral. The Lend Spoke's reserves carry the borrowable flag, but their draw cap is 0, so nothing is drawn through the Lend Spoke.",
    "",
    table(["Spoke", "Reserve", "Collateral factor", "Max liquidation bonus", "Borrowable", "Collateral risk", "Liquidation fee", "Risk premium threshold", "receiveShares"], risk),
    "",
    "> Collateral risk is Aave V4's `collateralRisk`: the premium borrowers pay on top of the base rate, and lenders earn, for that collateral. `Max` is Aave V4's `MAX_RISK_PREMIUM_THRESHOLD`. Avana requires a liquidation fee of 0 on every LP reserve; its revenue from a liquidation is the fee share under Fees.",
    "",
  );

  const fixed = fixedAssets(m);
  const standIn = fixed.some((d) => d.fixedPriceSource);
  const fixedSentence = fixed.length
    ? standIn
      ? ` ${list(fixed.map((d) => d.symbol))} has no feed: it is priced at a fixed $1, served on this network by a fixed price source the listing deploys.`
      : ` ${list(fixed.map((d) => d.symbol))} has no feed: Aave prices it at a fixed $1.`
    : "";
  const feeds: string[][] = m.debtAssets.map((d) => {
    let source: string;
    if (d.fixedPrice) source = d.fixedPriceSource ? `[Fixed $1 price source, ${d.symbol}](${link(m, "addresses", "avana-core")})` : "Fixed $1 price (Aave)";
    else if (d.debtOracle) source = `[DebtOracle, ${d.symbol}](${link(m, "addresses", "avana-core")})`;
    else source = `[${d.symbol} / USD price feed](${link(m, "addresses", "external-dependencies")})`;
    return ["Lend Spoke and every CDP Spoke", d.symbol, source];
  });
  for (const s of spokes) feeds.push([s.name, "Each LP reserve", `[The market's LPOracle](${link(m, "addresses", "markets")})`]);
  out.push(
    "### Price feeds",
    "",
    `Each Spoke has its own AaveOracle; these are the sources it reads. Each name links to its address on Contract Addresses.${fixedSentence} Each market's LPOracle is under Markets on Contract Addresses.`,
    "",
    table(["Spoke", "Reserve", "Oracle"], feeds),
    "",
  );

  const lpHeaders = ["Spoke", "Market", "Pool", ...(hasV4 ? ["v3 reference pool"] : []), "Fee tier or tick spacing", "Pool risk factor", "Market cap", "Consistency tolerance"];
  const lpRows = spokes.flatMap((s) =>
    s.markets.map((x) => [
      s.name,
      x.pair,
      x.pool,
      ...(hasV4 ? [x.referencePool ?? "—"] : []),
      feeText(x),
      pct(x.poolRiskFactorBps),
      usd(x.marketUsdCap),
      pct(x.consistencyToleranceBps),
    ]),
  );
  out.push(
    "### LP market parameters",
    "",
    "Avana's own settings for each market: the pool it accepts, how much of the pool's value counts as collateral, and how much can be pledged.",
    "",
    table(lpHeaders, lpRows),
    "",
  );
  if (hasV4) {
    const v4Markets = markets.filter((x) => x.kind === "uniswap-v4");
    const refFees = [...new Set(v4Markets.map((x) => x.referenceFee))];
    // The fee is shown when the world records every reference pool with one fee (a pool the deploy creates has none).
    const feeNote = refFees.length === 1 && refFees[0] !== undefined ? ` (fee ${pct(refFees[0] / 100)})` : "";
    out.push(
      `> A Uniswap v4 market's Pool is its PoolId. Hookless Uniswap v4 pools keep no price history, so each also reads the same pair's Uniswap v3 reference pool${feeNote} for the price check.`,
      "",
    );
  }

  out.push(
    "### Slippage allowance",
    "",
    "The most below oracle value a liquidation's swaps may settle (`slippageAllowanceBps`), and the floor a tightening cannot go below (`slippageAllowanceMinBps`), as each Spoke's markets were listed.",
    "",
    table(
      ["Spoke", "Slippage allowance", "Slippage allowance floor"],
      spokes.map((s) => [s.name, perSpoke(s, (x) => bps(x.slippageAllowanceBps)), perSpoke(s, (x) => bps(x.slippageAllowanceMinBps))]),
    ),
    "",
    "### Lend Spoke",
    "",
    "Each debt asset has a First-Loss Reserve and a DAO deficit offset on the Hub.",
    "",
    table(
      ["Asset", "Borrowable on CDP Spokes", "First-Loss Reserve minimum", "DAO deficit offset minimum"],
      m.debtAssets.map((d) => [d.symbol, m.spokes.some((s) => s.borrowable.includes(d.symbol)) ? "Yes" : "No", `${int(d.coverageMinimum)} ${d.symbol}`, `${int(d.offsetMinimum)} ${d.symbol}`]),
    ),
    "",
    "### Collateral tokens",
    "",
    "Each pool token's collateral factor (CF0 and CF1 in the LP collateral factor, `min(CF0, CF1) × poolRiskFactor`) and its exposure cap across every Spoke and market of the Hub.",
    "",
    table(["Token", "Token collateral factor", "Token cap"], m.tokens.map((t) => [t.symbol, pct(t.collateralFactorBps), usd(t.tokenCapUsd)])),
    "",
  );

  const bt = m.blockTime;
  const settings: string[][] = [
    ["`CHAIN_BLOCK_TIME`", `${bt} s`, "Block interval of the chain. It sizes the observation buffer a pool needs for the time-weighted price check."],
    ["`twapMinObservations`", int(Math.floor((TWAP_WINDOW + bt - 1) / bt) + 1), `Observation slots a pool must hold for a ${int(TWAP_WINDOW)} s window at ${bt} s blocks.`],
  ];
  if (m.manifest.sequencerFeed) {
    settings.push(
      [
        "`sequencer.feed`",
        "Chainlink L2 sequencer uptime feed",
        `While it reports the sequencer down, borrow-side prices fail closed and liquidation pauses. Its address is on [Contract Addresses](${link(m, "addresses", "external-dependencies")}).`,
      ],
      ["`sequencer.gracePeriod`", seconds(m.sequencerGraceSeconds), "Time after a sequencer restart during which borrowing and new pledges are refused (bounds 600–7,200 s)."],
    );
  } else {
    settings.push([
      "`sequencer.feed`",
      "None",
      m.net.layer2
        ? "No sequencer uptime feed is read on this network; the feed and its grace period apply on Base mainnet only."
        : "Ethereum has no sequencer, so no uptime feed is read.",
    ]);
  }
  const t = m.manifest.roles.timelock;
  settings.push(
    ["`SHORT_DELAY`", seconds(m.shortDelay), "Timelock delay of an operation whose every call is on the short-delay list."],
    ["`normalDelay`", seconds(t.normalDelay), "Timelock delay of every other operation."],
    ["`publicExecution`", t.publicExecution ? "true" : "false", t.publicExecution ? "Any address may execute a ready timelock operation." : "Only the governance Safe executes ready timelock operations."],
    ["`MAX_MARKET_COUNT`", int(m.maxMarketCount), "Most markets this chain's MarketRegistry ever lists, fixed when it was deployed."],
  );
  const thresholds = markets.flatMap((x) => x.routes.flatMap((r) => [r.depthThreshold, r.backupDepthThreshold]).filter((v): v is number => v !== undefined));
  const unset = markets.some((x) => x.routes.some((r) => r.depthThreshold === undefined));
  if (!thresholds.length && m.net.kind === "local") {
    settings.push(["`routeDepthThreshold`", "Not set", "The local development chains list swap routes without a depth threshold; the monitor reports each route slot as having none."]);
  } else {
    if (unset) problems.push("missing: routeDepthThreshold of some swap routes (listing.markets[].routes[].depthThreshold)");
    const vals = [...new Set(thresholds)].sort((p, q) => p - q).map((v) => int(v));
    settings.push(["`routeDepthThreshold`", vals.join(" or ") || "MISSING", "Whole units of the route's debt asset each approved swap route must deliver within the slippage allowance in the stress case, set on every route slot at listing."]);
  }
  for (const d of m.debtAssets) {
    if (d.debtOracle) settings.push([`\`pokeMinGas\` (DebtOracle, ${d.symbol})`, `${int(d.debtOraclePokeMinGas ?? Number.NaN)} gas`, `Minimum gas a \`poke()\` of the ${d.symbol} DebtOracle needs at entry.`]);
  }
  out.push("### Chain settings", "", table(["Parameter", "Value", "Description"], settings));
  return out.join("\n");
}

// ─── Access Control ───

export function renderAccessControls(m: Model): string {
  const r = m.manifest.roles;
  const a = m.manifest.avana;
  const gv = a.gasVault;
  const addr = (anchor: string) => link(m, "addresses", anchor);
  const kind = (address: string, safe: string, intended: string) => (m.isSafe(address) ? safe : `On this network a single account, not a Safe; the intended holder is ${intended}.`);
  const rows: string[][] = [
    [
      `[AvanaTimelock](${addr("avana-core")})`,
      "Holds `DEFAULT_ADMIN_ROLE` on itself, `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` on every upgradeable Avana contract, and is the `TIMELOCK` address of every immutable Avana contract.",
      "On Contract Addresses",
    ],
    [
      `[Aave governance executor](${addr("external-dependencies")})`,
      "`PROPOSER_ROLE`, `CANCELLER_ROLE` and `DAO_CANCELLER_ROLE` on the AvanaTimelock; the MarketRegistry's immutable `AAVE_GOVERNANCE_EXECUTOR` (`cancelStandbySwitch`); `RESERVE_ADMIN_ROLE` on every First-Loss Reserve; admin and configurator of the Hub, the Lend Spoke and every CDP Spoke.",
      "On Contract Addresses",
    ],
    [
      `[Aave Protocol Guardian](${addr("external-dependencies")})`,
      "Same Avana roles as the Emergency Guardian (both guardian roles, `CANCELLER_ROLE`, `COVERAGE_ROLE`), plus Aave's one-way `freezeReserve` and `pauseReserve` on CDP Spoke reserves and `freezeReserve` on Lend Spoke reserves.",
      "On Contract Addresses",
    ],
    [
      "Governance Safe",
      `${kind(r.governanceSafe, "4-of-7 Safe with Avana Labs and external signers.", "a 4-of-7 Safe with Avana Labs and external signers")} \`PROPOSER_ROLE\`, \`CANCELLER_ROLE\` and \`EXECUTOR_ROLE\` on the AvanaTimelock. No role on any other Avana contract and no immediate power.`,
      r.governanceSafe,
    ],
    [
      "Emergency Guardian",
      `${kind(r.emergencyGuardian, "3-of-5 Safe: three Avana Labs seats, one Aave Labs seat, one independent risk-provider seat.", "a 3-of-5 Safe with three Avana Labs seats, one Aave Labs seat and one independent risk-provider seat")} \`APPLICATION_PAUSE_GUARDIAN\` and \`APPLICATION_FREEZE_GUARDIAN\` on the MarketRegistry, \`APPLICATION_PAUSE_GUARDIAN\` on the ParameterStore, \`CANCELLER_ROLE\` on the AvanaTimelock, \`COVERAGE_ROLE\` on every First-Loss Reserve${gv && gv.guardian.toLowerCase() === r.emergencyGuardian.toLowerCase() ? ", and the AvanaGasVault's `GUARDIAN`" : ""}. No upgrade or parameter power.`,
      r.emergencyGuardian,
    ],
    [
      "Joint Configuration Safe",
      `${kind(r.jointConfigSafe, "2-of-3 Safe: one Avana Labs, one Aave Labs and one independent risk-provider signer.", "a 2-of-3 Safe with one Avana Labs, one Aave Labs and one independent risk-provider signer")} \`APPLICATION_PAUSE_GUARDIAN\` and \`APPLICATION_FREEZE_GUARDIAN\` on the MarketRegistry and \`APPLICATION_RISK_STEWARD\` on the ParameterStore. Cannot loosen, upgrade, change roles, cover a deficit or cancel.`,
      r.jointConfigSafe,
    ],
    [
      "Fee recipient (treasury)",
      `The ParameterStore's \`feeRecipient\`${gv && gv.treasury.toLowerCase() === m.manifest.feeRecipient.toLowerCase() ? " and the AvanaGasVault's `TREASURY`" : ""}. Receives the ${pct(m.avanaFeeShareBps)} liquidation fee share and the app's frontend fee. Holds no role; changed only by \`setFeeRecipient\` at the normal delay.`,
      m.manifest.feeRecipient,
    ],
  ];
  r.keepers.forEach((k, i) => {
    const refilled = gv && m.gasVaultSigners.includes(k.toLowerCase());
    const helper = a.operatorHelpers.some((h) => h.signer.toLowerCase() === k.toLowerCase());
    rows.push([
      r.keepers.length > 1 ? `Liquidation keeper ${i + 1}` : "Liquidation keeper",
      `Avana's own committed operator on LPVaultSwap, counted toward \`keeperFloor\`.${helper ? ` Also the signer of the OperatorFlashLiquidator${refilled ? " and a signer the AvanaGasVault refills" : ""}.` : refilled ? " Also a signer the AvanaGasVault refills." : ""} Never the deployer or the treasury.`,
      k,
    ]);
  });
  a.operatorHelpers.forEach((h, i) => {
    rows.push([
      a.operatorHelpers.length > 1 ? `Keeper funding Safe ${i + 1}` : "Keeper funding Safe",
      `${m.isSafe(h.fundingSafe) ? "" : "On this network an account, not a Safe. "}\`FUNDING_SAFE\` of the OperatorFlashLiquidator: its only payer and payout recipient. Holds no role.`,
      h.fundingSafe,
    ]);
  });
  const t = r.timelock;
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
    "### Timelock",
    "",
    "The AvanaTimelock's delays and execution setting on this network.",
    "",
    table(
      ["Setting", "Value", "Description"],
      [
        ["Short delay (`SHORT_DELAY`)", seconds(m.shortDelay), "Delay of an operation whose every call is on the short list."],
        ["Normal delay (`normalDelay`)", seconds(t.normalDelay), "Delay of every other operation, including upgrades and role changes."],
        ["Public execution", t.publicExecution ? "On" : "Off", t.publicExecution ? "Any address may execute a ready operation." : "Only the governance Safe executes ready operations."],
      ],
    ),
  );
  return out.join("\n");
}

export function renderPage(page: Page, m: Model, problems: string[]): string {
  if (page === "addresses") return renderAddresses(m, problems);
  if (page === "parameters") return renderParameters(m, problems);
  return renderAccessControls(m);
}
