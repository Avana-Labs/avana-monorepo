// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ICollateralization} from "../../../src/legacy/ICollateralization.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreTighten} from "../../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {IRiskModuleErrors} from "../../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCounters, PositionRef} from "../../../src/types/PositionTypes.sol";
import {ClTestToken} from "../../utils/fixtures/ClPoolFixture.sol";
import {FullStackLPVaultMock} from "../../utils/mocks/FullStackLPVaultMock.sol";
import {OracleFeedMock} from "../../utils/mocks/LPOracleMocks.sol";
import {LPVaultSwapMock} from "../../utils/mocks/LPVaultSwapMock.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice The real contracts and identities the full-stack handler drives.
struct FullStackWorld {
    IAaveAdapter adapter;
    MarketRegistry registry;
    IParameterStore store;
    AccessManager accessManager;
    ICollateralization coll;
    FullStackLPVaultMock lpVault;
    LPVaultSwapMock swap;
    IAaveV4Spoke spoke;
    address hub;
    address hubConfigurator;
    address aaveDao;
    address dao;
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
/// repay (their own debt or a third party's), withdraw debt-free; token prices move inside the USD band; LPVaultSwap
/// liquidates any account below HF 1; the Aave DAO cuts the CDP Spoke's draw cap below its drawn amount and anyone
/// syncs it into the registry's credit line; the governance Safe tightens a cap at the tighten delay and upgrades the
/// AaveAdapter to a second reviewed implementation at the governance delay; time passes with every feed republished.
/// @dev Each failed expectation increments a counter the invariants read: an exit (repay, debt-free withdrawal,
/// liquidation) that reverts for a breaker; a borrow that leaves the Spoke's owed amount above its draw cap; a pledge
/// worth less than `minPledgeUsd` at the served price; a governed call that executed before its execution delay.
contract FullStackHandler is CommonBase, StdUtils {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work. An exit refused for a breaker does
    /// not revert, so its `exitBlocked` count stands.
    error Skipped();

    /// @dev The Hub rounds both share conversions of a draw up (`toDrawnSharesUp`, then `toDrawnAssetsUp` in
    /// `getSpokeTotalOwed`); each adds less than `drawnIndex / RAY` units, under 2 while the index is below 2 RAY. The
    /// Hub's cap check reads the owed amount before the draw, so a draw of exactly the room left reads 1 or 2 units above
    /// the cap afterwards (a GHO draw of 160e18 into an empty 160 GHO cap at index 1.0000003 reads 160e18 + 1).
    uint256 internal constant DRAW_ROUNDING = 2;

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
    uint256 public drawCapViolations;
    uint256 public minPledgeViolations;
    uint256 public capViolations;
    uint256 public earlyExecutions;
    uint256 public pledges;
    uint256 public borrows;
    uint256 public repays;
    uint256 public withdrawals;
    uint256 public liquidations;
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

    // ─── Set-up ───

    /// @notice Set-up only (not a fuzzed action): Alice and Bob pledge 10,000 units ($20,000) into market A and
    /// Carol into market B, and each borrows 5,700 GHO (95 % of the $6,000 the pledge can borrow), so a price fall
    /// inside the USD band puts the accounts below HF 1 and repays have debt from the first call.
    function seedAccounts() external {
        for (uint256 i = 0; i < 3; ++i) {
            this.pledge(i, i / 2, 10_000e6);
            this.borrow(i, i / 2, 0, 2850);
            this.borrow(i, i / 2, 0, 2850);
        }
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
        uint256 value = uint256(units) * uint256(_price(i)) / 1e6;
        vm.prank(wallet);
        (bool ok,) = address(w.adapter)
            .call(abi.encodeCall(w.adapter.pledge, (market, PositionRef(w.integrationId, key), block.timestamp + 600)));
        if (!ok) revert Skipped();
        ++pledges;
        if (value < w.store.minPledgeUsd(market)) ++minPledgeViolations;
        _checkCaps(i, wallet);
        openKeys[wallet][market].push(key);
        address proxy = w.adapter.proxyOf(wallet, market);
        if (proxyWallet[proxy] == address(0)) {
            proxies.push(proxy);
            proxyWallet[proxy] = wallet;
            proxyMarket[proxy] = market;
            proxyCodeHash[proxy] = proxy.codehash;
        }
    }

    /// @dev Steered to the first (wallet, market) pair from the seeds that has a proxy.
    function borrow(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 reserveSeed,
        uint256 shareSeed
    ) external {
        (address wallet, uint256 market, address proxy) = _withProxy(walletSeed, marketSeed, false);
        if (proxy == address(0)) revert Skipped();
        uint256 r = reserveSeed % 2;
        // $1 to $3,000 of the asset ($1.00 each); a borrow beyond the account's room is refused by Aave or the RiskModule.
        uint256 amount = bound(shareSeed, 1, 3000) * 10 ** w.debtAssets[r].decimals();
        // The Spoke's owed amount (drawn + premium) and deficit on the asset in this block, before the draw.
        (uint256 owedBefore, uint256 deficit) = _spokeOwed(r);
        if (!_borrowAs(wallet, market, proxy, r, amount)) revert Skipped();
        ++borrows;
        _checkDrawGate(r, amount, owedBefore, deficit);
    }

    /// @dev `wallet` borrows `amount` of reserve `r` through the AaveAdapter at its proxy's next nonce.
    function _borrowAs(
        address wallet,
        uint256 market,
        address proxy,
        uint256 r,
        uint256 amount
    ) internal returns (bool ok) {
        uint256 nonce = w.adapter.borrowNonce(proxy);
        vm.prank(wallet);
        (ok,) = address(w.adapter)
            .call(
                abi.encodeCall(
                    w.adapter.borrow, (market, w.debtReserves[r], amount, wallet, block.timestamp + 600, 0, nonce)
                )
            );
    }

    /// @dev Steered to the first pair from the seeds whose proxy has debt, in the chosen reserve if it owes it.
    function repay(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 reserveSeed,
        uint256 shareSeed
    ) external {
        (address wallet, uint256 market, address proxy) = _withProxy(walletSeed, marketSeed, true);
        if (proxy == address(0)) revert Skipped();
        uint256 r = reserveSeed % 2;
        if (w.spoke.getUserTotalDebt(w.debtReserves[r], proxy) == 0) r = 1 - r;
        uint256 owed = w.spoke.getUserTotalDebt(w.debtReserves[r], proxy);
        uint256 amount = owed * bound(shareSeed, 1, 100) / 100;
        if (amount == 0) revert Skipped();
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
        if (!ok && !_exit(ret)) revert Skipped();
        if (ok) ++repays;
    }

    /// @dev Steered to the first pair from the seeds whose proxy is debt-free and holds a position; when there is
    /// none, the first debt-free pair first pledges 1,000 units through `pledge`.
    function withdraw(
        uint256 walletSeed,
        uint256 marketSeed
    ) external {
        (bool found, address wallet, uint256 market) = _debtFree(walletSeed, marketSeed, true);
        if (!found) {
            (found,,) = _debtFree(walletSeed, marketSeed, false);
            if (!found) revert Skipped();
            uint256 j = _debtFreeIndex(walletSeed, marketSeed);
            try this.pledge(walletSeed % 3 + j, marketSeed % 2 + j / 3, 1000e6) {} catch {}
            (found, wallet, market) = _debtFree(walletSeed, marketSeed, true);
            if (!found) revert Skipped();
        }
        bytes32[] storage keys = openKeys[wallet][market];
        bytes32 key = keys[keys.length - 1];
        uint128 units = w.coll.getRecord(w.coll.recordIdOf(w.integrationId, key)).credited;
        vm.prank(wallet);
        (bool ok, bytes memory ret) = address(w.adapter)
            .call(
                abi.encodeCall(
                    w.adapter.withdraw, (market, PositionRef(w.integrationId, key), units, block.timestamp + 600, 0)
                )
            );
        if (!ok && !_exit(ret)) revert Skipped();
        if (ok) {
            ++withdrawals;
            keys.pop();
        }
    }

    /// @notice LPVaultSwap liquidates `debtToCover` of the first account below HF 1 in the chosen market.
    /// @dev Steered: when no account is below HF 1, for three seeds in four both pool tokens first move to $0.93 to
    /// $0.95 (`setPrice`, inside the USD band), which puts the set-up's accounts (HF about 1.05) below 1. The steering
    /// bits come from a hash of the seed, so the fuzzer's small dictionary values steer too.
    function liquidate(
        uint256 seed
    ) external {
        uint256 steer = uint256(keccak256(abi.encode(seed)));
        if (!_anyLiquidatable() && steer % 4 != 0) this.setPrice(bound(steer >> 8, 93_000_000, 95_000_000));
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
            if (!ok && !_exit(ret)) revert Skipped();
            if (ok) ++liquidations;
            return;
        }
        revert Skipped();
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
        ok;
    }

    /// @notice The governance Safe tightens the market's `topUpSliceUsd` by a little after the tighten delay.
    function tightenSlice(
        uint256 marketSeed
    ) external {
        uint256 market = w.markets[marketSeed % 2];
        uint256 slice = w.store.topUpSliceUsd(market);
        if (slice <= 1e8) revert Skipped();
        _govern(address(w.store), abi.encodeCall(IParameterStoreTighten.tightenTopUpSliceUsd, (market, slice - 1e8)));
    }

    /// @notice The governance Safe upgrades the AaveAdapter to the second reviewed implementation after the governance delay.
    function upgradeAdapter() external {
        if (upgrades > 0) revert Skipped();
        _govern(
            address(w.adapter), abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (w.secondImplementation, bytes("")))
        );
        ++upgrades;
    }

    // ─── Internals ───

    /// @dev The CDP Spoke's owed amount (drawn + premium) on debt reserve `r`'s asset and its deficit, rounded up as the
    /// Hub's draw check rounds it (`fromRayUp`).
    function _spokeOwed(
        uint256 r
    ) internal view returns (uint256 owed, uint256 deficit) {
        IAaveV4Hub h = IAaveV4Hub(w.hub);
        owed = h.getSpokeTotalOwed(w.debtAssetIds[r], address(w.spoke));
        uint256 ray = h.getSpokeDeficitRay(w.debtAssetIds[r], address(w.spoke));
        deficit = ray == 0 ? 0 : (ray - 1) / 1e27 + 1;
    }

    /// @dev After a borrow of `amount` on reserve `r`: `INV-057`'s draw gate as the Hub applies it at each draw (drawn +
    /// premium + deficit + the amount within the cap), and the owed amount grown by the amount plus at most the round-up
    /// of the Hub's two share conversions, so no draw goes past the cap by more than that rounding.
    function _checkDrawGate(
        uint256 r,
        uint256 amount,
        uint256 owedBefore,
        uint256 deficit
    ) internal {
        IAaveV4Hub h = IAaveV4Hub(w.hub);
        uint256 id = w.debtAssetIds[r];
        uint256 cap = uint256(h.getSpokeConfig(id, address(w.spoke)).drawCap) * 10 ** w.debtAssets[r].decimals();
        if (owedBefore + amount + deficit > cap) ++drawCapViolations;
        if (h.getSpokeTotalOwed(id, address(w.spoke)) > owedBefore + amount + DRAW_ROUNDING) ++drawCapViolations;
    }

    /// @dev The (wallet, market) pairs in the order a call tries them: the seeds' own pair first, then the others.
    function _pair(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 j
    ) internal view returns (address wallet, uint256 market) {
        wallet = wallets[(walletSeed % 3 + j) % 3];
        market = w.markets[(marketSeed % 2 + j / 3) % 2];
    }

    /// @dev The first pair from the seeds with a proxy (with debt when `indebted`); a zero proxy when there is none.
    function _withProxy(
        uint256 walletSeed,
        uint256 marketSeed,
        bool indebted
    ) internal view returns (address wallet, uint256 market, address proxy) {
        for (uint256 j = 0; j < 6; ++j) {
            (wallet, market) = _pair(walletSeed, marketSeed, j);
            proxy = w.adapter.proxyOf(wallet, market);
            if (proxy != address(0) && (!indebted || _indebted(proxy))) return (wallet, market, proxy);
        }
        return (wallet, market, address(0));
    }

    /// @dev The first pair from the seeds whose proxy is absent or debt-free (and, with `withPosition`, exists and
    /// holds a position the handler opened).
    function _debtFree(
        uint256 walletSeed,
        uint256 marketSeed,
        bool withPosition
    ) internal view returns (bool found, address wallet, uint256 market) {
        for (uint256 j = 0; j < 6; ++j) {
            (wallet, market) = _pair(walletSeed, marketSeed, j);
            address p = w.adapter.proxyOf(wallet, market);
            bool free = p == address(0) || !_indebted(p);
            if (withPosition) free = free && p != address(0) && openKeys[wallet][market].length != 0;
            if (free) return (true, wallet, market);
        }
    }

    function _debtFreeIndex(
        uint256 walletSeed,
        uint256 marketSeed
    ) internal view returns (uint256 j) {
        for (; j < 6; ++j) {
            (address wallet, uint256 market) = _pair(walletSeed, marketSeed, j);
            address p = w.adapter.proxyOf(wallet, market);
            if (p == address(0) || !_indebted(p)) return j;
        }
    }

    function _anyLiquidatable() internal view returns (bool) {
        for (uint256 j = 0; j < proxies.length; ++j) {
            if (_indebted(proxies[j]) && w.spoke.getUserAccountData(proxies[j]).healthFactor < 1e18) return true;
        }
        return false;
    }

    function _govern(
        address target,
        bytes memory data
    ) internal {
        IAccessManager m = IAccessManager(address(w.accessManager));
        (, uint32 delay) = m.canCall(w.governance, target, bytes4(data));
        vm.prank(w.governance);
        m.schedule(target, data, 0);
        uint256 scheduledAt = block.timestamp;
        // Executing a moment before readiness must fail.
        vm.prank(w.governance);
        (bool ok,) = address(m).call(abi.encodeCall(m.execute, (target, data)));
        if (ok) ++earlyExecutions;
        vm.warp(block.timestamp + delay);
        vm.roll(block.number + 1);
        _refresh();
        vm.prank(w.governance);
        (ok,) = address(m).call(abi.encodeCall(m.execute, (target, data)));
        if (ok && block.timestamp < scheduledAt + delay) ++earlyExecutions;
        // The DAO cancels a scheduled repeat of the call.
        vm.prank(w.governance);
        m.schedule(target, data, 0);
        vm.prank(w.dao);
        m.cancel(w.governance, target, data);
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

    /// @dev An exit never fails for a breaker: counts a failed exit's error when it is one.
    /// @return blocked Whether `ret` is such an error.
    function _exit(
        bytes memory ret
    ) internal returns (bool blocked) {
        if (ret.length < 4) return false;
        bytes4 sel = bytes4(ret);
        blocked =
            sel == IRiskModuleErrors.BreakerTripped.selector || sel == IRiskModuleErrors.DebtBreakerTripped.selector;
        if (blocked) ++exitBlocked;
    }
}
