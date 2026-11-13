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
    ReconcileWorld internal w;
    address[3] internal wallets;
    uint256 internal keyNonce;

    mapping(address wallet => bytes32[] keys) internal openKeys;
    address[] public proxies;
    mapping(address proxy => bool) internal known;

    uint256 public ledgerAfterExitViolations;
    uint256 public seizures;
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
        if (openKeys[wallet].length >= 4) return;
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
        } catch {}
    }

    function borrow(
        uint256 walletSeed,
        uint256 amountSeed
    ) external {
        address wallet = wallets[walletSeed % 3];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        if (proxy == address(0)) return;
        uint256 amount = bound(amountSeed, 1, 4000) * 1e18;
        uint256 nonce = w.adapter.borrowNonce(proxy);
        vm.prank(wallet);
        try w.adapter.borrow(w.market, w.ghoReserve, amount, wallet, _deadline(), 0, nonce) {} catch {}
    }

    function setPrice(
        uint256 seed
    ) external {
        w.vtPrice.set(int256(bound(seed, 1.2e8, 2e8)));
    }

    /// @notice LPVaultSwap seizes, hostile (keeps the units, no Avana call) or honest (snapshot, burn, settlement).
    function seize(
        uint256 walletSeed,
        uint256 coverSeed,
        bool hostile
    ) external {
        address proxy = w.adapter.proxyOf(wallets[walletSeed % 3], w.market);
        if (proxy == address(0)) return;
        uint256 cover = bound(coverSeed, 1, 2000) * 1e18;
        if (hostile) {
            try w.swap.seizeAndKeep(address(w.spoke), address(w.token), w.reserve, w.ghoReserve, proxy, cover) returns (
                uint256 s
            ) {
                if (s > 0) ++seizures;
            } catch {}
        } else {
            try w.swap
            .liquidate(address(w.spoke), w.market, address(w.token), w.reserve, w.ghoReserve, proxy, cover, 2) returns (
                uint256 s
            ) {
                if (s > 0) ++seizures;
                _checkLedger(proxy);
            } catch {}
        }
    }

    /// @notice The borrower repays all its GHO and withdraws one position (reconciling any unsettled seizure).
    function exit(
        uint256 walletSeed,
        uint256 keySeed
    ) external {
        address wallet = wallets[walletSeed % 3];
        bytes32[] storage ks = openKeys[wallet];
        if (ks.length == 0) return;
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
        if (max == 0) return;
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
