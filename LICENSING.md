# Avana Labs — Software Licensing Policy
Status: Approved Legal Counsel  
Licensor: Avana Labs  
License: Business Source License 1.1 (BUSL-1.1)  
Protection Period: Three years following Ethereum mainnet launch, subject to the applicable BUSL-1.1 maximum term  
Change License: MIT License  
Effective Date: November 1st, 2026  

## 1. Licensing Policy
Avana Labs makes its independently developed protocol software publicly available under the Business Source License 1.1 (BUSL-1.1).
This licensing framework is designed to promote transparency, independent security review, research, and ecosystem development while protecting the protocol against unauthorized production deployments during its initial development and adoption period.

The source code will remain publicly accessible for inspection, testing, auditing, modification, and non-production development in accordance with BUSL-1.1.
Production deployments require authorization from Avana Labs or another duly authorized licensing entity until the applicable Change Date.

## 2. Scope of Coverage
Subject to applicable third-party licenses and ownership rights, this policy is intended to cover original software developed and owned by Avana Labs, including:

* Protocol smart contracts: All contracts that are not Aave Labs owned, LP Vaults, vault-token adapters, collateral management, and borrowing infrastructure.
* Oracle and risk infrastructure: LP Oracle implementations, valuation libraries, risk modules, and collateral eligibility logic.
* Liquidation infrastructure: LPVaultSwap, liquidation adapters, settlement mechanisms, and protocol-developed execution contracts.
* Application software: Official Avana web applications, frontend interfaces, dashboards, and supporting backend services.
* Developer infrastructure: Proprietary SDKs, APIs, indexing software, deployment tooling, and other original software distributed by Avana Labs.

Third-party dependencies, externally licensed code, and materials subject to separate license terms remain governed by their respective licenses.
The Avana name, logos, trademarks, and other brand assets are not licensed under BUSL-1.1.

## 3. Production Use Restrictions
During the applicable BUSL protection period, third parties may not deploy or operate the BUSL-covered software in production without a separate written authorization from Avana Labs or another legally authorized rights holder.
This includes deploying unauthorized forks, modified versions, or derivative implementations incorporating protected Avana software on public blockchains with economically meaningful assets.
Non-production development, research, security auditing, testing, and modification remain permitted under the applicable BUSL-1.1 terms.
These restrictions apply to the licensed software and do not independently restrict third parties from developing original, independently implemented protocols.

## 4. License Conversion
Avana Labs intends for BUSL-covered software to transition automatically to the MIT License three years following the official Avana Ethereum mainnet launch.
Each licensed software version is subject to its applicable Change Date.
Following the Change Date, that version becomes available under the MIT License without requiring additional authorization for uses permitted by MIT.

## 5. Governance and Licensing Exceptions
Avana Labs may grant separate commercial licenses or written permissions authorizing specific production deployments before the applicable Change Date.
Avana governance may participate in decisions concerning licensing exemptions and early license conversion where such authority has been validly established and delegated.
Any licensing exception or early conversion must be documented through an authorized process and must not conflict with existing license grants or third-party rights.
No governance decision may independently override the rights of another copyright holder.

## 6. Third-Party Software and Aave Integration
Avana is an independently developed protocol designed to integrate with Aave v4 infrastructure.
Avana Labs' licensing policy does not modify, replace, or supersede the licenses governing Aave software or any other third-party components.
Any Aave-origin code included in Avana will comply with its applicable license, including any production deployment restrictions and authorization requirements.
Avana Labs cannot grant exemptions to third-party licensing obligations unless separately authorized by the relevant rights holder.

## 7. Legal Ownership and Enforcement
Avana Labs retains the copyrights and other intellectual property rights it owns in the covered software.
Avana Labs reserves the right to enforce applicable licensing restrictions and negotiate separate licensing agreements, subject to existing third-party rights and any valid governance or contractual delegations.
No trademark rights, implied endorsements, or rights to third-party intellectual property are granted through this policy.

© 2026 Avana Labs. All rights reserved.
Avana is an independent protocol integrating with Aave infrastructure and is not represented as an official Aave Labs product.

---

The BUSL-1.1 text and its parameters are in [`LICENSE`](LICENSE). Files under another licence, and every third-party component with its licence and required notices, are listed in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md), [`NOTICE`](NOTICE) and [`LICENSES/`](LICENSES/). Contribution terms are in [`CONTRIBUTING.md`](CONTRIBUTING.md).
