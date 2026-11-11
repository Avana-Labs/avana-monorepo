# Security

Avana Labs takes reports of vulnerabilities in Avana seriously. This page says what to report, how, and what happens next.

## Reporting a vulnerability

Email **support@avana.cc** with "Security" in the subject. It is the only channel for security reports. Do not open a public issue, pull request or discussion for a vulnerability.

Include:

- the affected contract, chain and address, or the file and commit;
- the impact: what an attacker gains or what a user loses, and under which conditions;
- steps or a proof of concept, ideally a Foundry test against a fork at a stated block;
- whether the issue is already public or being exploited.

The bug bounty, with its scope, severity levels and rewards, is published at [avana.cc/developers/safety/bug-bounty](https://www.avana.cc/developers/safety/bug-bounty); that page is the only statement of its terms. Avana's safety overview is at [avana.cc/developers/safety](https://avana.cc/developers/safety).

## What happens next

| Step | Target |
|---|---|
| Acknowledgement of the report | 2 business days |
| First assessment: valid or not, severity | 5 business days |
| Fix or mitigation for a critical or high finding | as fast as the fix can be reviewed; an emergency pause or freeze first where one stops the loss |
| Disclosure | coordinated with the reporter once the fix is deployed |

A fix to a deployed contract follows the change process of the contract: an upgradeable contract is upgraded through its AvanaTimelock at the normal delay; a risk-reducing step (a pause of new activity, a freeze, a parameter lowered) can run at the short delay or directly by the Emergency Guardian ([governance/README.md](governance/README.md)). Exits and liquidation never depend on a pause, so a pause protects users without trapping funds.

## Scope

In scope: the contracts in [`contracts/src/`](contracts/src/) as deployed at the addresses of the verified manifests in [`deployments/verified/`](deployments/verified/), the deployment and governance scripts, the calldata builders in [`packages/protocol/`](packages/protocol/), the keeper in [`services/keeper/`](services/keeper/), and the web app at [app.avana.cc](https://app.avana.cc).

Out of scope: third-party protocols Avana integrates with (the lending Hubs and Spokes, the flash-loan pool, the AMMs, the price feeds and the debt assets), except where Avana's use of them is the cause; findings that need control of a governance Safe, the Emergency Guardian or the DAO governance executor; and issues already listed in [5.3 Audit Findings](spec/05-verification/03-audit-findings.md) or an external report.

## Safe harbour

Avana Labs will not pursue legal action against anyone who, in good faith, finds and reports a vulnerability under this policy: who tests only on a fork or on a test deployment, never on mainnet funds that are not their own; who does not degrade the service or access other users' data; and who gives Avana Labs reasonable time to fix the issue before any public disclosure.

## Audits

External audit and formal-verification reports, with the commit each one audited, are indexed in [`audit/external/`](audit/external/index.md). Avana's internal verification (tests, fuzzing, symbolic execution, formal proofs and static analysis) is described in [`audit/README.md`](audit/README.md).
