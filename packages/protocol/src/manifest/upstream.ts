// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Upstream check: the Aave V4 runtime code Avana deploys on test networks (out-aave/, pinned a3ef63e) against the code
// the Aave DAO runs on Ethereum, with immutables, linked library addresses and a library's own address masked.
// Addresses: bgd-labs/aave-address-book src/AaveV4Ethereum.sol at 967c772c.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { type Address, type PublicClient, getAddress } from "viem";
import { ADMIN_SLOT, implementationOf } from "./chain.ts";
import type { Check } from "./verify.ts";

type Span = { start: number; length: number };
interface Runtime { readonly code: string; readonly spans: Span[]; readonly links: Span[] }

const PROXY = "out-aave:TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy";
const PROXY_ADMIN = "out-aave:ProxyAdmin.sol:ProxyAdmin";
const HUB = "out-aave:HubInstance.sol:HubInstance";
const SPOKE = "out-aave:SpokeInstance.sol:SpokeInstance";
const ORACLE = "out-aave:AaveOracle.sol:AaveOracle";
const IR = "out-aave:AssetInterestRateStrategy.sol:AssetInterestRateStrategy";

/** `artifact` is `<outDir>:<file>:<contract>`. Spans: immutables, linked libraries, a library's call-guard address. */
export function upstreamRuntime(contractsDir: string, artifact: string): Runtime | null {
  const [outDir, file, name] = artifact.split(":");
  const path = join(contractsDir, outDir!, file!, `${name}.json`);
  if (!existsSync(path)) return null;
  const d = (JSON.parse(readFileSync(path, "utf8")) as {
    deployedBytecode: {
      object: string;
      immutableReferences?: Record<string, Span[]>;
      linkReferences?: Record<string, Record<string, Span[]>>;
    };
  }).deployedBytecode;
  const code = d.object.replace(/^0x/, "").toLowerCase();
  const links = Object.values(d.linkReferences ?? {}).flatMap((f) => Object.values(f).flat());
  const spans = [...Object.values(d.immutableReferences ?? {}).flat(), ...links];
  // Legacy codegen leaves a library's `PUSH20 <own address> ADDRESS EQ` guard zero; deployment fills it in.
  if (/^73(00){20}3014/.test(code)) spans.push({ start: 1, length: 20 });
  return { code, spans, links };
}

export function mask(code: string, spans: Span[]): string {
  const chars = code.split("");
  for (const m of spans) for (let i = m.start * 2; i < (m.start + m.length) * 2; i++) chars[i] = "0";
  return chars.join("");
}

export interface Target { readonly label: string; readonly address: Address; readonly artifact: string; readonly proxy?: boolean }

const t = (label: string, address: string, artifact: string, proxy = false): Target => ({ label, address: getAddress(address), artifact, proxy });
export const LIQUIDATION_LOGIC = getAddress("0x88dF535473C5adf1f57789734A05E555F7Deb8DB");

export const AAVE_V4_ETHEREUM: Target[] = [
  t("AccessManagerEnumerable", "0x08aE3BE30958cDd1847ec58fFfd4C451a87fDF01", "out-aave:AccessManagerEnumerable.sol:AccessManagerEnumerable"),
  t("HubConfigurator", "0x1F0753480bB03EaA00863224602267B7E0525C3d", "out-aave:HubConfigurator.sol:HubConfigurator"),
  t("SpokeConfigurator", "0x9BFFf48BFb5A7AE70c348d4d4cb97E8DEFa5389a", "out-aave:SpokeConfigurator.sol:SpokeConfigurator"),
  t("TreasurySpoke", "0xB9B0b8616f6Bf6841972a52058132BE08d723155", "out-aave:TreasurySpokeInstance.sol:TreasurySpokeInstance", true),
  t("LiquidationLogic", LIQUIDATION_LOGIC, "out-aave:LiquidationLogic.sol:LiquidationLogic"),
  ...Object.entries({
    Core: "0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9", Plus: "0x06002e9c4412CB7814a791eA3666D905871E536A",
    Prime: "0x943827DCA022D0F354a8a8c332dA1e5Eb9f9F931", GlobalDollar: "0x62d63197660c080236193CA60b70E49A08E90368",
  }).map(([n, a]) => t(`${n} Hub`, a, HUB, true)),
  ...Object.entries({
    Bluechip: "0x973a023A77420ba610f06b3858aD991Df6d85A08", EthenaCorrelated: "0x58131E79531caB1d52301228d1f7b842F26B9649",
    EthenaEcosystem: "0xba1B3D55D249692b669A164024A838309B7508AF", Forex: "0xD8B93635b8C6d0fF98CbE90b5988E3F2d1Cd9da1",
    Gold: "0x65407b940966954b23dfA3caA5C0702bB42984DC", LombardBtc: "0x7EC68b5695e803e98a21a9A05d744F28b0a7753D",
    Main: "0x94e7A5dCbE816e498b89aB752661904E2F56c485", PaxgGold: "0xAD75cE6354f87F3135cE10621d385d8D1e2562C2",
    UsdgPendle: "0x956d8e0A89cfa3744428C4641b5a53B56167a7f9", EtherFi: "0xbF10BDfE177dE0336aFD7fcCF80A904E15386219",
    Kelp: "0x3131FE68C4722e726fe6B2819ED68e514395B9a4", Lido: "0xe1900480ac69f0B296841Cd01cC37546d92F35Cd",
    PaxgPaxos: "0x115aF1C2db26cD8ECa3f29055E4E424AF4edF616", UsdgMaple: "0x774b9655413c34809c1f1b16b654465A89EBE989",
  }).map(([n, a]) => t(`${n} Spoke`, a, SPOKE, true)),
  ...[
    "0x0083421fd178749af2201ddA5A7C3feB5790B80c", "0x198Cac7f54FFc7d709Ac0FEc4B6454CE73e21D3D", "0x37C316996C714Bf906743071e04E62220b3271ac",
    "0x47a7cC7Fd47aCed15087a8b6e0ACFddCD63C811A", "0x664D73b6C3591333Fd79510f7ce9ef81228824F5", "0x692cD2F7653680aFf316Ac309ce825FCF573B7Ee",
    "0x6b3800e96Bb4AA38a879b2c143B6E2f5f2687b77", "0x8CEcC12b23ED45EC2A9b9EB57EA6974c0cae850B", "0x99B2B6CEa9C3D2fd8F4d90f86741C44B212a6127",
    "0x9b91a0943CADf554742E8Fb358B1cC4ae4F85F01", "0xB3CE6E7b6d389a66eA4a3777bA07219d00FB3a9D", "0xc390dbe9fc00D6db73C52d375642b47008C33c90",
    "0xd8B153FaAA8f2b1bC774916FEd333A4F3dE48792", "0xdA1266a7b8620819dAE3F8bd6B546Da36e505bB8",
  ].map((a) => t("AaveOracle", a, ORACLE)),
  ...[
    "0x31280650661b8443723fa9739b3A164E3696af48", "0xAD88791B0F81D1FA242f637eB05bee0cbc53fe2f",
    "0xD7eC225DC053151100A0ef47b94a77AAD9C413b7", "0xDCd924047a4bDBFef9CCDDe845E5D45373Ad276D",
  ].map((a) => t("AssetInterestRateStrategy", a, IR)),
];

/** Every target's runtime code (and for proxies the proxy, its ProxyAdmin and its implementation) against the build. */
export async function verifyUpstream(client: PublicClient, contractsDir: string, targets = AAVE_V4_ETHEREUM): Promise<Check[]> {
  const checks: Check[] = [];
  const add = (name: string, ok: boolean | "pending", detail: string) =>
    checks.push({ name, outcome: ok === "pending" ? "pending" : ok ? "pass" : "fail", detail });
  if ((await client.getChainId()) !== 1) throw new Error("upstream check reads Ethereum mainnet");

  const compare = async (label: string, address: Address, artifact: string) => {
    const ref = upstreamRuntime(contractsDir, artifact);
    if (!ref) return add(label, "pending", `${artifact} not built (forge build --profile aave)`);
    const live = ((await client.getCode({ address })) ?? "0x").slice(2).toLowerCase();
    if (live.length !== ref.code.length) return add(label, false, `${address}: ${live.length / 2} bytes live, ${ref.code.length / 2} built`);
    add(label, mask(live, ref.spans) === mask(ref.code, ref.spans), `${address}, ${ref.spans.length} positions masked`);
    const linked = new Set(ref.links.map((l) => getAddress(`0x${live.slice(l.start * 2, (l.start + 20) * 2)}`)));
    if (linked.size > 0) add(`${label} links LiquidationLogic`, linked.size === 1 && linked.has(LIQUIDATION_LOGIC), [...linked].join(", "));
  };

  for (const x of targets) {
    if (!x.proxy) {
      await compare(x.label, x.address, x.artifact);
      continue;
    }
    await compare(`${x.label} proxy`, x.address, PROXY);
    const admin = await client.getStorageAt({ address: x.address, slot: ADMIN_SLOT });
    if (admin && BigInt(admin) !== 0n) await compare(`${x.label} ProxyAdmin`, getAddress(`0x${admin.slice(-40)}`), PROXY_ADMIN);
    const impl = await implementationOf(client, x.address);
    if (!impl) add(`${x.label} implementation`, false, "ERC-1967 implementation slot is zero");
    else await compare(`${x.label} implementation`, impl, x.artifact);
  }
  return checks;
}
