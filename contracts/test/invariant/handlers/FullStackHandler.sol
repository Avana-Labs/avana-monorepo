// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../../src/custody/collateralization/ICollateralization.sol";
import {AvanaTimelock} from "../../../src/governance/timelock/AvanaTimelock.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {IAaveAdapterErrors} from "../../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreTighten} from "../../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {IRiskModuleErrors} from "../../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {PledgeCounters} from "../../../src/types/PledgeCounters.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {ClTestToken} from "../../utils/fixtures/ClPoolFixture.sol";
import {FullStackLPVaultMock} from "../../utils/mocks/FullStackLPVaultMock.sol";
import {OracleFeedMock} from "../../utils/mocks/LPOracleMocks.sol";
import {LPVaultSwapMock} from "../../utils/mocks/LPVaultSwapMock.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice The real contracts and identities the full-stack handler drives.
struct FullStackWorld {
    IAaveAdapter adapter;
    MarketRegistry registry;
    IParameterStore store;
    AvanaTimelock timelock;
    ICollateralization coll;
    FullStackLPVaultMock lpVault;
    LPVaultSwapMock swap;
    IAaveV4Spoke spoke;
    address hub;
    address hubConfigurator;
    address aaveDao;
    address guardian;
    address governance;
    uint256[2] markets;
    address[2] vaultTokens;
    uint256[2] vtReserves;
    ClTestToken[2] debtAssets;
    uint256[2] debtReserves;
    uint256[2] debtAssetIds;
    address secondImplementation;
    uint32 integrationId;
}

/// @title FullStackHandler
/// @notice Actor handler of the full-stack invariants: three wallets pledge into two markets, borrow GHO and USDC,
/// repay (their own debt or a third party's), withdraw debt-free; the Emergency Guardian moves the Hub through every
/// pause state and reason on the real MarketRegistry; token prices move inside the USD band; LPVaultSwap liquidates any
/// account below HF 1; the Aave DAO cuts the CDP Spoke's draw cap below its drawn amount and anyone syncs it into the
/// registry's credit line; the timelock tightens a cap at the short delay and upgrades the AaveAdapter to a second
/// reviewed implementation at the normal delay; time passes with every feed republished.
/// @dev Each failed expectation increments a counter the invariants read: an exit (repay, debt-free withdrawal,
/// liquidation) that reverts for a pause, freeze or breaker; a borrow or no-debt pledge that succeeds while the Hub's
/// state forbids it; a borrow that leaves the Spoke's owed amount above its draw cap; a pledge worth less than
/// `minPledgeUsd` at the served price; a timelock operation that executed before its required delay.
contract FullStackHandler is CommonBase, StdUtils {
    FullStackWorld internal w;
    address[3] internal wallets;
    address internal payer;
    OracleFeedMock[] internal feeds;
    uint256 internal keyNonce;
    uint256 internal opNonce;

    mapping(address wallet => mapping(uint256 market => bytes32[] keys)) internal openKeys;
    mapping(address proxy => bytes32 codeHash) public proxyCodeHash;
    mapping(address proxy => address wallet) public proxyWallet;
    mapping(address proxy => uint256 market) public proxyMarket;
    address[] public proxies;

    uint256 public exitBlocked;
    uint256 public gateViolations;
    uint256 public drawCapViolations;
    uint256 public minPledgeViolations;
    uint256 public capViolations;
    uint256 public earlyExecutions;
    uint256 public pledges;
    uint256 public borrows;
    uint256 public repays;
    uint256 public withdrawals;
    uint256 public liquidations;
    uint256 public pauses;
    uint256 public upgrades;

    constructor(
        FullStackWorld memory world,
        address[3] memory wallets_,
        address payer_,
        OracleFeedMock[] memory feeds_
    ) {
        w = world;
        wallets = wallets_;
        payer = payer_;
        for (uint256 i = 0; i < feeds_.length; ++i) {
            feeds.push(feeds_[i]);
        }
    }

    // ─── Reads ───

    function proxyCount() external view returns (uint256) {
        return proxies.length;
    }

    function walletAt(
        uint256 i
    ) external view returns (address) {
        return wallets[i];
    }

    // ─── Actions ───

    function pledge(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 unitsSeed
    ) external {
        address wallet = wallets[walletSeed % 3];
        uint256 i = marketSeed % 2;
        uint256 market = w.markets[i];
        uint128 units = uint128(bound(unitsSeed, 1e6, 50_000e6));
        bytes32 key = keccak256(abi.encode("full-stack position", ++keyNonce));
        w.lpVault.mintPosition(key, wallet, market, units);
        address proxy = w.adapter.proxyOf(wallet, market);
        bool indebted = proxy != address(0) && _indebted(proxy);
        PauseState state = w.registry.pauseState(w.hub);
        uint256 value = uint256(units) * uint256(_price(i)) / 1e6;
        vm.prank(wallet);
        (bool ok,) = address(w.adapter)
            .call(abi.encodeCall(w.adapter.pledge, (market, PositionRef(w.integrationId, key), block.timestamp + 600)));
        if (!ok) return;
        ++pledges;
        if (state == PauseState.Frozen && !indebted) ++gateViolations;
        if (state == PauseState.Paused && w.registry.pauseReason(w.hub) == PauseReason.MintPathSuspect) {
            ++gateViolations;
        }
        if (value < w.store.minPledgeUsd(market)) ++minPledgeViolations;
        _checkCaps(i, wallet);
        openKeys[wallet][market].push(key);
        proxy = w.adapter.proxyOf(wallet, market);
        if (proxyWallet[proxy] == address(0)) {
            proxies.push(proxy);
            proxyWallet[proxy] = wallet;
            proxyMarket[proxy] = market;
            proxyCodeHash[proxy] = proxy.codehash;
        }
    }

    function borrow(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 reserveSeed,
        uint256 shareSeed
    ) external {
        address wallet = wallets[walletSeed % 3];
        uint256 market = w.markets[marketSeed % 2];
        address proxy = w.adapter.proxyOf(wallet, market);
        if (proxy == address(0)) return;
        uint256 r = reserveSeed % 2;
        // $1 to $3,000 of the asset ($1.00 each); a borrow beyond the account's room is refused by Aave or the RiskModule.
        uint256 amount = bound(shareSeed, 1, 3000) * 10 ** w.debtAssets[r].decimals();
        PauseState state = w.registry.pauseState(w.hub);
        uint256 nonce = w.adapter.borrowNonce(proxy);
        vm.prank(wallet);
        (bool ok,) = address(w.adapter)
            .call(
                abi.encodeCall(
                    w.adapter.borrow, (market, w.debtReserves[r], amount, wallet, block.timestamp + 600, 0, nonce)
                )
            );
        if (!ok) return;
        ++borrows;
        if (state != PauseState.None) ++gateViolations;
        IAaveV4Hub h = IAaveV4Hub(w.hub);
        uint256 owed = h.getSpokeTotalOwed(w.debtAssetIds[r], address(w.spoke));
        uint256 cap =
            uint256(h.getSpokeConfig(w.debtAssetIds[r], address(w.spoke)).drawCap) * 10 ** w.debtAssets[r].decimals();
        if (owed > cap) ++drawCapViolations;
    }

    function repay(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 reserveSeed,
        uint256 shareSeed
    ) external {
        address wallet = wallets[walletSeed % 3];
        uint256 market = w.markets[marketSeed % 2];
        address proxy = w.adapter.proxyOf(wallet, market);
        if (proxy == address(0)) return;
        uint256 r = reserveSeed % 2;
        uint256 owed = w.spoke.getUserTotalDebt(w.debtReserves[r], proxy);
        if (owed == 0) return;
        uint256 amount = owed * bound(shareSeed, 1, 100) / 100;
        if (amount == 0) return;
        address who = shareSeed % 2 == 0 ? wallet : payer;
        ClTestToken asset = w.debtAssets[r];
        asset.mint(who, amount);
        vm.prank(who);
        asset.approve(address(w.adapter), amount);
        vm.prank(who);
        (bool ok, bytes memory ret) = address(w.adapter)
            .call(
                abi.encodeCall(
                    w.adapter.repay, (wallet, market, w.debtReserves[r], amount, false, block.timestamp + 600)
                )
            );
        _exit(ok, ret);
        if (ok) ++repays;
    }

    function withdraw(
        uint256 walletSeed,
        uint256 marketSeed
    ) external {
        address wallet = wallets[walletSeed % 3];
        uint256 market = w.markets[marketSeed % 2];
        address proxy = w.adapter.proxyOf(wallet, market);
        bytes32[] storage keys = openKeys[wallet][market];
        if (proxy == address(0) || keys.length == 0 || _indebted(proxy)) return;
        bytes32 key = keys[keys.length - 1];
        uint128 units = w.coll.getRecord(w.coll.recordIdOf(w.integrationId, key)).credited;
        vm.prank(wallet);
        (bool ok, bytes memory ret) = address(w.adapter)
            .call(
                abi.encodeCall(
                    w.adapter.withdraw, (market, PositionRef(w.integrationId, key), units, block.timestamp + 600, 0)
                )
            );
        _exit(ok, ret);
        if (ok) {
            ++withdrawals;
            keys.pop();
        }
    }

    /// @notice LPVaultSwap liquidates `debtToCover` of the first account below HF 1 in the chosen market.
    function liquidate(
        uint256 seed
    ) external {
        for (uint256 j = 0; j < proxies.length; ++j) {
            address proxy = proxies[(seed + j) % proxies.length];
            if (w.spoke.getUserAccountData(proxy).healthFactor >= 1e18) continue;
            uint256 i = proxyMarket[proxy] == w.markets[0] ? 0 : 1;
            uint256 r = w.spoke.getUserTotalDebt(w.debtReserves[0], proxy) > 0 ? 0 : 1;
            uint256 owed = w.spoke.getUserTotalDebt(w.debtReserves[r], proxy);
            if (owed == 0) continue;
            (bool ok, bytes memory ret) = address(w.swap)
                .call(
                    abi.encodeCall(
                        w.swap.liquidate,
                        (
                            address(w.spoke),
                            w.markets[i],
                            w.vaultTokens[i],
                            w.vtReserves[i],
                            w.debtReserves[r],
                            proxy,
                            owed / 2 + 1,
                            2
                        )
                    )
                );
            _exit(ok, ret);
            if (ok) ++liquidations;
            return;
        }
    }

    /// @notice The Emergency Guardian sets the Hub's state: None, Frozen, Paused(General) or Paused(MintPathSuspect).
    function setPause(
        uint256 seed
    ) external {
        uint256 target = seed % 4;
        PauseState s = w.registry.pauseState(w.hub);
        vm.startPrank(w.guardian);
        if (s == PauseState.Frozen) w.registry.unfreeze(w.hub);
        if (s == PauseState.Paused) w.registry.unpause(w.hub);
        if (target == 1) w.registry.freeze(w.hub);
        if (target == 2) w.registry.pause(w.hub, PauseReason.General);
        if (target == 3) w.registry.pause(w.hub, PauseReason.MintPathSuspect);
        vm.stopPrank();
        ++pauses;
    }

    /// @notice Both pool tokens move to one price in [$0.93, $1.00] on every route (inside the USD band, pool ratio 1).
    function setPrice(
        uint256 seed
    ) external {
        int256 p = int256(bound(seed, 93_000_000, 100_000_000));
        // The next block: an LPOracle caps its fair price's move from a price accepted in the same block.
        vm.roll(block.number + 1);
        for (uint256 i = 0; i < feeds.length; ++i) {
            feeds[i].push(p, block.timestamp);
        }
    }

    /// @notice Time passes (up to a day) with every feed republished at its answer.
    function warp(
        uint256 seed
    ) external {
        vm.warp(block.timestamp + bound(seed, 1, 1 days));
        vm.roll(block.number + 1);
        _refresh();
    }

    /// @notice The Aave DAO cuts the CDP Spoke's draw cap on a debt asset (possibly below what it owes) and anyone
    /// syncs the registry's credit line.
    function cutDrawCap(
        uint256 reserveSeed,
        uint256 capSeed
    ) external {
        uint256 r = reserveSeed % 2;
        uint256 cap = bound(capSeed, 1, 1_000_000);
        vm.prank(w.aaveDao);
        (bool ok,) = w.hubConfigurator
            .call(
                abi.encodeWithSignature(
                    "updateSpokeDrawCap(address,uint256,address,uint256)",
                    w.hub,
                    w.debtAssetIds[r],
                    address(w.spoke),
                    cap
                )
            );
        if (ok) w.registry.syncDrawCap(address(w.spoke), w.debtReserves[r]);
    }

    /// @notice The timelock tightens the market's `topUpSliceUsd` by a little at the short delay.
    function tightenSlice(
        uint256 marketSeed
    ) external {
        uint256 market = w.markets[marketSeed % 2];
        uint256 slice = w.store.topUpSliceUsd(market);
        if (slice <= 1e8) return;
        _govern(address(w.store), abi.encodeCall(IParameterStoreTighten.tightenTopUpSliceUsd, (market, slice - 1e8)));
    }

    /// @notice The timelock upgrades the AaveAdapter to the second reviewed implementation at the normal delay.
    function upgradeAdapter() external {
        if (upgrades > 0) return;
        _govern(
            address(w.adapter), abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (w.secondImplementation, bytes("")))
        );
        ++upgrades;
    }

    // ─── Internals ───

    function _govern(
        address target,
        bytes memory data
    ) internal {
        address[] memory t = new address[](1);
        t[0] = target;
        bytes[] memory p = new bytes[](1);
        p[0] = data;
        uint256 delay = w.timelock.requiredDelay(t, p);
        bytes32 salt = keccak256(abi.encode("full-stack op", ++opNonce));
        vm.prank(w.governance);
        w.timelock.schedule(target, 0, data, bytes32(0), salt, delay);
        uint256 scheduledAt = block.timestamp;
        vm.warp(block.timestamp + delay);
        vm.roll(block.number + 1);
        _refresh();
        (bool ok,) = address(w.timelock).call(abi.encodeCall(w.timelock.execute, (target, 0, data, bytes32(0), salt)));
        if (ok && block.timestamp < scheduledAt + delay) ++earlyExecutions;
        // Executing a moment before readiness must fail.
        bytes32 early = keccak256(abi.encode("full-stack early", opNonce));
        vm.prank(w.governance);
        w.timelock.schedule(target, 0, data, bytes32(0), early, delay);
        (ok,) = address(w.timelock).call(abi.encodeCall(w.timelock.execute, (target, 0, data, bytes32(0), early)));
        if (ok) ++earlyExecutions;
        bytes32 id = w.timelock.hashOperation(target, 0, data, bytes32(0), early);
        vm.prank(w.guardian);
        w.timelock.cancel(id);
    }

    /// @dev After a completed pledge Collateralization's counters are within the ParameterStore's caps.
    function _checkCaps(
        uint256 i,
        address wallet
    ) internal {
        uint256 market = w.markets[i];
        PledgeCounters memory k = w.coll.getCounters(w.vaultTokens[i], wallet);
        if (k.regularUsed > w.store.marketUsdCap(market) || k.sliceUsed > w.store.topUpSliceUsd(market)) {
            ++capViolations;
        }
        if (k.depositorUsed > w.store.depositorUsdCap(w.hub)) ++capViolations;
    }

    function _refresh() internal {
        for (uint256 i = 0; i < feeds.length; ++i) {
            feeds[i].push(feeds[i].answer(), block.timestamp);
        }
    }

    function _indebted(
        address proxy
    ) internal view returns (bool) {
        return w.spoke.getUserAccountData(proxy).totalDebtValueRay != 0;
    }

    function _price(
        uint256 i
    ) internal view returns (int256) {
        (bool ok, bytes memory ret) =
            w.registry.getMarket(w.markets[i]).lpOracle.staticcall(abi.encodeWithSignature("latestAnswer()"));
        return ok && ret.length == 32 ? abi.decode(ret, (int256)) : int256(0);
    }

    /// @dev An exit never fails for a pause, a freeze or a breaker.
    function _exit(
        bool ok,
        bytes memory ret
    ) internal {
        if (ok || ret.length < 4) return;
        bytes4 sel = bytes4(ret);
        if (
            sel == IAaveAdapterErrors.ApplicationFrozen.selector || sel == IAaveAdapterErrors.ApplicationPaused.selector
                || sel == IAaveAdapterErrors.AddressIsFrozen.selector
                || sel == IRiskModuleErrors.BreakerTripped.selector
                || sel == IRiskModuleErrors.DebtBreakerTripped.selector
        ) ++exitBlocked;
    }
}
