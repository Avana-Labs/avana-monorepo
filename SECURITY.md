# Security

Avana Labs takes reports of vulnerabilities in Avana seriously. This page says what to report, how, and what happens next.

**Status:** Avana is in an internal audit (an internal manual review and an automated review). There has been no external audit yet, and the bug bounty has not started; it will be announced. Details: [`docs/audit/README.md`](docs/audit/README.md#audit-status).

## Reporting a vulnerability

Email **support@avana.cc** with "Security" in the subject. It is the only channel for security reports. Do not open a public issue, pull request or discussion for a vulnerability.

Include:

- the affected contract, chain and address, or the file and commit;
- the impact: what an attacker gains or what a user loses, and under which conditions;
- steps or a proof of concept, ideally a Foundry test against a fork at a stated block;
- whether the issue is already public or being exploited.

Avana's safety overview is at [avana.cc/developers/safety](https://avana.cc/developers/safety).

## What happens next

| Step | Target |
|---|---|
| Acknowledgement of the report | 2 business days |
| First assessment: valid or not, severity | 5 business days |
| Fix or mitigation for a critical or high finding | as fast as the fix can be reviewed; a freeze or a removed debt reserve first where one stops the loss |
| Disclosure | coordinated with the reporter once the fix is deployed |

Avana's core contracts are immutable, so a fix to a deployed contract is a new release, deployed and listed through governance. Until it is live, the risk-reducing steps in code apply: the Joint Configuration Safe removes a debt reserve or a keeper at once (which stops new borrowing), the Aave Protocol Guardian or the Aave DAO freezes the affected Aave reserves, and the Aave DAO cancels any scheduled Avana change ([docs/governance/README.md](docs/governance/README.md#emergency-actions-in-code)). None of them stops repayment or liquidation.

## Scope

In scope: the contracts in [`contracts/src/`](contracts/src/) as deployed at the addresses of the verified manifests in `contracts/deployments/verified/` (empty until the first verified release; see [`contracts/deployments/README.md`](contracts/deployments/README.md)), the deployment and governance scripts, the calldata builders in [`packages/protocol/`](packages/protocol/), the keeper in [`services/keeper/`](services/keeper/), and the web app at [app.avana.cc](https://app.avana.cc).

Out of scope: third-party protocols Avana integrates with (the lending Hubs and Spokes, the flash-loan pool, the AMMs, the price feeds and the debt assets), except where Avana's use of them is the cause; findings that need control of the governance Safe, the Joint Configuration Safe or the Aave governance executor; and issues already known from the internal audit ([docs/audit/README.md](docs/audit/README.md)).

## Safe harbour

Avana Labs will not pursue legal action against anyone who, in good faith, finds and reports a vulnerability under this policy: who tests only on a fork or on a test deployment, never on mainnet funds that are not their own; who does not degrade the service or access other users' data; and who gives Avana Labs reasonable time to fix the issue before any public disclosure.
