// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../../src/custody/collateralization/ICollateralization.sol";
import {BackingRecord} from "../../../src/custody/collateralization/types/BackingRecord.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILock} from "../../../src/lock/lock/ILock.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {CollPriceSource} from "../../utils/fixtures/CollateralizationFixture.sol";
import {CollLPVaultMock, CollPoolToken} from "../../utils/mocks/CollateralizationMocks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice The contracts and identities the handler drives.
struct CollWorld {
    ICollateralization coll;
    ILock lock;
    VaultToken token;
    CollLPVaultMock lpVault;
    IAaveV4Spoke spoke;
    CollPoolToken debt;
    CollPriceSource vtPrice;
    address adapter;
    address lpVaultSwap;
    uint256 vtReserveId;
    uint256 debtReserveId;
    uint256 marketId;
}

/// @title CollateralizationHandler
/// @notice Actor handler of the reconcile-on-exit invariants on the real Collateralization and the real local Aave
/// V4: two borrowers pledge, withdraw, borrow and repay; the price moves; LPVaultSwap liquidates honestly (snapshot,
/// seizure, burn, settlement under the Lock) or, as a non-conforming implementation, seizes and keeps the units with no
/// Collateralization call; kept units are later burned and paid out through `settlePending`. Ghosts record, per proxy,
/// the kept units no reconciliation has debited yet, and the kept units LPVaultSwap still holds.
contract CollateralizationHandler is CommonBase, StdUtils {
    CollWorld internal w;
    address[2] internal proxies;
    address[2] internal depositors;
    uint256 internal nextKey = 1000;

    /// @notice Kept-seizure units of a proxy that no reconciliation has debited yet.
    mapping(address proxy => uint256 units) public unreconciled;
    /// @notice Kept-seizure units LPVaultSwap still holds (neither burned nor settled).
    uint256 public keptHeld;
    uint256 public honestLiquidations;
    uint256 public keptSeizures;
    uint256 public pendingSettlements;
    uint256 public withdrawals;

    constructor(
        CollWorld memory world,
        address[2] memory proxies_,
        address[2] memory depositors_
    ) {
        w = world;
        proxies = proxies_;
        depositors = depositors_;
    }

    /// @notice A borrower pledges a new position of 10^6 to 3 × 10^9 units into its proxy and supplies the units.
    function pledge(
        uint256 who,
        uint256 units
    ) external {
        uint256 i = who % 2;
        address proxy = proxies[i];
        units = bound(units, 1e6, 3e9);
        bytes32 key = bytes32(nextKey++);
        // Bounded to 3e9 above.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.lpVault.mintPosition(key, depositors[i], w.marketId, uint128(units));
        vm.startPrank(w.adapter);
        w.lock.acquire();
        if (!w.token.isValidProxy(proxy)) w.token.addValidProxy(proxy);
        (, uint128 credited) = w.coll.pledge(depositors[i], proxy, address(w.token), key, false);
        w.token.mint(proxy, credited);
        vm.stopPrank();
        vm.startPrank(proxy);
        w.token.approve(address(w.spoke), credited);
        w.spoke.supply(w.vtReserveId, credited, proxy);
        w.spoke.setUsingAsCollateral(w.vtReserveId, true, proxy);
        vm.stopPrank();
        vm.prank(w.adapter);
        w.lock.release();
    }

    /// @notice A borrower withdraws one record at the units `previewRelease` reports (the release reconciles first).
    function withdraw(
        uint256 who,
        uint256 index
    ) external {
        address proxy = proxies[who % 2];
        (, BackingRecord[] memory page) = w.coll.getAccountRecords(proxy, address(w.token), 0, 16);
        if (page.length == 0) return;
        BackingRecord memory r = page[index % page.length];
        if (r.credited == 0) return;
        uint256 units = w.coll.previewRelease(r.integrationId, r.positionKey);
        if (units == 0) return;
        vm.prank(w.adapter);
        w.lock.acquire();
        vm.prank(proxy);
        w.spoke.withdraw(w.vtReserveId, units, proxy);
        vm.startPrank(w.adapter);
        w.token.burn(proxy, units);
        w.coll.release(proxy, address(w.token), r.positionKey, units);
        w.lock.release();
        vm.stopPrank();
        unreconciled[proxy] = 0;
        ++withdrawals;
    }

    /// @notice A borrower borrows 50 % to 78 % of its collateral's value at the current price (GHO at $1); Aave
    /// refuses a borrow that would end below its health factor.
    function borrow(
        uint256 who,
        uint256 pct
    ) external {
        address proxy = proxies[who % 2];
        uint256 credited = w.coll.getAccountCredited(proxy, address(w.token));
        // Collateral value in 18-decimal USD: units have 6 decimals, the price 8.
        uint256 value = credited * uint256(w.vtPrice.latestAnswer()) * 1e4;
        uint256 amount = value * bound(pct, 50, 78) / 100;
        if (amount == 0) return;
        vm.prank(proxy);
        w.spoke.borrow(w.debtReserveId, amount, proxy);
    }

    /// @notice A borrower repays all its debt.
    function repay(
        uint256 who
    ) external {
        address proxy = proxies[who % 2];
        w.debt.mint(proxy, 1_000_000e18);
        vm.startPrank(proxy);
        w.debt.approve(address(w.spoke), type(uint256).max);
        w.spoke.repay(w.debtReserveId, type(uint256).max, proxy);
        vm.stopPrank();
    }

    /// @notice The vault token's price moves between $0.80 and $2.50.
    function setPrice(
        uint256 price
    ) external {
        // Bounded to $0.80 … $2.50 in 8 decimals.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.vtPrice.set(int256(bound(price, 0.8e8, 2.5e8)));
    }

    /// @notice The price drops by 20 % to 60 % (not below $0.10), then LPVaultSwap liquidates honestly: snapshot,
    /// seizure, burn and settlement in one Lock session.
    function liquidate(
        uint256 who,
        uint256 debtToCover,
        uint256 drop
    ) external {
        address proxy = proxies[who % 2];
        debtToCover = bound(debtToCover, 1e18, 20_000e18);
        _drop(drop);
        vm.prank(w.lpVaultSwap);
        w.lock.acquire();
        vm.prank(w.lpVaultSwap);
        w.coll.beginSeizure(proxy, address(w.token));
        uint256 seized = _seize(proxy, debtToCover);
        vm.prank(w.adapter);
        w.token.burn(w.lpVaultSwap, seized);
        vm.startPrank(w.lpVaultSwap);
        w.coll.settleSeizure(proxy, address(w.token), seized, new uint256[](2));
        w.lock.release();
        vm.stopPrank();
        unreconciled[proxy] = 0;
        ++honestLiquidations;
    }

    /// @notice The price drops as in `liquidate`, then a non-conforming LPVaultSwap seizes and keeps the units, with no
    /// Collateralization call.
    function seizeAndKeep(
        uint256 who,
        uint256 debtToCover,
        uint256 drop
    ) external {
        address proxy = proxies[who % 2];
        debtToCover = bound(debtToCover, 1e18, 20_000e18);
        _drop(drop);
        uint256 seized = _seize(proxy, debtToCover);
        unreconciled[proxy] += seized;
        keptHeld += seized;
        ++keptSeizures;
    }

    /// @notice LPVaultSwap has the Adapter burn kept units it holds and settles that many pending units.
    function settlePending(
        uint256 units
    ) external {
        uint256 pendingUnits = w.coll.getPending(address(w.token)).units;
        uint256 most = pendingUnits < keptHeld ? pendingUnits : keptHeld;
        if (most == 0) return;
        units = bound(units, 1, most);
        vm.prank(w.lpVaultSwap);
        w.lock.acquire();
        vm.prank(w.adapter);
        w.token.burn(w.lpVaultSwap, units);
        vm.startPrank(w.lpVaultSwap);
        w.coll.settlePending(address(w.token), units);
        w.lock.release();
        vm.stopPrank();
        keptHeld -= units;
        ++pendingSettlements;
    }

    function proxyAt(
        uint256 i
    ) external view returns (address) {
        return proxies[i];
    }

    /// @dev Lowers the vault token's price by 20 % to 60 %, to no less than $0.10.
    function _drop(
        uint256 drop
    ) internal {
        uint256 price = uint256(w.vtPrice.latestAnswer()) * (100 - bound(drop, 20, 60)) / 100;
        // At most the current price, which is below 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.vtPrice.set(int256(price < 0.1e8 ? 0.1e8 : price));
    }

    /// @dev `liquidationCall` by LPVaultSwap; returns the vault-token units it received.
    function _seize(
        address proxy,
        uint256 debtToCover
    ) internal returns (uint256 seized) {
        uint256 before = w.token.balanceOf(w.lpVaultSwap);
        w.debt.mint(w.lpVaultSwap, debtToCover);
        vm.startPrank(w.lpVaultSwap);
        w.debt.approve(address(w.spoke), debtToCover);
        w.spoke.liquidationCall(w.vtReserveId, w.debtReserveId, proxy, debtToCover, false);
        vm.stopPrank();
        seized = w.token.balanceOf(w.lpVaultSwap) - before;
    }
}
