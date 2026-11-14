# Checklist: UniswapV3Integration

Spec pages: 02-lp-vault.md, 19-amm-integration-interface.md, 20-uniswap-v3-integration.md. CVL specs: UniswapV3Integration.spec, LPVault.spec.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (106: 0 verified, 0 failed, 78 not run, 28 unlinked)

- [~] `REQ-VAULT-001` (02-lp-vault.md:83) Every LPVault MUST be deployed as a non-upgradeable contract: no proxy, no `delegatecall`, no `selfdestruct`,  — TEST-108
- [~] `REQ-VAULT-002` (02-lp-vault.md:84) An LPVault MUST take every address it calls from its constructor immutables and MUST hold no Hub, Spoke, vault — TEST-108
- [ ] `REQ-VAULT-003` (02-lp-vault.md:85) An LPVault MUST take custody of a position for a record only through `receivePosition`, called by Collateraliz — TEST-010, TEST-015 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-VAULT-004` (02-lp-vault.md:86) An LPVault MUST make every state-changing call on its AMM protocol's position contracts, pools and AMM vaults  — TEST-021, TEST-291
- [ ] `REQ-VAULT-005` (02-lp-vault.md:87) An LPVault MUST NOT have a pause of its own and MUST NOT read any Avana pause state, breaker, address freeze,  — TEST-162 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-174` (02-lp-vault.md:88) Each chain MUST have at most one LPVault per AMM protocol, registered write-once in the VaultTokenFactory unde — TEST-024 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-VAULT-166` (02-lp-vault.md:92) `bindMarket(marketId, pool, poolId, shape, integrationData)` MUST behave per [2.19](19-amm-integration-interfa — TEST-264, TEST-265
- [~] `REQ-VAULT-167` (02-lp-vault.md:93) `receivePosition(marketId, owner, positionKey)` MUST behave per `REQ-AMM-CORE-005` and `REQ-AMM-CORE-006`: it  — TEST-010
- [~] `REQ-VAULT-168` (02-lp-vault.md:94) `returnPosition(positionKey)` MUST behave per `REQ-AMM-CORE-007`: it deletes the custody entry before the posi — TEST-016
- [~] `REQ-VAULT-169` (02-lp-vault.md:95) `unwind(positionKey, units, minAmounts, recipient)` MUST behave per `REQ-AMM-CORE-008`: it reverts with `Inval — TEST-058
- [~] `REQ-VAULT-170` (02-lp-vault.md:96) `releaseToDepositor(positionKey, units, minAmounts)` MUST behave per `REQ-AMM-CORE-008`, sending the principal — TEST-237
- [~] `REQ-VAULT-171` (02-lp-vault.md:97) `unitsOf(positionKey)` MUST revert with `NotInCustody` without a custody entry and otherwise return the positi — TEST-222
- [~] `REQ-VAULT-150` (02-lp-vault.md:98) An LPVault MUST NOT acquire the Lock: it is not a Lock member, and the Lock's members are only the AaveAdapter — TEST-011, TEST-017, TEST-108, TEST-222
- [~] `REQ-VAULT-151` (02-lp-vault.md:99) `depositorOf`, `marketOfPosition`, `isInCustody` and `unitsOf` MUST revert with `Locked` while the Lock is hel — TEST-222
- [ ] `REQ-VAULT-152` (02-lp-vault.md:100) At the end of every transaction, `depositorOf(positionKey) != address(0)` if and only if the LPVault holds tha — TEST-015, TEST-016 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-VAULT-153` (02-lp-vault.md:101) Upstream errors from the AMM protocol's contracts, the pool tokens and the Lock MUST pass through unchanged; L — TEST-011
- [~] `REQ-VAULT-154` (02-lp-vault.md:102) An LPVault MUST follow checks-effects-interactions: `depositorOf` and `marketOfPosition` are written before cu — TEST-010, TEST-080
- [~] `REQ-VAULT-155` (02-lp-vault.md:103) The constructor MUST fix `INTEGRATION_ID`, `COLLATERALIZATION`, `MARKET_REGISTRY`, `LOCK`, `TIMELOCK` and the  — TEST-108
- [ ] `REQ-VAULT-175` (02-lp-vault.md:104) An LPVault whose AMM protocol pays native ETH MUST accept ETH only while the Lock is held and only from that A — TEST-080 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-039` (02-lp-vault.md:108) An LPVault MUST NOT mint, burn or hold vault tokens: the AaveAdapter is the only minter and burner of every va — TEST-162, TEST-189 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-040` (02-lp-vault.md:109) An LPVault MUST NOT call any vault-token function and is never granted a vault-token allowance; the units that — TEST-162 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-041` (02-lp-vault.md:110) A withdrawal burns from the proxy and a seizure or pending settlement burns from LPVaultSwap (`burnSeized`), b — TEST-162 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-044` (02-lp-vault.md:111) No vault token MUST ever be held by an LPVault: it is not an allowed recipient of any vault token ([2.4](04-va — TEST-189 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-045` (02-lp-vault.md:112) Because vault tokens cannot reach an LPVault, none is ever credited, debited or moved by it; the LPVault has n — TEST-162, TEST-189 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-VAULT-064` (02-lp-vault.md:116) `collectFees(positionKey, depositor)` MUST revert with `NotCollateralization` unless `msg.sender == COLLATERAL — TEST-017, TEST-091
- [~] `REQ-VAULT-172` (02-lp-vault.md:117) `collectFees` MUST change no unit of the position, mint, burn or change no counter, and pay every fee and ever — TEST-017
- [~] `REQ-VAULT-066` (02-lp-vault.md:118) Fee collection MUST NOT read the RiskModule, the MarketRegistry, the ParameterStore, a pause state, a breaker, — TEST-017
- [~] `REQ-VAULT-067` (02-lp-vault.md:119) Because `collectFees` and every `unwind` and `releaseToDepositor` run under the Lock, and each removal perform — TEST-058, TEST-091, TEST-222
- [~] `REQ-VAULT-077` (02-lp-vault.md:123) Units added to a custodied position by anyone (an NFT's `increaseLiquidity`) MUST NOT be credited, minted or c — TEST-016, TEST-238
- [ ] `REQ-VAULT-165` (02-lp-vault.md:127) `returnStray(positionKey, recipient)` MUST revert with `NotTimelock` unless `msg.sender == TIMELOCK`, with `Lo — TEST-015 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-081` (02-lp-vault.md:128) The recipient MUST be an address governance has established off-chain as the position's rightful owner; the LP — TEST-166 (only excluded checks: tag on a test named for another row)
- [ ] `REQ-VAULT-082` (02-lp-vault.md:129) The only delay on a stray return MUST be the AvanaTimelock's normal delay (`normalDelay()`, 5 days at launch,  — TEST-166 (only excluded checks: tag on a test named for another row)
- [ ] `REQ-VAULT-083` (02-lp-vault.md:130) Because nothing is reserved when the operation is scheduled, `returnStray` MUST evaluate the stray condition o — TEST-015 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-084` (02-lp-vault.md:131) A scheduled stray return MUST be cancellable through the AvanaTimelock's `cancel` by any `CANCELLER_ROLE` hold — TEST-166 (only excluded checks: tag on a test named for another row)
- [~] `REQ-VAULT-085` (02-lp-vault.md:132) An LPVault MUST NOT have any sweep or rescue function for ERC-20 tokens, vault tokens, ETH or positions of oth — TEST-016, TEST-080, TEST-108
- [ ] `REQ-VAULT-093` (02-lp-vault.md:174) An LPVault MUST NOT take custody of a position for a record except through `receivePosition` from Collateraliz — TEST-015, TEST-016 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-VAULT-094` (02-lp-vault.md:175) An LPVault MUST NOT send a position with a `depositorOf` entry to any address other than that depositor, and M — TEST-015, TEST-016
- [~] `REQ-VAULT-095` (02-lp-vault.md:176) An LPVault MUST NOT reduce a position's units except in `unwind` and `releaseToDepositor` called by Collateral — TEST-016, TEST-058, TEST-074, TEST-291
- [ ] `REQ-VAULT-096` (02-lp-vault.md:177) An LPVault MUST NOT mint, burn, transfer or approve vault tokens; it holds no vault-token binding. (Source: Q- — TEST-162 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-VAULT-097` (02-lp-vault.md:178) An LPVault MUST NOT expose a generic call, `delegatecall`, multicall, ERC-1271 or arbitrary-target function, M — TEST-021, TEST-108, TEST-291
- [ ] `REQ-VAULT-098` (02-lp-vault.md:179) Fee collection and an LPVault's custody functions MUST NOT call any upgradeable Avana contract, and accept ins — TEST-162 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-VAULT-099` (02-lp-vault.md:180) An LPVault MUST NOT accept a caller-supplied recipient for a position with a depositor of record or for fees;  — TEST-237
- [~] `REQ-VAULT-101` (02-lp-vault.md:186) `receivePosition` for a position the named owner does not own, or naming the LPVault itself as owner | Reverts — TEST-011
- [~] `REQ-VAULT-120` (02-lp-vault.md:187) `collectFees` for a position not in custody for a record, or on an AMM protocol whose fees compound | Reverts  — TEST-017, TEST-091
- [ ] `REQ-VAULT-122` (02-lp-vault.md:188) `returnStray` for a position the LPVault does not hold or that has a depositor of record; recipient zero or th — TEST-015 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-123` (02-lp-vault.md:189) `returnStray` called by any address other than the AvanaTimelock, including a direct call by a governance sign — TEST-015 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-VAULT-126` (02-lp-vault.md:190) The AMM protocol, the pool or a pool token reverts during `collectFees` (pool broken, pool inside a callback,  — TEST-017
- [~] `REQ-VAULT-156` (02-lp-vault.md:191) A custody, unwind or fee function called by an address other than Collateralization, or `bindMarket` by an add — TEST-011, TEST-016, TEST-017, TEST-264, TEST-265
- [~] `REQ-VAULT-157` (02-lp-vault.md:192) A custody, unwind or fee function called while the Lock is not held | Reverts with `LockNotHeld` (Source: Q-14 — TEST-011, TEST-016, TEST-017
- [~] `REQ-VAULT-158` (02-lp-vault.md:193) `returnPosition`, `unwind`, `releaseToDepositor`, `unitsOf` or `collectFees` for a position not in custody for — TEST-016
- [~] `REQ-VAULT-159` (02-lp-vault.md:194) `unwind` with recipient zero or the LPVault | Reverts with `InvalidRecipient` (Source: Q-224) — TEST-058
- [~] `REQ-VAULT-160` (02-lp-vault.md:195) A custody view called while the Lock is held, by an address other than Collateralization | Reverts with `Locke — TEST-222
- [~] `REQ-VAULT-163` (02-lp-vault.md:196) `releaseToDepositor`'s removal returns less than a depositor minimum | The AMM protocol's slippage error passe — TEST-237
- [ ] `REQ-VAULT-164` (02-lp-vault.md:197) A pool token charges a transfer fee on a payout | No LPVault check fails: the LPVault reports the AMM protocol — TEST-080 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-VAULT-173` (02-lp-vault.md:198) `receivePosition` for a position whose pool or shape differs from the market's, or while the pool is mid-opera — TEST-011
- [~] `REQ-AMM-CORE-001` (19-amm-integration-interface.md:67) Every AMM integration MUST implement the functions above with these signatures, and the AMM-neutral core MUST  — PROP-099, TEST-024, TEST-108
- [~] `REQ-AMM-CORE-002` (19-amm-integration-interface.md:68) Each chain MUST have at most one LPVault per AMM protocol, registered write-once in the VaultTokenFactory as ` — TEST-058, TEST-108, TEST-279
- [~] `REQ-AMM-CORE-003` (19-amm-integration-interface.md:69) `bindMarket(marketId, pool, poolId, shape, integrationData)` MUST revert with `NotMarketRegistry` unless `msg. — TEST-264, TEST-265, TEST-279
- [~] `REQ-AMM-CORE-004` (19-amm-integration-interface.md:70) A market MUST have between 2 and `MAX_POOL_TOKENS = 8` tokens, each an ERC-20 with no transfer hook, no rebasi — TEST-264, TEST-265
- [~] `REQ-AMM-CORE-005` (19-amm-integration-interface.md:71) `receivePosition(marketId, owner, positionKey)` MUST revert with `NotCollateralization` unless `msg.sender ==  — TEST-010, TEST-011, TEST-265, TEST-266
- [~] `REQ-AMM-CORE-006` (19-amm-integration-interface.md:72) **Exact shape at pledge (`AMMN-RT-01`).** `receivePosition` MUST revert with `PoolMismatch` unless the positio — PROP-083, TEST-010, TEST-011
- [~] `REQ-AMM-CORE-007` (19-amm-integration-interface.md:73) `returnPosition(positionKey)` MUST revert with `NotCollateralization` unless `msg.sender == COLLATERALIZATION` — TEST-016, TEST-056, TEST-208, TEST-237
- [~] `REQ-AMM-CORE-008` (19-amm-integration-interface.md:74) `unwind(positionKey, units, minAmounts, recipient)` and `releaseToDepositor(positionKey, units, minAmounts)` M — TEST-058, TEST-264, TEST-265
- [~] `REQ-AMM-CORE-009` (19-amm-integration-interface.md:75) `unitsOf(positionKey)` MUST return the position's live units in the AMM protocol and revert with `NotInCustody — TEST-016, TEST-108, TEST-222, TEST-264, TEST-265
- [~] `REQ-AMM-CORE-010` (19-amm-integration-interface.md:76) **Fees.** Where the AMM protocol keeps fees apart from principal (`capabilities().feeMode == Separate`: Uniswa — TEST-017, TEST-091, TEST-264
- [~] `REQ-AMM-CORE-011` (19-amm-integration-interface.md:77) **Top-up hook.** Collateralization's `recredit` takes a `bytes topUp` argument and calls `topUpPosition` only  — TEST-017, TEST-238
- [~] `REQ-AMM-CORE-012` (19-amm-integration-interface.md:78) `composition(marketId, units, prices)` MUST compute the amounts per `SPEC-AMM-CORE-001` from `prices`, `units` — TEST-264, TEST-266, TEST-279
- [~] `REQ-AMM-CORE-013` (19-amm-integration-interface.md:79) `riskMetadata(marketId, positionKey)` MUST report `inRange` from the pool's current price against the market's — TEST-264, TEST-265
- [~] `REQ-AMM-CORE-014` (19-amm-integration-interface.md:80) **Quote-change cap.** The LPOracle implementation of every AMM protocol MUST cap the change of its per-unit qu — TEST-219, TEST-264, TEST-283
- [ ] `REQ-AMM-CORE-015` (19-amm-integration-interface.md:81) **Unwind size.** A market MUST NOT be listed unless the gas of its worst-case seizure, `seizureBaseGas + MAX_R — checked outside contracts/: a listing measurement: the worst-case seizure gas of a market is measured on a fork of its chain at listing; the local bound G(16) <= 5.15M is TEST-123 (LPVaultSwap.Liquidation.gas)
- [~] `SPEC-AMM-CORE-001` (19-amm-integration-interface.md:87) **Fair composition.** For a market `m`, a price vector `p` and `u` units: `(a_1 … a_n, exact) = composition(m, — TEST-037, TEST-279
- [~] `SPEC-AMM-CORE-002` (19-amm-integration-interface.md:88) **Keys.** `marketKey = keccak256(abi.encode(block.chainid, integrationId, pool, poolId, shape.kind, shape.tick — PROP-083, TEST-024, TEST-108, TEST-265
- [~] `REQ-AMM-CORE-016` (19-amm-integration-interface.md:120) A position's pool or shape differs from the market's in any field, including a range one tick spacing wider or — PROP-083, TEST-011
- [~] `REQ-AMM-CORE-017` (19-amm-integration-interface.md:121) `bindMarket` for a pool that does not derive from the pinned factory, a misaligned or out-of-bounds shape, few — TEST-264, TEST-265
- [~] `REQ-AMM-CORE-018` (19-amm-integration-interface.md:122) The AMM protocol reports the pool mid-operation during custody, removal or a quote | Reverts with `PoolLocked` — TEST-011
- [ ] `REQ-AMM-CORE-019` (19-amm-integration-interface.md:123) `collectFees` on an integration whose fees compound | Reverts with `FeesRolledIn` (Source: Q-297) — TEST-017 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-AMM-V3-001` (20-uniswap-v3-integration.md:46) The Uniswap v3 LPVault MUST take `NFPM` and `FACTORY` from its constructor and revert deployment with `Invalid — TEST-108, TEST-264
- [~] `REQ-AMM-V3-002` (20-uniswap-v3-integration.md:47) `bindMarket(marketId, pool, bytes32(0), PositionShape(TickRange, tickLower, tickUpper), integrationData)` MUST — TEST-264
- [~] `REQ-AMM-V3-003` (20-uniswap-v3-integration.md:48) Every read of `pool.slot0()` MUST decode the Uniswap v3 layout of 7 fields, `(uint160 sqrtPriceX96, int24 tick — TEST-011
- [ ] `REQ-AMM-V3-004` (20-uniswap-v3-integration.md:49) The Uniswap v3 LPVault MUST make every state-changing NFPM call on pledged NFTs (`transferFrom`, `decreaseLiqu — TEST-021 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `REQ-AMM-V3-005` (20-uniswap-v3-integration.md:50) `composition` MUST follow `SPEC-AMM-V3-001` and read no pool state: the price input is the oracle price vector — TEST-217, TEST-279
- [~] `REQ-AMM-V3-006` (20-uniswap-v3-integration.md:51) `riskMetadata(marketId, positionKey)` MUST report `inRange` as `tickLower ≤ slot0().tick < tickUpper`, `readSa — TEST-264, TEST-279
- [~] `REQ-AMM-V3-007` (20-uniswap-v3-integration.md:52) The Uniswap v3 liquidity bound MUST hold for every market: credited liquidity on one range is at most `maxLiqu — TEST-279
- [ ] `REQ-AMM-V3-012` (20-uniswap-v3-integration.md:53) The Uniswap v3 LPVault MUST take the chain's minimum block interval `BLOCK_TIME` (seconds) from its constructo
- [~] `REQ-VAULT-147` (20-uniswap-v3-integration.md:57) The Uniswap v3 `receivePosition(marketId, owner, positionKey)`, with `tokenId = uint256(positionKey)`, MUST ru — PROP-083, TEST-010, TEST-011, TEST-116, TEST-265
- [~] `REQ-VAULT-148` (20-uniswap-v3-integration.md:58) The Uniswap v3 `returnPosition(positionKey)` MUST revert with `NotCollateralization`, `LockNotHeld` or `NotInC — TEST-016
- [~] `REQ-VAULT-149` (20-uniswap-v3-integration.md:59) The Uniswap v3 `unwind(positionKey, units, minAmounts, recipient)` MUST pass the checks of `REQ-AMM-CORE-008`  — TEST-058, TEST-116, TEST-265
- [~] `REQ-VAULT-161` (20-uniswap-v3-integration.md:60) The Uniswap v3 `releaseToDepositor(positionKey, units, minAmounts)` MUST pass the checks of `REQ-AMM-CORE-008` — TEST-237
- [~] `REQ-VAULT-162` (20-uniswap-v3-integration.md:61) The Uniswap v3 `unitsOf(positionKey)` MUST revert with `NotInCustody` without a custody entry and otherwise re — TEST-016, TEST-222, TEST-291
- [~] `REQ-VAULT-065` (20-uniswap-v3-integration.md:62) The Uniswap v3 `collectFees(positionKey, depositor)` MUST require `depositor == depositorOf(positionKey)` (`No — TEST-017, TEST-091
- [~] `REQ-VAULT-008` (20-uniswap-v3-integration.md:66) The Uniswap v3 `receivePosition` MUST read `(token0, token1, fee, tickLower, tickUpper)` from `NFPM.positions( — PROP-083, TEST-011
- [~] `REQ-VAULT-009` (20-uniswap-v3-integration.md:67) The Uniswap v3 `receivePosition` MUST revert with `RangeMismatch(tickLower, tickUpper)` unless `tickLower == m — PROP-083, TEST-011
- [~] `REQ-VAULT-011` (20-uniswap-v3-integration.md:68) The borrower MUST grant the per-token `NFPM.approve(LPVault, tokenId)` or an NFPM `permit` before a pledge; ap — TEST-010
- [~] `REQ-VAULT-057` (20-uniswap-v3-integration.md:72) For each record debited for a seizure with debit `take > 0`, the Uniswap v3 removal MUST call `NFPM.decreaseLi — TEST-058
- [~] `REQ-VAULT-058` (20-uniswap-v3-integration.md:73) Immediately after the `decreaseLiquidity`, the LPVault MUST call `NFPM.collect({tokenId, recipient, amount0Max — TEST-058, TEST-091, TEST-177
- [ ] `REQ-VAULT-078` (20-uniswap-v3-integration.md:77) `onERC721Received` MUST revert with `UnsupportedNft` unless `msg.sender == NFPM`; for the canonical NFPM it MU — TEST-015 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-079` (20-uniswap-v3-integration.md:78) A stray NFT is a canonical-NFPM token with `NFPM.ownerOf(tokenId) == address(this)` and no custody entry for i — TEST-015 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `REQ-VAULT-080` (20-uniswap-v3-integration.md:79) The Uniswap v3 `returnStray(bytes32(tokenId), recipient)` MUST pass the checks of [2.2](02-lp-vault.md) `REQ-V — TEST-015 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `SPEC-BACK-001` (20-uniswap-v3-integration.md:85) **Exact range check.** With `s = pool.tickSpacing()`, `MIN_TICK = −887272`, `MAX_TICK = 887272`, and `%` the s — TEST-264, TEST-265, TEST-279
- [~] `SPEC-BACK-008` (20-uniswap-v3-integration.md:86) **Principal-capped collect** (executed by `unwind` and `releaseToDepositor`). `(a0, a1) = NFPM.decreaseLiquidi — TEST-058, TEST-074, TEST-091, TEST-116, TEST-177, TEST-237, TEST-265
- [~] `SPEC-AMM-V3-001` (20-uniswap-v3-integration.md:87) **Composition at the clamped oracle price.** The floored amounts here are exactly those of [2.10](10-lp-oracle — PROP-083, TEST-037, TEST-217, TEST-266, TEST-279
- [~] `REQ-VAULT-124` (20-uniswap-v3-integration.md:106) `onERC721Received` from any contract other than `NFPM` | Reverts with `UnsupportedNft` (Source: Q-144) — TEST-015, TEST-265
- [~] `REQ-AMM-V3-008` (20-uniswap-v3-integration.md:107) `bindMarket` for a pool not deployed by `FACTORY` with the canonical init code, a non-standard tick spacing, o — TEST-264
- [~] `REQ-AMM-V3-009` (20-uniswap-v3-integration.md:108) A pledged NFT's derived pool or ticks differ from the market's | The LPVault reverts with `PoolMismatch` or `R — TEST-011
- [~] `REQ-AMM-V3-010` (20-uniswap-v3-integration.md:109) `slot0().unlocked == false` during custody, removal or a live-liquidity read under the Lock | Reverts with `Po — TEST-011, TEST-058
- [~] `REQ-AMM-V3-011` (20-uniswap-v3-integration.md:110) The NFPM's `decreaseLiquidity` in `releaseToDepositor` returns less than a minimum | The NFPM's `Price slippag — TEST-237

## TEST rows (43: 0 verified, 0 failed, 21 not run, 22 unlinked)

- [~] `TEST-010` [unit] Pledge happy path: the NFT owner approves the LPVault for one `positionKey` and calls `AaveAdapter.pledge(mark
- [~] `TEST-011` [unit] Pledge rejections: a caller that does not own the NFT reverts `NotTokenOwner` in the LPVault, including a per-
- [ ] `TEST-015` [unit] Stray NFTs: an NFT sent to the LPVault outside a pledge is not credited and cannot be pledged; `onERC721Receiv (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `TEST-016` [unit] Donations: a third party's `increaseLiquidity` on a pledged NFT raises live liquidity only; credited units in 
- [~] `TEST-017` [unit] Fee collection: only the depositor of record can collect (`NotDepositor` otherwise); Collateralization, under 
- [ ] `TEST-018` [unit] Debt-free withdrawal: `AaveAdapter.withdraw(spoke, vaultToken, positionKey, units, deadline, minHealthFactor)` (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-020` [unit] Zero-credit record: after a full seizure the record stays open with 0 credited units; it cannot be debited or  (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-021` [unit] Position-manager approvals: the LPVault never calls `approve` or `setApprovalForAll`; a per-token approval set (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-150` [unit] Reconcile on withdrawal: a mock LPVaultSwap calls `liquidationCall` on the proxy and keeps the seized vault to (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-152` [unit] Pending settlement in Collateralization: only LPVaultSwap can call `Collateralization.settlePending(vaultToken (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-209` [unit] Withdrawal order: in `AaveAdapter.withdraw` the calls happen in this order, checked with `vm.expectCall` and a (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-047` [unit] Caller-funded liquidation, run for each debt reserve: `T.transferFrom(msg.sender, LPVaultSwap, debtToCover)` m (only excluded checks: tag on a test named for another row; uses a stand-in for UniswapV3Integration)
- [~] `TEST-058` [unit] Principal-capped collect: the integration's `unwind(positionKey, units, minAmounts, recipient)` of exactly `un
- [~] `TEST-060` [unit] Lock: every outer entry point of the AaveAdapter and LPVaultSwap acquires the immutable Lock, whose only membe
- [ ] `TEST-162` [unit] Pause-state readers: the AaveAdapter reads `MarketRegistry.pauseState()` and `pauseReason()` only in `pledge`, (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-166` [access-control] Single timelock delay for immutable contracts: `LPVault.returnStray` and `VaultTokenFactory.deployVaultToken`  (only excluded checks: tag on a test named for another row; uses a stand-in for UniswapV3Integration)
- [~] `TEST-074` [fuzz] Splitting: unwinding in many pieces never returns more tokens than one unwind; splitting a liquidation into ma
- [~] `TEST-217` [fuzz] Conservative LP value (`INV-078`): pool liquidity 10⁴ to 10¹⁵, Chainlink answers 0.01 to 2.0 per leg, pool spo
- [ ] `TEST-084` [invariant] Custody: each open Collateralization record's NFT is owned by the LPVault, `LPVault.depositorOf(positionKey)`  (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `TEST-091` [invariant] Fees: fee collection pays only the depositor of record; no liquidation reduces a record's owed fees.
- [ ] `TEST-099` [invariant] Exit liveness (`fail_on_revert` on): repay (by the borrower or any payer), fee collection, debt-free withdrawa (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-153` [invariant] Reconcile on exit: the handlers of `TEST-082` add hostile seize-and-keep, honest settlement of pending balance (only excluded checks: tag on a test named for another row; uses a stand-in for UniswapV3Integration)
- [ ] `TEST-193` [invariant] Exits and liquidation under every pause state and reason (`fail_on_revert` on for the live actions): a pause h (only excluded checks: tag on a test named for another row; uses a stand-in for UniswapV3Integration)
- [ ] `TEST-215` [invariant] Multi-actor invariant suite (Foundry invariant test with handlers, extending `TEST-082`). Actors: borrowers wi (only excluded checks: tag on a test named for another row)
- [ ] `TEST-218` [invariant] Withdrawal and liquidation cascades: N accounts (N up to 200) opened near HF 1.10 in two markets; outside LPs  (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-116` [fork] Each AMM integration on its chain's fork, through the AMM integration interface (`TEST-264` for Uniswap v3 on  (only excluded checks: tag on a test named for another row)
- [ ] `TEST-195` [fork] Exit inside the delay: the governance multisig schedules an AaveAdapter upgrade to a hostile implementation (n (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `TEST-221` [fork] Token edge cases. A fee-on-transfer mock pool token is rejected at listing; a fee switched on after listing on
- [ ] `TEST-223` [fork] LP journeys on one fork, end to end, with the Lens asserted at every step against execution: deposit → borrow  (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-130` [hostile] Hostile AaveAdapter (blast radius): once executed, the hostile Adapter can borrow every debt reserve against e (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `TEST-154` [hostile] Regression for Quint counterexample C-QNT-1: a hostile LPVaultSwap installed through the timelock seizes 315 u (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `TEST-222` [unit] Reentrancy through `collect` and `decreaseLiquidity`: pool tokens with transfer hooks (ERC-777 style) re-enter
- [~] `TEST-237` [unit] Partial removal: `removeLiquidity` burns exactly `units`, keeps the backing gap, leaves live liquidity ≥ credi
- [~] `TEST-238` [unit] Re-credit: only the record's depositor can re-credit; after a third party's `increaseLiquidity` the added liqu
- [~] `TEST-239` [unit] Repay with collateral: HF does not decrease while debt remains (`HealthFactorNotImproved`); no bonus or Avana 
- [~] `TEST-252` [unit] Small fixes: grace starts at the newest leg in use of the fresh price, never after `block.timestamp`, includin
- [~] `TEST-264` [fork] Uniswap v3 integration on the Ethereum fork, through the AMM integration interface: `receive` takes custody of
- [~] `TEST-265` [fork] Aerodrome Slipstream integration on the Base fork, through the same interface and the same assertions as `TEST
- [~] `TEST-266` [unit, fork] Spot-move invariance on local Uniswap v3 pools built from the pinned release and on both forks (Uniswap v3 and
- [~] `TEST-270` [access-control] Lock membership: the Lock's members are exactly the AaveAdapter and LPVaultSwap, fixed at construction; every 
- [~] `TEST-279` [unit] Exact range and clamp: a position on a listed pool whose range differs from the market's exact `[tickLower, ti
- [ ] `TEST-283` [unit] Readiness listing guards for AMM protocols beyond Uniswap v3 and Slipstream: a Uniswap v2 pricing that reads ` (only excluded checks: tag on a test named for another row)
- [~] `TEST-291` [unit] Slipstream exploit-shape regression (`ATTACK-003`, `ATTACK-008`): a position minted at the market's exact rang

## PROP rows (9: 5 verified, 0 failed, 4 not run, 0 unlinked)

- [~] `PROP-002` [Certora] For every open Collateralization record, the AMM integration's units of its `positionKey` are ≥ its credited u
- [x] `PROP-003` [Certora] At most one open record per `positionKey` (`Collateralization.recordIdOf`); `LPVault.returnStray` never moves  — Collateralization job 8a8379652a2f4faaacd36ef1e8a3c13a
- [~] `PROP-032` [Certora] Adapter `repay`, LPVault `collectFees`, Collateralization `releaseZeroCredit`, and an Adapter `withdraw` or `r
- [x] `PROP-034` [Certora] Every restricted selector of every upgradeable Avana contract (AaveAdapter, MarketRegistry, ParameterStore, Ri — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_034_setPokeMinGasNeedsApplicationAdmin
- [x] `PROP-037` [Certora] Lock: any Avana function reachable only from inside the fixed set reverts unless the Lock is held and `msg.sen — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock
- [~] `PROP-038` [Certora] `collectFees` transfers fees only to `depositorOf(positionKey)`; a position leaves its LPVault only through `r
- [x] `PROP-043` [SMTChecker] The immutable contracts (every LPVault, Collateralization, vault token, VaultTokenFactory, ProxyManager, Posit — Lock job 0f0bbe338f844d87ba9968713df8b185
- [x] `PROP-065` [Certora] Backing one-sided across the Adapter, Collateralization and LPVaultSwap: for every market and every reachable  — Collateralization job 8a8379652a2f4faaacd36ef1e8a3c13a
- [~] `PROP-083` [Halmos; Certora (`UniswapV3Integration.spec`, `SlipstreamIntegration.spec`)] Exact range and clamp: `receive` accepts a position only when its pool and `[tickLower, tickUpper]` equal its 

## INV (20: 8 verified, 0 failed, 8 not run, 4 unlinked)

- [~] `INV-002` For every open record `r`: `integration[r.integrationId].unitsOf(r.positionKey) ≥ r.credited`, where `unitsOf` — PROP-002, TEST-016, TEST-084, TEST-247, TEST-265, TEST-291
- [ ] `INV-003` For every market `m`, at the end of every transaction: `vaultToken[m].balanceOf(Hub) == Hub.getAddedAssets(ass — TEST-086, TEST-087, TEST-247 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [x] `INV-005` One position backs one record in one account: (a) custody is keyed by `(integrationId, positionKey)`: for ever — PROP-002, PROP-003, PROP-083, TEST-010, TEST-011, TEST-265, TEST-279, TEST-291 — Collateralization job 8a8379652a2f4faaacd36ef1e8a3c13a
- [~] `INV-006` `r.credited` is set at pledge by Collateralization to the position's units read through its AMM integration (` — TEST-010, TEST-015, TEST-016, TEST-080, TEST-084, TEST-186
- [~] `INV-007` The LPVault of each AMM protocol transfers a position out only (a) to `depositorOf(positionKey)`, by a transfe — PROP-003, PROP-038, TEST-015, TEST-130, TEST-291
- [x] `INV-058` Reconcile on exit. In `release` (withdrawal), `releasePartial` (partial removal), `releaseForDeleverage` (dele — PROP-045, PROP-051, TEST-020, TEST-150, TEST-151, TEST-153, TEST-154 — Collateralization job 8a8379652a2f4faaacd36ef1e8a3c13a
- [x] `INV-011` Transfer allowlist. A market's vault-token balances change only on these paths, and every other `transfer` and — PROP-008, PROP-055, TEST-022, TEST-087, TEST-189 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_008_movementsOnlyOnAllowedPaths
- [x] `INV-066` Backing across contracts. In every AaveAdapter `pledge` and `recredit`, the units minted equal the `credited`  — PROP-054, PROP-065, TEST-088, TEST-186, TEST-241 — Collateralization job 8a8379652a2f4faaacd36ef1e8a3c13a
- [x] `INV-088` Partial removal and re-credit. In every `removeLiquidity` the units burned from the proxy equal the record's d — PROP-054, PROP-065, TEST-237, TEST-238, TEST-241 — Collateralization job 8a8379652a2f4faaacd36ef1e8a3c13a
- [~] `INV-017` Collateralization and each LPVault obtain an AMM protocol's position manager and factory only from the LPVault — PROP-083, TEST-010, TEST-030, TEST-108, TEST-114, TEST-116, TEST-171, TEST-264, TEST-265
- [ ] `INV-018` Blast radius of upgradeable contracts. (a) AaveAdapter implementation faulty or hostile (one per chain, servin — TEST-031, TEST-107, TEST-130, TEST-133, TEST-195 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `INV-020` In a borrow of debt reserve `r`, `r`'s asset moves from `r`'s funding Hub (the CDP Spoke's home Hub, or anothe — TEST-027, TEST-106 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [x] `INV-021` At the end of every transaction: (a) every ERC-20 allowance an Avana contract granted during the transaction i — PROP-016, PROP-068, PROP-080, TEST-021, TEST-054, TEST-080, TEST-092, TEST-177, TEST-232 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_donationNeverForwarded
- [ ] `INV-022` Calldata built by `packages/protocol` asks a user for only two kinds of approval: an approval of exactly one p
- [~] `INV-044` The depositor of any open record, including one at 0 credited units, can collect fees with `AaveAdapter.collec — PROP-057, TEST-017, TEST-060, TEST-099, TEST-132, TEST-151, TEST-193
- [~] `INV-081` Stops never reach exits or liquidation. The application pause state and reason, the market and debt breakers a — PROP-066, TEST-218, TEST-228, TEST-229
- [~] `INV-052` The vault tokens, VaultTokenFactory, every LPVault (one per AMM protocol per chain), Collateralization (one pe — PROP-099, TEST-108, TEST-166
- [x] `INV-054` Every external state-changing entry point of the AaveAdapter and LPVaultSwap either acquires the Lock (outer c — PROP-037, PROP-075, TEST-046, TEST-060, TEST-179 — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock
- [~] `INV-067` Pause-state effects. In every application pause state and pause reason, the liquidation entry point `liquidate — PROP-057, PROP-066, TEST-029, TEST-053, TEST-099, TEST-193, TEST-229, TEST-243
- [x] `INV-091` The Lock has exactly two members: the chain's AaveAdapter and LPVaultSwap, fixed as immutables at the Lock's d — PROP-037, PROP-075, TEST-011, TEST-060, TEST-270 — Lock job 0f0bbe338f844d87ba9968713df8b185

## ATTACK (9: 0 verified, 0 failed, 5 not run, 4 unlinked)

- [~] `ATTACK-001` Duplicate LP Collateral Registration — TEST-010, TEST-011
- [~] `ATTACK-003` Pledge of a third party's NFT — TEST-010, TEST-011, TEST-291
- [ ] `ATTACK-006` Pledged or zero-credit NFT released through the stray-NFT return — TEST-015, TEST-016 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `ATTACK-007` Re-pledge during the release callback — TEST-060 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [~] `ATTACK-008` Operator rights over a pledged NFT — TEST-021, TEST-291
- [~] `ATTACK-015` Fee capture during partial settlement — TEST-058
- [~] `ATTACK-092` Cross-contract reentrancy during settlement — TEST-046, TEST-060, TEST-222
- [ ] `ATTACK-113` Theft or over-debit through the pending-settlement balance — TEST-152 (only excluded checks: uses a stand-in for UniswapV3Integration)
- [ ] `ATTACK-169` Lock that cannot admit vaults and ledgers added later — TEST-060 (only excluded checks: uses a stand-in for UniswapV3Integration)

## Cross-cutting TEST rows, every contract (17): see --uncovered

- `TEST-001` [environment] The Foundry workspace builds with solc 0.8.28 and EVM `cancun`, the same compiler as Aave V4; dependencies are
- `TEST-032` [access-control] Selector inventory: the external selectors of every deployed Avana contract are enumerated from bytecode and c
- `TEST-061` [unit] Events: every borrower and keeper action is one atomic call that emits the inventory events of its contracts, 
- `TEST-177` [unit] Zero-amount transfers skipped: with mock tokens that revert on a zero-amount `transfer` and `transferFrom`, ev
- `TEST-062` [access-control] Role map: every privileged selector of every Avana contract checks the role or the `TIMELOCK` address in the r
- `TEST-066` [access-control] Guardian powers: the Emergency Guardian (3-of-5) and the Aave Protocol Guardian hold `APPLICATION_PAUSE_GUARDI
- `TEST-080` [fuzz] Dust donations: sending 1 wei up to 10^6 wei of GHO, USDC, WETH, DAI, pool tokens or vault tokens (where the r
- `TEST-092` [invariant] Conservation: for every token (each debt asset, each pool token, each vault token), the sum of tracked balance
- `TEST-107` [invariant] Hostile suite: with the RiskModule, MarketRegistry, ParameterStore, LPOracle and LPVaultSwap replaced through 
- `TEST-108` [invariant] Structure and governance: immutables and runtime code hashes of the LPVault, Collateralization, vault tokens, 
- `TEST-212` [invariant] Timelock timing: handlers schedule normal, short and mixed batches (short-listed and normal calls in one batch
- `TEST-121` [fork] End-to-end lifecycle on one fork (Avana-deployed Aave V4 plus Ethereum Uniswap v3, Chainlink, GHO, the Aave V3
- `TEST-126` [fork] Emergency matrix: for every row of the matrix in [3.6](../03-operations/06-emergency-operations.md) (applicati
- `TEST-127` [fork] Halt deterioration and caps: with liquidation of an account stopped for the 48-hour incident window of `Q-192`
- `TEST-137` [deployment-check] Upgrade safety: every UUPS contract (AaveAdapter, MarketRegistry, ParameterStore, RiskModule, LPOracle, LPVaul
- `TEST-214` [deployment-check] Role snapshot: on every upgradeable Avana contract `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` are held only 
- `TEST-224` [deployment-check] Deployment simulation: `forge script` on the Ethereum fork and on the Base fork runs the chain's full deployme
