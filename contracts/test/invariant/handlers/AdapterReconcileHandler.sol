// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../../src/custody/collateralization/ICollateralization.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {CollPriceSource} from "../../utils/fixtures/CollateralizationFixture.sol";
import {CollLPVaultMock, CollPoolToken} from "../../utils/mocks/CollateralizationMocks.sol";
import {LPVaultSwapMock} from "../../utils/mocks/LPVaultSwapMock.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice The contracts the reconcile handler drives: one market of the AaveAdapter fixture.
struct ReconcileWorld {
    IAaveAdapter adapter;
    ICollateralization coll;
    LPVaultSwapMock swap;
    CollLPVaultMock lpVault;
    IAaveV4Spoke spoke;
    address hub;
    VaultToken token;
    uint256 market;
    uint256 reserve;
    CollPoolToken gho;
    uint256 ghoReserve;
    CollPriceSource vtPrice;
    uint32 integrationId;
}

/// @title AdapterReconcileHandler
/// @notice Reconcile on exit through the real AaveAdapter and real PositionProxies: three wallets pledge and borrow
/// GHO in one market; an LPVaultSwap that is honest or hostile at random seizes and keeps vault tokens
/// (`seizeAndKeep`, no Avana call), liquidates honestly, or settles the pending balance honestly; borrowers repay all
/// and withdraw after an unsettled seizure; the price moves.
/// @dev Ghosts: per-proxy equality of Spoke supply and Collateralization's credited units at the end of every
/// withdrawal, honest liquidation and pending settlement that touched the proxy, and the pool tokens Collateralization
/// must hold for the pending balance.
contract AdapterReconcileHandler is CommonBase, StdUtils {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    ReconcileWorld internal w;
    address[3] internal wallets;
    uint256 internal keyNonce;

    mapping(address wallet => bytes32[] keys) internal openKeys;
    address[] public proxies;
    mapping(address proxy => bool) internal known;

    uint256 public ledgerAfterExitViolations;
    uint256 public seizures;
    /// @notice Hostile seizures that kept units (the state a reconciling exit acts on).
    uint256 public keptSeizures;
    uint256 public reconciles;
    uint256 public settlements;

    constructor(
        ReconcileWorld memory world,
        address[3] memory wallets_
    ) {
        w = world;
        wallets = wallets_;
    }

    function proxyCount() external view returns (uint256) {
        return proxies.length;
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 600;
    }

    function _checkLedger(
        address proxy
    ) internal {
        if (w.spoke.getUserSuppliedShares(w.reserve, proxy) != w.coll.getAccountCredited(proxy, address(w.token))) {
            ++ledgerAfterExitViolations;
        }
    }

    function pledge(
        uint256 walletSeed,
        uint256 unitsSeed
    ) external {
        address wallet = wallets[walletSeed % 3];
        if (openKeys[wallet].length >= 4) revert Skipped();
        uint128 units = uint128(bound(unitsSeed, 100_000_000, 5_000_000_000));
        bytes32 key = keccak256(abi.encode("reconcile", ++keyNonce));
        w.lpVault.mintPosition(key, wallet, w.market, units);
        vm.prank(wallet);
        try w.adapter.pledge(w.market, PositionRef(w.integrationId, key), _deadline()) returns (
            address proxy, uint256, uint128
        ) {
            openKeys[wallet].push(key);
            if (!known[proxy]) {
                known[proxy] = true;
                proxies.push(proxy);
            }
        } catch {
            revert Skipped();
        }
    }

    function borrow(
        uint256 walletSeed,
        uint256 amountSeed
    ) external {
        address wallet = wallets[walletSeed % 3];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        if (proxy == address(0)) revert Skipped();
        uint256 amount = bound(amountSeed, 1, 4000) * 1e18;
        uint256 nonce = w.adapter.borrowNonce(proxy);
        vm.prank(wallet);
        try w.adapter.borrow(w.market, w.ghoReserve, amount, wallet, _deadline(), 0, nonce) {}
        catch {
            revert Skipped();
        }
    }

    function setPrice(
        uint256 seed
    ) external {
        w.vtPrice.set(int256(bound(seed, 1.2e8, 2e8)));
    }

    /// @notice LPVaultSwap seizes, hostile (keeps the units, no Avana call) or honest (snapshot, burn, settlement).
    /// @dev Steered so most calls seize: the account is the first from the seed with GHO debt (when none has any, the
    /// first with a proxy borrows 3,000 GHO through `borrow`); for three seeds in four a healthy account has the
    /// vault-token price lowered so its health factor is 0.85 to 0.99 (restored after the call); the cover is 1 to
    /// 2,000 GHO, or the whole debt when less than 1,000 GHO would remain (no dust), so most seizures leave collateral
    /// for a reconciling exit. Before steering (64 runs of 50 calls) no seizure ever succeeded, so the reconcile and
    /// settlement invariants were never exercised.
    function seize(
        uint256 walletSeed,
        uint256 coverSeed,
        bool hostile
    ) external {
        address proxy = _debtor(walletSeed);
        if (proxy == address(0)) {
            for (uint256 j = 0; j < 3; ++j) {
                if (w.adapter.proxyOf(wallets[(walletSeed % 3 + j) % 3], w.market) == address(0)) continue;
                try this.borrow(walletSeed % 3 + j, 3000) {} catch {}
                break;
            }
            proxy = _debtor(walletSeed);
            if (proxy == address(0)) revert Skipped();
        }
        uint256 steer = uint256(keccak256(abi.encode(coverSeed)));
        int256 price = w.vtPrice.latestAnswer();
        _toLiquidatable(proxy, price, steer);
        uint256 owed = w.spoke.getUserTotalDebt(w.ghoReserve, proxy);
        uint256 cover = bound(coverSeed, 1, 2000) * 1e18;
        if (cover + 1000e18 > owed) cover = owed;
        _seize(proxy, cover, hostile);
        w.vtPrice.set(price);
    }

    /// @dev The first wallet from `walletSeed` with a position whose proxy holds kept units, else the first with a
    /// position; zero when no wallet has one.
    function _exiter(
        uint256 walletSeed
    ) internal view returns (address first) {
        for (uint256 j = 0; j < 3; ++j) {
            address wallet = wallets[(walletSeed % 3 + j) % 3];
            if (openKeys[wallet].length == 0) continue;
            if (first == address(0)) first = wallet;
            address proxy = w.adapter.proxyOf(wallet, w.market);
            if (w.spoke.getUserSuppliedShares(w.reserve, proxy) < w.coll.getAccountCredited(proxy, address(w.token))) {
                return wallet;
            }
        }
    }

    /// @dev The first proxy from `walletSeed` with GHO debt, or zero.
    function _debtor(
        uint256 walletSeed
    ) internal view returns (address proxy) {
        for (uint256 j = 0; j < 3; ++j) {
            proxy = w.adapter.proxyOf(wallets[(walletSeed % 3 + j) % 3], w.market);
            if (proxy != address(0) && w.spoke.getUserTotalDebt(w.ghoReserve, proxy) != 0) return proxy;
        }
        return address(0);
    }

    /// @dev For three steering values in four, lowers the vault-token price so a healthy `proxy`'s health factor is
    /// 0.85 to 0.99 (HF is linear in that price; GHO is fixed at $1).
    function _toLiquidatable(
        address proxy,
        int256 price,
        uint256 steer
    ) internal {
        uint256 hf = w.spoke.getUserAccountData(proxy).healthFactor;
        if (hf < 1e18 || steer % 4 == 0) return;
        uint256 lowered = uint256(price) * bound(steer >> 8, 85, 99) * 1e16 / hf;
        // At most 0.99 / HF times the current price (below 2e8).
        // forge-lint: disable-next-line(unsafe-typecast)
        w.vtPrice.set(int256(lowered > 1e6 ? lowered : 1e6));
    }

    function _seize(
        address proxy,
        uint256 cover,
        bool hostile
    ) internal {
        if (hostile) {
            try w.swap.seizeAndKeep(address(w.spoke), address(w.token), w.reserve, w.ghoReserve, proxy, cover) returns (
                uint256 s
            ) {
                if (s > 0) {
                    ++seizures;
                    ++keptSeizures;
                }
            } catch {
                revert Skipped();
            }
        } else {
            try w.swap
            .liquidate(address(w.spoke), w.market, address(w.token), w.reserve, w.ghoReserve, proxy, cover, 2) returns (
                uint256 s
            ) {
                if (s > 0) ++seizures;
                _checkLedger(proxy);
            } catch {
                revert Skipped();
            }
        }
    }

    /// @notice The borrower repays all its GHO and withdraws one position (reconciling any unsettled seizure).
    /// @dev Steered to the first wallet from the seed whose proxy has units a hostile seizure kept (Spoke supply below
    /// Collateralization's credit), else the first with a position.
    function exit(
        uint256 walletSeed,
        uint256 keySeed
    ) external {
        address wallet = _exiter(walletSeed);
        if (wallet == address(0)) revert Skipped();
        bytes32[] storage ks = openKeys[wallet];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        uint256 owed = w.spoke.getUserTotalDebt(w.ghoReserve, proxy);
        if (owed > 0) {
            w.gho.mint(wallet, owed);
            vm.prank(wallet);
            w.gho.approve(address(w.adapter), owed);
            vm.prank(wallet);
            w.adapter.repay(wallet, w.market, w.ghoReserve, owed, true, _deadline());
        }
        uint256 index = keySeed % ks.length;
        bytes32 key = ks[index];
        uint256 pending0 = w.coll.getPending(address(w.token)).units;
        uint256 units = w.coll.previewRelease(w.integrationId, key);
        if (units == 0) revert Skipped();
        vm.prank(wallet);
        w.adapter.withdraw(w.market, PositionRef(w.integrationId, key), units, _deadline(), 0);
        if (w.coll.getPending(address(w.token)).units > pending0) ++reconciles;
        ks[index] = ks[ks.length - 1];
        ks.pop();
        _checkLedger(proxy);
    }

    /// @notice An honest LPVaultSwap settles what it holds of the pending balance.
    function settle(
        uint256 unitsSeed
    ) external {
        uint256 pendingUnits = w.coll.getPending(address(w.token)).units;
        uint256 held = w.token.balanceOf(address(w.swap));
        uint256 max = pendingUnits < held ? pendingUnits : held;
        if (max == 0) revert Skipped();
        uint256 units = bound(unitsSeed, 1, max);
        w.swap.settlePending(w.market, address(w.token), units);
        ++settlements;
        for (uint256 i = 0; i < proxies.length; ++i) {
            if (
                w.spoke.getUserSuppliedShares(w.reserve, proxies[i])
                    > w.coll.getAccountCredited(proxies[i], address(w.token))
            ) {
                ++ledgerAfterExitViolations;
            }
        }
    }
}
