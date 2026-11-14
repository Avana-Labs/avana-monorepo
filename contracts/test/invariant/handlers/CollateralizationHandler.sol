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
import {VmSafe} from "forge-std/Vm.sol";

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
/// the kept units no reconciliation has debited yet, and the kept units LPVaultSwap still holds. The ledger actions
/// (partial removal, deleverage release, re-credit, zero-credit release) each reconcile the proxy first.
/// @dev Steered so most calls do what they name: a liquidation first gives the account debt if it has none, then sets
/// the price so its health factor lands between 0.50 and 0.99, and covers between a quarter of the debt and all of it;
/// borrows size from the account's remaining borrowing power and repays from its debt. A call that finds nothing to act
/// on reverts `Skipped()` instead of returning, so the campaign's metrics count it as a revert and the success column
/// is the number of calls that changed the ledger.
contract CollateralizationHandler is CommonBase, StdUtils {
    /// @notice Nothing to act on (no record, no debt, nothing pending): the call is counted as a revert.
    error Skipped();

    /// @dev The vault-token reserve's collateral factor on the fixture's CDP Spoke, in basis points.
    uint256 internal constant CF_BPS = 8000;

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
    uint256 public partialRemovals;
    uint256 public deleverages;
    uint256 public recredits;
    uint256 public zeroReleases;
    uint256 public pledges;
    uint256 public borrows;
    uint256 public repays;

    constructor(
        CollWorld memory world,
        address[2] memory proxies_,
        address[2] memory depositors_
    ) {
        w = world;
        proxies = proxies_;
        depositors = depositors_;
    }

    /// @dev A handler call that reverted inside a `startPrank` leaves that prank active (cheatcode state is not rolled
    /// back with the call); end it so the next call starts with no prank, as in VaultTokenAttackerHandler.
    modifier endsStalePrank() {
        (VmSafe.CallerMode mode,,) = vm.readCallers();
        if (mode == VmSafe.CallerMode.RecurrentPrank) vm.stopPrank();
        _;
    }

    /// @notice Setup, not a fuzzed action: each borrower pledges three positions (500, 1,500 and 3,000 vault tokens)
    /// and borrows 60 % of its borrowing power, so every run starts with records to release and debt to liquidate.
    function seedAccounts() external {
        for (uint256 i = 0; i < 2; ++i) {
            this.pledge(i, 500e6);
            this.pledge(i, 1500e6);
            this.pledge(i, 3000e6);
            this.borrow(i, 60);
        }
    }

    /// @notice A borrower pledges a new position of 10^6 to 3 × 10^9 units into its proxy and supplies the units.
    function pledge(
        uint256 who,
        uint256 units
    ) external endsStalePrank {
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
        ++pledges;
    }

    /// @notice A borrower withdraws one record at the units `previewRelease` reports (the release reconciles first).
    function withdraw(
        uint256 who,
        uint256 index
    ) external endsStalePrank {
        address proxy = proxies[_withRecords(who)];
        (, BackingRecord[] memory page) = w.coll.getAccountRecords(proxy, address(w.token), 0, 16);
        if (page.length == 0) revert Skipped();
        BackingRecord memory r = _pick(page, index, true);
        uint256 units = w.coll.previewRelease(r.integrationId, r.positionKey);
        if (units == 0) revert Skipped();
        // A withdrawal must leave the account healthy: when the record is more than it can free, it repays first.
        if (units > _freeUnits(proxy)) _repay(proxy, 100);
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

    /// @notice A borrower borrows 10 % to 95 % of its remaining borrowing power at the current price (GHO at $1); the
    /// other borrower does when `who` has none.
    function borrow(
        uint256 who,
        uint256 pct
    ) external endsStalePrank {
        pct = bound(pct, 10, 95);
        if (!_borrow(proxies[who % 2], pct) && !_borrow(proxies[(who + 1) % 2], pct)) revert Skipped();
        ++borrows;
    }

    /// @notice A borrower repays 10 % to 100 % of its debt (all of it from 90 % up); the other borrower does when `who`
    /// owes nothing.
    function repay(
        uint256 who,
        uint256 pct
    ) external endsStalePrank {
        pct = bound(pct, 10, 100);
        if (!_repay(proxies[who % 2], pct) && !_repay(proxies[(who + 1) % 2], pct)) revert Skipped();
        ++repays;
    }

    /// @notice The vault token's price moves between $0.80 and $2.50.
    function setPrice(
        uint256 price
    ) external endsStalePrank {
        // Bounded to $0.80 … $2.50 in 8 decimals.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.vtPrice.set(int256(bound(price, 0.8e8, 2.5e8)));
    }

    /// @notice The account is made liquidatable (`_makeLiquidatable`), then LPVaultSwap liquidates honestly: snapshot,
    /// seizure, burn and settlement in one Lock session; the price then returns to where it was.
    function liquidate(
        uint256 who,
        uint256 debtToCover,
        uint256 health
    ) external endsStalePrank {
        address proxy = proxies[_withCollateral(who)];
        int256 price = w.vtPrice.latestAnswer();
        debtToCover = _makeLiquidatable(proxy, debtToCover, health);
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
        w.vtPrice.set(price);
        unreconciled[proxy] = 0;
        ++honestLiquidations;
    }

    /// @notice The account is made liquidatable as in `liquidate`, then a non-conforming LPVaultSwap seizes and keeps
    /// the units, with no Collateralization call; the price then returns to where it was.
    function seizeAndKeep(
        uint256 who,
        uint256 debtToCover,
        uint256 health
    ) external endsStalePrank {
        address proxy = proxies[_withCollateral(who)];
        int256 price = w.vtPrice.latestAnswer();
        debtToCover = _makeLiquidatable(proxy, debtToCover, health);
        uint256 seized = _seize(proxy, debtToCover);
        if (seized == 0) revert Skipped();
        w.vtPrice.set(price);
        unreconciled[proxy] += seized;
        keptHeld += seized;
        ++keptSeizures;
    }

    /// @notice LPVaultSwap has the Adapter burn kept units it holds and settles that many pending units.
    function settlePending(
        uint256 units
    ) external endsStalePrank {
        uint256 pendingUnits = w.coll.getPending(address(w.token)).units;
        uint256 most = pendingUnits < keptHeld ? pendingUnits : keptHeld;
        if (most == 0) revert Skipped();
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

    /// @notice A borrower removes 1 % to 99 % of one record's post-reconcile units as a partial removal (the proxy
    /// withdraws them, the Adapter burns them and calls `releasePartial`); the release reconciles first.
    function partialRemove(
        uint256 who,
        uint256 index,
        uint256 pct
    ) external endsStalePrank {
        address proxy = proxies[_withRecords(who)];
        (bytes32 key, uint256 units) = _exitUnits(proxy, index, pct, false);
        if (units == 0) revert Skipped();
        _adapterExit(proxy, key, units, false);
        ++partialRemovals;
    }

    /// @notice A deleverage release of 1 % to 100 % of one record's post-reconcile units (the principal goes to
    /// LPVaultSwap; all of them closes the record).
    function deleverage(
        uint256 who,
        uint256 index,
        uint256 pct
    ) external endsStalePrank {
        address proxy = proxies[_withRecords(who)];
        (bytes32 key, uint256 units) = _exitUnits(proxy, index, pct, true);
        if (units == 0) revert Skipped();
        _adapterExit(proxy, key, units, true);
        ++deleverages;
    }

    /// @notice Someone adds 1 to 10^9 units to a pledged position and its depositor re-credits it; the Adapter mints
    /// the added units and the proxy supplies them.
    function recredit(
        uint256 who,
        uint256 index,
        uint256 extra
    ) external endsStalePrank {
        uint256 i = _withRecords(who);
        address proxy = proxies[i];
        (, BackingRecord[] memory page) = w.coll.getAccountRecords(proxy, address(w.token), 0, 16);
        if (page.length == 0) revert Skipped();
        BackingRecord memory r = _pick(page, index, true);
        if (w.coll.previewRelease(r.integrationId, r.positionKey) == 0) revert Skipped();
        // Bounded to 10^9 below.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.lpVault.addUnits(r.positionKey, uint128(bound(extra, 1, 1e9)));
        vm.startPrank(w.adapter);
        w.lock.acquire();
        (uint128 added,) = w.coll.recredit(depositors[i], proxy, address(w.token), r.positionKey, "", false);
        w.token.mint(proxy, added);
        vm.stopPrank();
        vm.startPrank(proxy);
        w.token.approve(address(w.spoke), added);
        w.spoke.supply(w.vtReserveId, added, proxy);
        vm.stopPrank();
        vm.prank(w.adapter);
        w.lock.release();
        unreconciled[proxy] = 0;
        ++recredits;
    }

    /// @notice The depositor releases a record whose credit a kept seizure took (`previewRelease == 0`).
    function releaseZero(
        uint256 who,
        uint256 index
    ) external endsStalePrank {
        uint256 i = _withRecords(who);
        address proxy = proxies[i];
        (, BackingRecord[] memory page) = w.coll.getAccountRecords(proxy, address(w.token), 0, 16);
        if (page.length == 0) revert Skipped();
        BackingRecord memory r = _pick(page, index, false);
        if (w.coll.previewRelease(r.integrationId, r.positionKey) != 0) revert Skipped();
        vm.startPrank(w.adapter);
        w.lock.acquire();
        w.coll.releaseZeroCredit(depositors[i], address(w.token), r.positionKey);
        w.lock.release();
        vm.stopPrank();
        unreconciled[proxy] = 0;
        ++zeroReleases;
    }

    function proxyAt(
        uint256 i
    ) external view returns (address) {
        return proxies[i];
    }

    /// @dev One record's key and `pct` % of its post-reconcile units: at most `units - 1` for a partial removal, at
    /// most all of them for a deleverage release, and no more than the account can withdraw and stay healthy; 0 when
    /// nothing qualifies.
    function _exitUnits(
        address proxy,
        uint256 index,
        uint256 pct,
        bool all
    ) internal view returns (bytes32 key, uint256 units) {
        (, BackingRecord[] memory page) = w.coll.getAccountRecords(proxy, address(w.token), 0, 16);
        if (page.length == 0) return (key, 0);
        BackingRecord memory r = _pick(page, index, true);
        uint256 credited = w.coll.previewRelease(r.integrationId, r.positionKey);
        uint256 most = all ? credited : (credited == 0 ? 0 : credited - 1);
        uint256 free = _freeUnits(proxy);
        if (most > free) most = free;
        if (most == 0) return (key, 0);
        key = r.positionKey;
        units = credited * bound(pct, 1, 100) / 100;
        if (units == 0) units = 1;
        if (units > most) units = most;
    }

    /// @dev The Adapter's exit: the proxy withdraws `units`, the Adapter burns them and calls `releasePartial` or
    /// `releaseForDeleverage`, one Lock session.
    function _adapterExit(
        address proxy,
        bytes32 key,
        uint256 units,
        bool deleverageRelease
    ) internal {
        vm.prank(w.adapter);
        w.lock.acquire();
        vm.prank(proxy);
        w.spoke.withdraw(w.vtReserveId, units, proxy);
        vm.startPrank(w.adapter);
        w.token.burn(proxy, units);
        // At most the record's credit, below 2^120.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 u = uint128(units);
        if (deleverageRelease) {
            w.coll.releaseForDeleverage(proxy, address(w.token), key, u, new uint256[](2));
        } else {
            w.coll.releasePartial(proxy, address(w.token), key, u, new uint256[](2));
        }
        w.lock.release();
        vm.stopPrank();
        unreconciled[proxy] = 0;
    }

    /// @dev The borrower `who` names, or the other one when `who`'s account has no open record.
    function _withRecords(
        uint256 who
    ) internal view returns (uint256 i) {
        i = who % 2;
        if (w.coll.getOpenRecordCount(proxies[i], address(w.token)) == 0) i = 1 - i;
    }

    /// @dev The borrower `who` names, or the other one when `who`'s account supplies no collateral.
    function _withCollateral(
        uint256 who
    ) internal view returns (uint256 i) {
        i = who % 2;
        if (w.spoke.getUserSuppliedShares(w.vtReserveId, proxies[i]) == 0) i = 1 - i;
    }

    /// @dev Prefers, from `index`, a record whose release would credit units (`credited`) or one that would release
    /// nothing (`!credited`); falls back to the record at `index`.
    function _pick(
        BackingRecord[] memory page,
        uint256 index,
        bool credited
    ) internal view returns (BackingRecord memory) {
        for (uint256 j = 0; j < page.length; ++j) {
            BackingRecord memory r = page[(index + j) % page.length];
            if ((w.coll.previewRelease(r.integrationId, r.positionKey) != 0) == credited) return r;
        }
        return page[index % page.length];
    }

    /// @dev The proxy's supplied vault-token value in 18-decimal USD (units have 6 decimals, the price 8).
    function _collateralValue(
        address proxy
    ) internal view returns (uint256) {
        return w.spoke.getUserSuppliedShares(w.vtReserveId, proxy) * uint256(w.vtPrice.latestAnswer()) * 1e4;
    }

    /// @dev Borrows `pct` % of the proxy's remaining borrowing power (GHO at $1); false when it has less than 1 GHO.
    function _borrow(
        address proxy,
        uint256 pct
    ) internal returns (bool) {
        uint256 most = _collateralValue(proxy) * CF_BPS / 1e4;
        uint256 owed = w.spoke.getUserTotalDebt(w.debtReserveId, proxy);
        if (most <= owed) return false;
        uint256 amount = (most - owed) * pct / 100;
        if (amount < 1e18) return false;
        vm.prank(proxy);
        w.spoke.borrow(w.debtReserveId, amount, proxy);
        return true;
    }

    /// @dev Repays `pct` % of the proxy's debt, all of it from 90 % up; false when it has none.
    function _repay(
        address proxy,
        uint256 pct
    ) internal returns (bool) {
        uint256 owed = w.spoke.getUserTotalDebt(w.debtReserveId, proxy);
        if (owed == 0) return false;
        uint256 amount = pct >= 90 ? type(uint256).max : owed * pct / 100;
        w.debt.mint(proxy, owed + 1e18);
        vm.startPrank(proxy);
        w.debt.approve(address(w.spoke), type(uint256).max);
        w.spoke.repay(w.debtReserveId, amount, proxy);
        w.debt.approve(address(w.spoke), 0);
        vm.stopPrank();
        return true;
    }

    /// @dev Steers an account into liquidation: borrows 90 % to 99 % of its borrowing power if it has no debt or a
    /// health factor above 1.5, then sets the price so its health factor is 0.85 to 0.99, or 0.50 to 0.84 for one seed
    /// in eight (not below $0.01); returns a `debtToCover` between a quarter of the debt and all of it (all of it for
    /// half the seeds and for debts under 4,000 GHO).
    function _makeLiquidatable(
        address proxy,
        uint256 debtToCover,
        uint256 health
    ) internal returns (uint256) {
        if (w.spoke.getUserSuppliedShares(w.vtReserveId, proxy) == 0) revert Skipped();
        if (w.spoke.getUserTotalDebt(w.debtReserveId, proxy) == 0 && !_borrow(proxy, 90 + health % 10)) {
            revert Skipped();
        }
        uint256 hf = w.spoke.getUserAccountData(proxy).healthFactor;
        // A debt small against the collateral would need a price below $0.01: borrow up to the limit first.
        if (hf > 1.5e18 && _borrow(proxy, 90 + health % 10)) hf = w.spoke.getUserAccountData(proxy).healthFactor;
        // One seed in eight goes deep (HF 0.50 to 0.84: the bonus outruns the collateral and Aave takes all of it);
        // the rest stay shallow (0.85 to 0.99), so the account keeps collateral for later calls.
        uint256 target = health % 8 == 0 ? bound(health, 50, 84) : bound(health, 85, 99);
        uint256 price = uint256(w.vtPrice.latestAnswer()) * target * 1e16 / hf;
        // At most 0.99 / HF times the current price, far below 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.vtPrice.set(int256(price < 1e6 ? 1e6 : price));
        uint256 owed = w.spoke.getUserTotalDebt(w.debtReserveId, proxy);
        // Aave's dust rule refuses a partial liquidation that leaves less than $1,000 of debt or collateral.
        return debtToCover % 2 == 0 || owed < 4000e18 ? owed : bound(debtToCover, owed / 4, owed);
    }

    /// @dev Supplied units the proxy can withdraw with its health factor staying at or above 1.01.
    function _freeUnits(
        address proxy
    ) internal view returns (uint256) {
        uint256 supplied = w.spoke.getUserSuppliedShares(w.vtReserveId, proxy);
        uint256 owed = w.spoke.getUserTotalDebt(w.debtReserveId, proxy);
        // Units backing `owed` at the collateral factor: 18-decimal USD over the 8-decimal price into 6-decimal units.
        uint256 needed = owed * 101 * 1e4 / (100 * CF_BPS * uint256(w.vtPrice.latestAnswer()) * 1e4) + 1;
        return owed == 0 ? supplied : (supplied > needed ? supplied - needed : 0);
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
