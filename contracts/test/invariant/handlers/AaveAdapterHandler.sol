// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../../src/custody/collateralization/ICollateralization.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {IAaveAdapterErrors} from "../../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {RepayWithCollateralParams} from "../../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {ProxyManager} from "../../../src/proxy/proxy-manager/ProxyManager.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {CollPriceSource} from "../../utils/fixtures/CollateralizationFixture.sol";
import {AdapterRegistryMock} from "../../utils/mocks/AaveAdapterMocks.sol";
import {CollLPVaultMock, CollPoolToken} from "../../utils/mocks/CollateralizationMocks.sol";
import {LPVaultSwapMock} from "../../utils/mocks/LPVaultSwapMock.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice The contracts and identities the handler drives.
struct AdapterWorld {
    IAaveAdapter adapter;
    ICollateralization coll;
    ProxyManager proxyManager;
    AdapterRegistryMock registry;
    LPVaultSwapMock swap;
    CollLPVaultMock lpVault;
    IAaveV4Spoke spoke;
    address hub;
    VaultToken tokenA;
    VaultToken tokenB;
    uint256 marketA;
    uint256 marketB;
    uint256 reserveA;
    uint256 reserveB;
    CollPoolToken gho;
    CollPoolToken usdc;
    uint256 ghoReserve;
    uint256 usdcReserve;
    uint256 ghoAssetId;
    uint256 usdcAssetId;
    CollPriceSource vtPrice;
    uint32 integrationId;
}

/// @title AaveAdapterHandler
/// @notice Actor handler of the AaveAdapter invariants on the real local Aave V4, the real Collateralization, vault
/// tokens, ProxyManager and PositionProxies: three wallets pledge into two markets, borrow GHO and USDC, repay (their
/// own debt or, as a third-party payer, someone else's), withdraw, remove liquidity, re-credit, repay with collateral;
/// prices move, the Hub's pause state and the address freeze change, LPVaultSwap liquidates honestly, time passes.
/// @dev Ghosts: units minted and burned per vault token, the matching credit or debit in Collateralization per call,
/// borrows completed per proxy, every completed borrow's forwarding, and exit liveness: a repay of an indebted account,
/// a debt-free withdrawal and a fee collection must succeed whatever the Avana pause state and freeze, since Aave
/// allows them here (no Aave pause or halt is set). Each failed expectation increments a counter the invariants read.
contract AaveAdapterHandler is CommonBase, StdUtils {
    AdapterWorld internal w;
    address[3] internal wallets;
    address internal payer;
    uint256 internal keyNonce;

    mapping(address wallet => mapping(uint256 market => bytes32[] keys)) internal openKeys;
    mapping(address proxy => uint256 count) public borrowsCompleted;
    mapping(address wallet => mapping(uint256 market => address proxy)) public firstProxy;
    mapping(address proxy => bytes32 codeHash) public proxyCodeHash;
    address[] public proxies;

    uint256 public minted;
    uint256 public burned;
    uint256 public backingViolations;
    uint256 public borrowViolations;
    uint256 public livenessViolations;
    uint256 public drawCapViolations;
    uint256 public refusedReceiverAccepted;
    uint256 public calls;
    uint256 public exitsAttempted;
    uint256 public exitsSucceeded;
    uint256 public pledges;
    uint256 public borrows;
    uint256 public withdrawals;
    uint256 public removals;
    uint256 public recredits;
    uint256 public deleverages;
    uint256 public liquidations;

    constructor(
        AdapterWorld memory world,
        address[3] memory wallets_,
        address payer_
    ) {
        w = world;
        wallets = wallets_;
        payer = payer_;
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

    function _market(
        uint256 seed
    ) internal view returns (uint256 market, VaultToken token, uint256 reserve) {
        return seed % 2 == 0 ? (w.marketA, w.tokenA, w.reserveA) : (w.marketB, w.tokenB, w.reserveB);
    }

    function _supply() internal view returns (uint256) {
        return w.tokenA.totalSupply() + w.tokenB.totalSupply();
    }

    function _ledger() internal view returns (uint256) {
        return w.coll.getTotalCredited(address(w.tokenA)) + w.coll.getPending(address(w.tokenA)).units
            + w.coll.getTotalCredited(address(w.tokenB)) + w.coll.getPending(address(w.tokenB)).units;
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 600;
    }

    /// @dev Supply and Collateralization's backing move together in every call (no orphan burn in this model).
    function _checkBacking(
        uint256 supplyBefore,
        uint256 ledgerBefore
    ) internal {
        int256 ds = int256(_supply()) - int256(supplyBefore);
        int256 dl = int256(_ledger()) - int256(ledgerBefore);
        if (ds != dl) ++backingViolations;
    }

    function _mins() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
    }

    function _pickKey(
        address wallet,
        uint256 market,
        uint256 seed
    ) internal view returns (bool ok, uint256 index, bytes32 key) {
        bytes32[] storage ks = openKeys[wallet][market];
        if (ks.length == 0) return (false, 0, bytes32(0));
        index = seed % ks.length;
        return (true, index, ks[index]);
    }

    function _dropKey(
        address wallet,
        uint256 market,
        uint256 index
    ) internal {
        bytes32[] storage ks = openKeys[wallet][market];
        ks[index] = ks[ks.length - 1];
        ks.pop();
    }

    // ─── Actions ───

    function pledge(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 unitsSeed
    ) external {
        ++calls;
        address wallet = wallets[walletSeed % 3];
        (uint256 market,,) = _market(marketSeed);
        if (openKeys[wallet][market].length >= 6) return;
        uint128 units = uint128(bound(unitsSeed, 100_000_000, 5_000_000_000));
        bytes32 key = keccak256(abi.encode("handler", ++keyNonce));
        w.lpVault.mintPosition(key, wallet, market, units);
        uint256 s0 = _supply();
        uint256 l0 = _ledger();
        vm.prank(wallet);
        try w.adapter.pledge(market, PositionRef(w.integrationId, key), _deadline()) returns (
            address proxy, uint256, uint128 credited
        ) {
            minted += credited;
            ++pledges;
            openKeys[wallet][market].push(key);
            if (firstProxy[wallet][market] == address(0)) {
                firstProxy[wallet][market] = proxy;
                proxyCodeHash[proxy] = proxy.codehash;
                proxies.push(proxy);
            }
        } catch {}
        _checkBacking(s0, l0);
    }

    function borrow(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 reserveSeed,
        uint256 amountSeed,
        uint256 mode
    ) external {
        ++calls;
        address wallet = wallets[walletSeed % 3];
        (uint256 market,,) = _market(marketSeed);
        address proxy = w.adapter.proxyOf(wallet, market);
        if (proxy == address(0)) return;
        bool gho = reserveSeed % 2 == 0;
        uint256 reserve = gho ? w.ghoReserve : w.usdcReserve;
        uint256 amount = bound(amountSeed, 1, 3000) * (gho ? 1e18 : 1e6);
        uint256 nonce = w.adapter.borrowNonce(proxy);
        // Mode 0, 1: a good borrow to the wallet or the payer; 2: a refused receiver; 3: a stale nonce.
        address receiver = mode % 4 == 1 ? payer : (mode % 4 == 2 ? proxy : wallet);
        uint256 useNonce = mode % 4 == 3 ? nonce + 1 : nonce;
        CollPoolToken asset = gho ? w.gho : w.usdc;
        uint256 receiverBefore = asset.balanceOf(receiver);
        uint256 proxyBefore = asset.balanceOf(proxy);
        vm.prank(wallet);
        try w.adapter.borrow(market, reserve, amount, receiver, _deadline(), 0, useNonce) returns (uint256 drawn) {
            ++borrowsCompleted[proxy];
            ++borrows;
            if (mode % 4 == 2) ++refusedReceiverAccepted;
            if (useNonce != nonce) ++borrowViolations;
            if (drawn != amount || asset.balanceOf(receiver) - receiverBefore != amount) ++borrowViolations;
            if (asset.balanceOf(proxy) != proxyBefore) ++borrowViolations;
            uint256 assetId = gho ? w.ghoAssetId : w.usdcAssetId;
            IAaveV4Hub.SpokeConfig memory cfg = IAaveV4Hub(w.hub).getSpokeConfig(assetId, address(w.spoke));
            uint256 cap = uint256(cfg.drawCap) * (gho ? 1e18 : 1e6);
            if (IAaveV4Hub(w.hub).getSpokeTotalOwed(assetId, address(w.spoke)) > cap) ++drawCapViolations;
        } catch {}
    }

    function repay(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 reserveSeed,
        uint256 capSeed,
        uint256 mode
    ) external {
        ++calls;
        address borrower = wallets[walletSeed % 3];
        (uint256 market,,) = _market(marketSeed);
        address proxy = w.adapter.proxyOf(borrower, market);
        if (proxy == address(0)) return;
        bool gho = reserveSeed % 2 == 0;
        uint256 reserve = gho ? w.ghoReserve : w.usdcReserve;
        uint256 debtNow = w.spoke.getUserTotalDebt(reserve, proxy);
        if (debtNow == 0) return;
        // Mode 0: partial by the borrower; 1: repay-all by the borrower; 2: partial by a third party; 3: repay-all
        // by a third party.
        bool all = mode % 2 == 1;
        address from = mode % 4 >= 2 ? payer : borrower;
        uint256 cap = all ? debtNow + bound(capSeed, 0, debtNow / 100 + 1) : bound(capSeed, 1, debtNow * 2);
        CollPoolToken asset = gho ? w.gho : w.usdc;
        asset.mint(from, cap);
        vm.prank(from);
        asset.approve(address(w.adapter), cap);
        ++exitsAttempted;
        vm.prank(from);
        try w.adapter.repay(borrower, market, reserve, cap, all, _deadline()) returns (uint256) {
            ++exitsSucceeded;
            if (all && w.spoke.getUserTotalDebt(reserve, proxy) != 0) ++livenessViolations;
        } catch {
            // Repay is open in every Avana state; nothing here pauses Aave.
            ++livenessViolations;
        }
        vm.prank(from);
        asset.approve(address(w.adapter), 0);
    }

    function withdraw(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 keySeed
    ) external {
        ++calls;
        address wallet = wallets[walletSeed % 3];
        (uint256 market,,) = _market(marketSeed);
        (bool ok, uint256 index, bytes32 key) = _pickKey(wallet, market, keySeed);
        if (!ok) return;
        address proxy = w.adapter.proxyOf(wallet, market);
        bool debtFree = w.spoke.getUserAccountData(proxy).borrowCount == 0;
        uint256 units = w.coll.previewRelease(w.integrationId, key);
        if (units == 0) return;
        uint256 s0 = _supply();
        uint256 l0 = _ledger();
        if (debtFree) ++exitsAttempted;
        vm.prank(wallet);
        try w.adapter.withdraw(market, PositionRef(w.integrationId, key), units, _deadline(), 0) {
            burned += units;
            ++withdrawals;
            _dropKey(wallet, market, index);
            if (debtFree) ++exitsSucceeded;
        } catch {
            // A debt-free withdrawal reads no Avana stop and Aave allows it: it must not fail.
            if (debtFree) ++livenessViolations;
        }
        _checkBacking(s0, l0);
    }

    function removeLiquidity(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 keySeed,
        uint256 unitsSeed
    ) external {
        ++calls;
        address wallet = wallets[walletSeed % 3];
        (uint256 market,,) = _market(marketSeed);
        (bool ok,, bytes32 key) = _pickKey(wallet, market, keySeed);
        if (!ok) return;
        uint256 credited = w.coll.previewRelease(w.integrationId, key);
        if (credited < 2) return;
        uint128 units = uint128(bound(unitsSeed, 1, credited - 1));
        uint256 s0 = _supply();
        uint256 l0 = _ledger();
        vm.prank(wallet);
        try w.adapter.removeLiquidity(market, PositionRef(w.integrationId, key), units, _mins(), _deadline(), 0) {
            burned += units;
            ++removals;
        } catch {}
        _checkBacking(s0, l0);
    }

    function recredit(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 keySeed,
        uint256 addSeed
    ) external {
        ++calls;
        address wallet = wallets[walletSeed % 3];
        (uint256 market,,) = _market(marketSeed);
        (bool ok,, bytes32 key) = _pickKey(wallet, market, keySeed);
        if (!ok) return;
        w.lpVault.addUnits(key, uint128(bound(addSeed, 1, 1_000_000_000)));
        uint256 s0 = _supply();
        uint256 l0 = _ledger();
        vm.prank(wallet);
        try w.adapter.recredit(market, PositionRef(w.integrationId, key), "", _deadline()) returns (uint128 added) {
            minted += added;
            ++recredits;
        } catch {}
        _checkBacking(s0, l0);
    }

    function repayWithCollateral(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 keySeed,
        uint256 unitsSeed
    ) external {
        ++calls;
        address wallet = wallets[walletSeed % 3];
        (uint256 market,,) = _market(marketSeed);
        (bool ok,, bytes32 key) = _pickKey(wallet, market, keySeed);
        if (!ok) return;
        address proxy = w.adapter.proxyOf(wallet, market);
        uint256 debtNow = w.spoke.getUserTotalDebt(w.ghoReserve, proxy);
        uint256 credited = w.coll.previewRelease(w.integrationId, key);
        if (debtNow == 0 || credited < 2) return;
        // LPVaultSwap converts at the oracle: price8 × 10^4 GHO wei per unit of a 6-decimal vault token; the units
        // released are at most what repays the GHO debt, so the flash loan never exceeds it.
        uint256 perUnit = uint256(w.vtPrice.latestAnswer()) * 1e4;
        uint256 maxUnits = debtNow / perUnit;
        if (maxUnits > credited - 1) maxUnits = credited - 1;
        if (maxUnits == 0) return;
        uint128 units = uint128(bound(unitsSeed, 1, maxUnits));
        uint256 flash = uint256(units) * perUnit;
        w.swap.setDeleverage(flash, perUnit, 0);
        RepayWithCollateralParams memory p = RepayWithCollateralParams({
            marketId: market,
            position: PositionRef(w.integrationId, key),
            units: units,
            debtReserveId: w.ghoReserve,
            minAmounts: _mins(),
            minDebtRepaid: 0,
            deadline: _deadline(),
            minHealthFactor: 0
        });
        uint256 s0 = _supply();
        uint256 l0 = _ledger();
        vm.prank(wallet);
        try w.adapter.repayWithCollateral(p) {
            burned += units;
            ++deleverages;
            if (w.spoke.getUserTotalDebt(w.ghoReserve, proxy) > debtNow) ++livenessViolations;
        } catch {}
        _checkBacking(s0, l0);
    }

    function collectFees(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 keySeed,
        uint256 feeSeed
    ) external {
        ++calls;
        address wallet = wallets[walletSeed % 3];
        (uint256 market,,) = _market(marketSeed);
        (bool ok,, bytes32 key) = _pickKey(wallet, market, keySeed);
        if (!ok) return;
        w.lpVault.accrueFees(key, bound(feeSeed, 0, 1e9));
        ++exitsAttempted;
        vm.prank(wallet);
        try w.adapter.collectFees(market, PositionRef(w.integrationId, key), _deadline()) {
            ++exitsSucceeded;
        } catch {
            ++livenessViolations;
        }
    }

    function setPrice(
        uint256 seed
    ) external {
        ++calls;
        w.vtPrice.set(int256(bound(seed, 0.9e8, 2.2e8)));
    }

    function setPause(
        uint256 seed,
        uint256 freezeSeed
    ) external {
        ++calls;
        // None half of the time, so new activity runs between the stops.
        uint256 s = seed % 8;
        PauseState state = s < 4 ? PauseState.None : (s == 4 ? PauseState.Frozen : PauseState.Paused);
        PauseReason reason =
            s == 5 || s == 7 ? PauseReason.General : (s == 6 ? PauseReason.MintPathSuspect : PauseReason.None);
        w.registry.setPause(w.hub, state, reason);
        address who = wallets[freezeSeed % 3];
        w.registry.setFrozen(who, (freezeSeed >> 8) % 4 == 0);
    }

    function liquidate(
        uint256 walletSeed,
        uint256 marketSeed,
        uint256 coverSeed
    ) external {
        ++calls;
        address wallet = wallets[walletSeed % 3];
        (uint256 market, VaultToken token, uint256 reserve) = _market(marketSeed);
        address proxy = w.adapter.proxyOf(wallet, market);
        if (proxy == address(0)) return;
        if (w.spoke.getUserAccountData(proxy).healthFactor >= 1e18) return;
        uint256 debtNow = w.spoke.getUserTotalDebt(w.ghoReserve, proxy);
        if (debtNow == 0) return;
        uint256 cover = bound(coverSeed, 1, debtNow);
        uint256 s0 = _supply();
        uint256 l0 = _ledger();
        try w.swap.liquidate(address(w.spoke), market, address(token), reserve, w.ghoReserve, proxy, cover, 2) returns (
            uint256 seized
        ) {
            burned += seized;
            ++liquidations;
        } catch {}
        _checkBacking(s0, l0);
    }

    function warp(
        uint256 seed
    ) external {
        ++calls;
        vm.warp(block.timestamp + bound(seed, 1, 5 days));
    }
}
