// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserve} from "../../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserveAdmin} from "../../../src/coverage/first-loss-reserve/IAvanaFirstLossReserveAdmin.sol";
import {Withdrawal, WithdrawalStatus} from "../../../src/coverage/first-loss-reserve/types/Withdrawal.sol";
import {CoverageActor} from "../../utils/mocks/CoverageActor.sol";
import {MockAuthority} from "../../utils/mocks/MockAuthority.sol";
import {MockCoverageHub} from "../../utils/mocks/MockCoverageHub.sol";
import {MockDebtAsset} from "../../utils/mocks/MockDebtAsset.sol";

/// @title AvanaFirstLossReserveProperties
/// @notice Echidna and Medusa properties of the First-Loss Reserve (2.14). Between transactions: the reserve holds only
/// donated tokens, its funded balance plus what it covered and withdrew never exceeds what was funded plus the yield
/// accrued to it (`accrueYield` adds interest to every added share and to `ghostYield`), only Spokes listed on the
/// asset are allowlisted, every issued withdrawal ID has a status, and the
/// immutables never change. Inside each assertion entry point: `fund`, `coverDeficit`, the allowlist and the
/// withdrawal calls succeed exactly when 2.14 allows and move exactly the stated amounts.
/// @dev The harness is the Aave DAO: the authority (`MockAuthority`, the `canCall` interface of the DAO's
/// AccessManager, which the unit tests use for real; the real one does not fit the harness's 49,152-byte initcode)
/// lets it call `coverDeficit` and every DAO function; `OUTSIDER` may call none. The Hub is the one-asset model
/// `MockCoverageHub`, whose `accrue` raises the value of every added share: the pinned Aave V4 Hub is deployed from its
/// release artifacts with `deployCode` (`AaveV4Fixture`), which Echidna and Medusa cannot run, so yield on the real Hub
/// is checked by `AvanaFirstLossReserve.unit.t.sol` (`test_TEST_293_yieldFillsFiniteCapButNotMax`,
/// `test_TEST_293_totalsAreSignedUnderYield`, `test_TEST_293_dustFundBelowOneShareReverts`); deficits are recorded in whole asset units, as `draw` + `reportDeficit` of whole amounts
/// record them. Actor indexes are taken modulo 3 with `if` branches, so hevm sees finite branching.
contract AvanaFirstLossReserveProperties {
    uint256 internal constant ASSET_ID = 0;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant DELAY = 1_209_600;
    /// @notice The Hub's virtual shares and assets in its share price (`MockCoverageHub.VIRTUAL`, as in the Hub).
    uint256 internal constant HUB_VIRTUAL = 1e6;

    MockDebtAsset internal immutable TOKEN;
    MockCoverageHub internal immutable HUB;
    MockAuthority internal immutable AUTH;
    AvanaFirstLossReserve internal immutable CS;
    CoverageActor internal immutable LEND;
    CoverageActor internal immutable BORROW;
    CoverageActor internal immutable OTHER;
    CoverageActor internal immutable OUTSIDER;

    /// @notice Tokens sent straight to the First-Loss Reserve.
    uint256 public ghostDonated;
    /// @notice Interest accrued to every added share (an upper bound of the reserve's yield).
    uint256 public ghostYield;

    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        TOKEN = new MockDebtAsset("GHO", "GHO", 18);
        HUB = new MockCoverageHub(address(TOKEN), 18, ASSET_ID);
        AUTH = new MockAuthority();
        CS = new AvanaFirstLossReserve(address(HUB), address(TOKEN), ASSET_ID, address(AUTH), DELAY);
        LEND = new CoverageActor();
        BORROW = new CoverageActor();
        OTHER = new CoverageActor();
        OUTSIDER = new CoverageActor();
        HUB.setSpoke(address(CS), true, true, false);
        HUB.setSpoke(address(LEND), true, true, false);
        HUB.setSpoke(address(BORROW), true, true, false);
        HUB.setSpoke(address(OTHER), true, true, false);

        AUTH.allow(address(this), IAvanaFirstLossReserve.coverDeficit.selector);
        AUTH.allow(address(this), IAvanaFirstLossReserveAdmin.setAllowedBorrowSpoke.selector);
        AUTH.allow(address(this), IAvanaFirstLossReserveAdmin.setFirstLossReserveMinimum.selector);
        AUTH.allow(address(this), IAvanaFirstLossReserveAdmin.requestWithdrawal.selector);
        AUTH.allow(address(this), IAvanaFirstLossReserveAdmin.cancelWithdrawal.selector);
        AUTH.allow(address(this), IAvanaFirstLossReserveAdmin.executeWithdrawal.selector);

        TOKEN.mint(address(HUB), 1_000_000e18);
        LEND.exec(address(HUB), abi.encodeCall(MockCoverageHub.add, (ASSET_ID, 1_000_000e18)));
        TOKEN.mint(address(this), 100_000e18);
        TOKEN.approve(address(CS), type(uint256).max);
        CS.fund(100_000e18);
        CS.setAllowedBorrowSpoke(address(BORROW), true);
        CS.setFirstLossReserveMinimum(100_000e18);
    }

    // ─── Properties (between transactions) ───

    function property_holdsOnlyDonations() external view returns (bool) {
        return TOKEN.balanceOf(address(CS)) == ghostDonated;
    }

    /// @notice SPEC-FLR-002 as a signed identity: the reserve's value plus everything it covered and returned never
    /// exceeds what was funded plus the yield it earned; with yield `totalCovered` may exceed `totalFunded`.
    function property_balanceWithinNetFundingPlusYield() external view returns (bool) {
        return CS.fundedBalance() + CS.totalCovered() + CS.totalWithdrawn() <= CS.totalFunded() + ghostYield;
    }

    function property_onlyListedSpokesAllowlisted() external view returns (bool) {
        return !CS.allowedBorrowSpoke(address(OUTSIDER)) && !CS.allowedBorrowSpoke(address(0))
            && !CS.allowedBorrowSpoke(address(this));
    }

    function property_issuedIdsHaveStatus() external view returns (bool) {
        uint256 next = CS.nextWithdrawalId();
        if (CS.getWithdrawal(0).status != WithdrawalStatus.None) return false;
        if (CS.getWithdrawal(next).status != WithdrawalStatus.None) return false;
        return next == 1 || CS.getWithdrawal(next - 1).status != WithdrawalStatus.None;
    }

    function property_immutablesFixed() external view returns (bool) {
        return CS.HUB() == address(HUB) && CS.ASSET() == address(TOKEN) && CS.ASSET_ID() == ASSET_ID
            && CS.RESERVE_WITHDRAWAL_DELAY() == DELAY && CS.authority() == address(AUTH);
    }

    // ─── State actions ───

    /// @notice A drawing Spoke borrows `amount` whole units and reports them all as a deficit.
    function recordDeficit(
        uint8 who,
        uint64 amount
    ) external {
        address spoke = _spoke(who);
        uint256 x = uint256(amount) % (HUB.liquidity() / 1e18 + 1);
        if (x == 0) return;
        HUB.drawAndReport(spoke, x * 1e18);
    }

    /// @notice Interest of `amount` whole units accrues to every added share of the asset.
    function accrueYield(
        uint32 amount
    ) external {
        HUB.accrue(uint256(amount) * 1e18);
        ghostYield += uint256(amount) * 1e18;
    }

    function donate(
        uint32 amount
    ) external {
        TOKEN.mint(address(CS), amount);
        ghostDonated += amount;
    }

    function setHalted(
        bool halted
    ) external {
        HUB.setSpoke(address(CS), true, true, halted);
    }

    // ─── Assertion entry points ───

    /// @notice `fund` succeeds exactly for a non-zero amount worth at least one Hub share on an unhalted instance
    /// (`REQ-FLR-037`: below one share's value, `floor(amount × (S + 1e6) / (A + 1e6)) = 0` once yield lifts the share
    /// price above 1, the Hub reverts with `InvalidShares`) and moves exactly `amount` from the funder to the Hub.
    function fundAmount(
        uint96 amount
    ) external {
        ++sequences;
        TOKEN.mint(address(this), amount);
        uint256 mine = TOKEN.balanceOf(address(this));
        uint256 hubBalance = TOKEN.balanceOf(address(HUB));
        uint256 total = CS.totalFunded();
        uint256 shares = (uint256(amount) * (HUB.addedShares() + HUB_VIRTUAL)) / (HUB.totalAddedAssets() + HUB_VIRTUAL);
        bool expected = amount > 0 && !HUB.halted(address(CS)) && shares > 0;
        try CS.fund(amount) {
            assert(expected);
            assert(TOKEN.balanceOf(address(this)) == mine - amount);
            assert(TOKEN.balanceOf(address(HUB)) == hubBalance + amount);
            assert(CS.totalFunded() == total + amount);
        } catch {
            assert(!expected);
        }
    }

    /// @notice `coverDeficit` succeeds exactly for an allowlisted Spoke with a non-zero SPEC-FLR-001 amount, and then
    /// eliminates exactly `min(maxAmount, ceil(deficitRay / RAY), fundedBalance())` of that Spoke's deficit.
    function cover(
        uint8 who,
        uint128 maxAmount
    ) external {
        ++sequences;
        address spoke = _spoke(who);
        uint256 deficitRay = HUB.spokeDeficitRay(spoke);
        uint256 funded = CS.fundedBalance();
        uint256 amount = _min(_min(maxAmount, (deficitRay + RAY - 1) / RAY), funded);
        bool expected = CS.allowedBorrowSpoke(spoke) && amount > 0;
        try CS.coverDeficit(spoke, maxAmount) returns (uint256, uint256 covered) {
            assert(expected);
            assert(covered == amount);
            uint256 dRay = amount < (deficitRay + RAY - 1) / RAY ? amount * RAY : deficitRay;
            assert(HUB.spokeDeficitRay(spoke) == deficitRay - dRay);
            assert(CS.fundedBalance() + amount <= funded + 1);
        } catch {
            assert(!expected);
        }
    }

    /// @notice Adding to the allowlist succeeds exactly for a listed Spoke; removal always succeeds.
    function allow(
        uint8 who,
        bool allowed
    ) external {
        ++sequences;
        uint256 i = who % 3;
        address spoke = i == 0 ? address(BORROW) : (i == 1 ? address(OTHER) : address(OUTSIDER));
        bool expected = !allowed || spoke != address(OUTSIDER);
        try CS.setAllowedBorrowSpoke(spoke, allowed) {
            assert(expected);
            assert(CS.allowedBorrowSpoke(spoke) == allowed);
        } catch {
            assert(!expected);
        }
    }

    /// @notice A request succeeds exactly for a non-zero amount and a valid recipient, executable after the delay.
    function request(
        uint96 amount,
        uint8 to
    ) external {
        ++sequences;
        uint256 i = to % 3;
        address recipient = i == 0 ? address(OUTSIDER) : (i == 1 ? address(CS) : address(HUB));
        bool expected = amount > 0 && recipient == address(OUTSIDER);
        uint256 id = CS.nextWithdrawalId();
        try CS.requestWithdrawal(amount, recipient) returns (uint256 got) {
            assert(expected && got == id);
            Withdrawal memory w = CS.getWithdrawal(id);
            assert(w.status == WithdrawalStatus.Pending && w.executableAt == block.timestamp + DELAY);
        } catch {
            assert(!expected);
        }
    }

    /// @notice Cancellation succeeds exactly for a Pending request.
    function cancel(
        uint8 idSeed
    ) external {
        ++sequences;
        uint256 id = uint256(idSeed) % (CS.nextWithdrawalId() + 1);
        bool expected = CS.getWithdrawal(id).status == WithdrawalStatus.Pending;
        try CS.cancelWithdrawal(id) {
            assert(expected);
            assert(CS.getWithdrawal(id).status == WithdrawalStatus.Cancelled);
        } catch {
            assert(!expected);
        }
    }

    /// @notice Execution succeeds only for a Pending request at or after `executableAt`, and then withdraws
    /// `min(amount, fundedBalance())` to the recipient.
    function execute(
        uint8 idSeed
    ) external {
        ++sequences;
        uint256 id = uint256(idSeed) % (CS.nextWithdrawalId() + 1);
        Withdrawal memory w = CS.getWithdrawal(id);
        uint256 expectedOut = _min(w.amount, CS.fundedBalance());
        uint256 received = TOKEN.balanceOf(w.to);
        bool deficitOpen = _allowlistedDeficitOpen();
        try CS.executeWithdrawal(id) returns (uint256 withdrawn) {
            assert(w.status == WithdrawalStatus.Pending && block.timestamp >= w.executableAt && !deficitOpen);
            assert(withdrawn == expectedOut && withdrawn > 0);
            assert(TOKEN.balanceOf(w.to) == received + withdrawn);
            assert(CS.getWithdrawal(id).status == WithdrawalStatus.Executed);
        } catch {
            assert(
                w.status != WithdrawalStatus.Pending || block.timestamp < w.executableAt || expectedOut == 0
                    || HUB.halted(address(CS)) || expectedOut > HUB.liquidity() || deficitOpen
            );
            assert(CS.getWithdrawal(id).status == w.status);
        }
    }

    /// @notice The outsider holds no role: every privileged selector refuses it.
    function outsiderCalls(
        uint8 which
    ) external {
        ++sequences;
        uint256 i = which % 6;
        bytes memory data;
        if (i == 0) {
            data = abi.encodeCall(IAvanaFirstLossReserve.coverDeficit, (address(BORROW), 1e18));
        } else if (i == 1) {
            data = abi.encodeCall(IAvanaFirstLossReserveAdmin.setAllowedBorrowSpoke, (address(OTHER), true));
        } else if (i == 2) {
            data = abi.encodeCall(IAvanaFirstLossReserveAdmin.setFirstLossReserveMinimum, (0));
        } else if (i == 3) {
            data = abi.encodeCall(IAvanaFirstLossReserveAdmin.requestWithdrawal, (1e18, address(OUTSIDER)));
        } else if (i == 4) {
            data = abi.encodeCall(IAvanaFirstLossReserveAdmin.cancelWithdrawal, (1));
        } else {
            data = abi.encodeCall(IAvanaFirstLossReserveAdmin.executeWithdrawal, (1));
        }
        (bool ok,) = OUTSIDER.exec(address(CS), data);
        assert(!ok);
    }

    // ─── Helpers ───

    /// @dev Whether an allowlisted drawing Spoke has a recorded deficit (the withdrawal guard of REQ-FLR-026).
    function _allowlistedDeficitOpen() internal view returns (bool) {
        return (CS.allowedBorrowSpoke(address(BORROW)) && HUB.getSpokeDeficitRay(ASSET_ID, address(BORROW)) != 0)
            || (CS.allowedBorrowSpoke(address(OTHER)) && HUB.getSpokeDeficitRay(ASSET_ID, address(OTHER)) != 0);
    }

    function _spoke(
        uint8 who
    ) internal view returns (address) {
        uint256 i = who % 3;
        if (i == 0) return address(BORROW);
        if (i == 1) return address(OTHER);
        return address(OUTSIDER);
    }

    function _min(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
