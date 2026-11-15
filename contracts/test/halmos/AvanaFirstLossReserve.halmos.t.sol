// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserveAdmin} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserveAdmin.sol";
import {MockAuthority} from "../utils/mocks/MockAuthority.sol";
import {MockDebtAsset} from "../utils/mocks/MockDebtAsset.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Recording Hub for the symbolic checks, as the Certora spec summarises it: `add`, `remove` and
/// `eliminateDeficit` record their asset ID, amount and Spoke; deficits are stored per (asset ID, Spoke) and the
/// First-Loss Reserve's added assets are a settable value, so every quantity stays linear for the solver.
contract HalmosCoverageHub {
    uint256 internal constant RAY = 1e27;

    address public immutable UNDERLYING;
    uint256 public immutable ASSET_ID;

    mapping(uint256 assetId => mapping(address spoke => uint256 ray)) public deficitRay;
    mapping(address spoke => bool listed) public listed;
    address[] internal _spokeList;
    uint256 public funded;

    uint256 public addCalls;
    uint256 public removeCalls;
    uint256 public eliminateCalls;
    uint256 public lastAmount;
    address public lastSpoke;
    bool public otherAssetTouched;

    constructor(
        address underlying,
        uint256 assetId
    ) {
        UNDERLYING = underlying;
        ASSET_ID = assetId;
    }

    function setDeficitRay(
        uint256 assetId,
        address spoke,
        uint256 ray
    ) external {
        deficitRay[assetId][spoke] = ray;
    }

    function setFunded(
        uint256 value
    ) external {
        funded = value;
    }

    function setListed(
        address spoke
    ) external {
        if (!listed[spoke]) _spokeList.push(spoke);
        listed[spoke] = true;
    }

    function getSpokeCount(
        uint256 assetId
    ) external view returns (uint256) {
        return assetId == ASSET_ID ? _spokeList.length : 0;
    }

    function getSpokeAddress(
        uint256,
        uint256 index
    ) external view returns (address) {
        return _spokeList[index];
    }

    function add(
        uint256 assetId,
        uint256 amount
    ) external returns (uint256) {
        if (assetId != ASSET_ID) otherAssetTouched = true;
        ++addCalls;
        lastAmount = amount;
        return amount;
    }

    function remove(
        uint256 assetId,
        uint256 amount,
        address to
    ) external returns (uint256) {
        if (assetId != ASSET_ID) otherAssetTouched = true;
        ++removeCalls;
        lastAmount = amount;
        lastSpoke = to;
        return amount;
    }

    function eliminateDeficit(
        uint256 assetId,
        uint256 amount,
        address spoke
    ) external returns (uint256, uint256) {
        if (assetId != ASSET_ID) otherAssetTouched = true;
        ++eliminateCalls;
        lastAmount = amount;
        lastSpoke = spoke;
        uint256 d = deficitRay[assetId][spoke];
        uint256 dRay;
        uint256 covered;
        // Unchecked: for a recorded deficit d <= 2^256 - RAY none of these operations wraps, for any amount
        // (MATH-ST-130), so the values equal those of the checked form, which never reverts on those inputs. Every
        // deficit the reserve can cover here is below 2^200. Unchecked, no revert path of the model depends on the
        // semantics of the divisions by RAY. A deficit above 2^256 - RAY (only PROP-060 records one, on another
        // asset) would have made the checked form revert and roll back `otherAssetTouched`; here it cannot.
        unchecked {
            dRay = amount < (d + RAY - 1) / RAY ? amount * RAY : d;
            deficitRay[assetId][spoke] = d - dRay;
            covered = (dRay + RAY - 1) / RAY;
        }
        return (amount, covered);
    }

    function getAssetUnderlyingAndDecimals(
        uint256 assetId
    ) external view returns (address, uint8) {
        return assetId == ASSET_ID ? (UNDERLYING, 18) : (address(0), 0);
    }

    function getSpokeAddedAssets(
        uint256,
        address
    ) external view returns (uint256) {
        return funded;
    }

    function getSpokeAddedShares(
        uint256,
        address
    ) external view returns (uint256) {
        return funded;
    }

    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256) {
        return deficitRay[assetId][spoke];
    }

    function isSpokeListed(
        uint256 assetId,
        address spoke
    ) external view returns (bool) {
        return assetId == ASSET_ID && listed[spoke];
    }
}

/// @title AvanaFirstLossReserveHalmosTest
/// @notice Symbolic checks of the First-Loss Reserve (2.14) for every caller, Spoke, amount and recorded deficit: a
/// successful `coverDeficit` came from the coverage role, named an allowlisted Spoke and eliminated, once, on its own
/// asset, an amount in `(0, min(maxAmount, ceil(deficitRay / RAY), fundedBalance())]`; it succeeds whenever those
/// inputs allow; no call of any selector touches another Hub asset; `fund` moves exactly the amount from the caller
/// to the Hub.
/// @dev The Hub is the recording model above (the Certora summaries of `AvanaFirstLossReserve.spec`), the authority a
/// two-holder stand-in. Unit and fuzz tests run the same properties against the pinned Aave V4 Hub. Halmos abstracts
/// a division as an uninterpreted function and falls back to the full 256-bit division only when the abstract query
/// has a model; the PROP-039 checks therefore compare the code's amount with the same `Math.ceilDiv(deficit, RAY)`
/// term the code computes, and MATH-ST-130 proves that term is `ceil(deficit / RAY)`. The earlier form, asserting
/// `(deficit + RAY - 1) / RAY`, a different division term, ran out of time on the division. The 10,000-run fuzz
/// twins are `testFuzz_TEST_199_coverOnlyByRoleForAllowlistedAndLive` and `testFuzz_TEST_199_coverageIsThreeWayMin`.
contract AvanaFirstLossReserveHalmosTest is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant ASSET_ID = 2;
    uint256 internal constant OTHER_ASSET_ID = 3;
    address internal constant COVERAGE = address(0xC0FE);
    address internal constant DAO = address(0xDA0);
    address internal constant BORROW = address(0xB0);
    address internal constant FUNDER = address(0xF0);
    address internal constant RECIPIENT = address(0x9EC);

    MockDebtAsset internal token;
    MockDebtAsset internal otherToken;
    HalmosCoverageHub internal hub;
    MockAuthority internal auth;
    AvanaFirstLossReserve internal cs;

    function setUp() public {
        token = new MockDebtAsset("GHO", "GHO", 18);
        otherToken = new MockDebtAsset("USDC", "USDC", 6);
        hub = new HalmosCoverageHub(address(token), ASSET_ID);
        auth = new MockAuthority();
        auth.allow(COVERAGE, IAvanaFirstLossReserve.coverDeficit.selector);
        auth.allow(DAO, IAvanaFirstLossReserveAdmin.setAllowedBorrowSpoke.selector);
        auth.allow(DAO, IAvanaFirstLossReserveAdmin.setFirstLossReserveMinimum.selector);
        auth.allow(DAO, IAvanaFirstLossReserveAdmin.requestWithdrawal.selector);
        auth.allow(DAO, IAvanaFirstLossReserveAdmin.cancelWithdrawal.selector);
        auth.allow(DAO, IAvanaFirstLossReserveAdmin.executeWithdrawal.selector);
        cs = new AvanaFirstLossReserve(address(hub), address(token), ASSET_ID, address(auth), 1_209_600);
        hub.setListed(BORROW);
        vm.prank(DAO);
        cs.setAllowedBorrowSpoke(BORROW, true);
        vm.prank(DAO);
        cs.requestWithdrawal(1000e18, RECIPIENT);
        vm.warp(block.timestamp + 1_209_600);
        token.mint(FUNDER, 1 << 128);
        otherToken.mint(FUNDER, 1 << 128);
        vm.prank(FUNDER);
        token.approve(address(cs), type(uint256).max);
        vm.prank(FUNDER);
        otherToken.approve(address(cs), type(uint256).max);
    }

    // PROP-039 verifies: REQ-FLR-016, REQ-FLR-018, REQ-FLR-019, REQ-FLR-029, REQ-FLR-030, SPEC-FLR-001, INV-042, Q-101, Q-142, Q-190, Q-236
    /// @notice A successful `coverDeficit` came from the coverage role, for an allowlisted Spoke, and called
    /// `eliminateDeficit` once on `ASSET_ID` with `0 < amount ≤ min(maxAmount, ceil(deficitRay / RAY), funded)`.
    /// This case: every caller and Spoke except the coverage role on the allowlisted Spoke, every amount, deficit
    /// below 2^200 and funded balance below 2^128. With
    /// `check_PROP_039_coverDeficitBoundedAndAllowlistedRoleAndSpoke` it covers every input of the property: the two
    /// assumptions on (caller, spoke) are complements and the amounts are the same. Here the call reverts in
    /// `restricted` or at the allowlist, before the division by RAY, so no query reaches it.
    function check_PROP_039_coverDeficitBoundedAndAllowlistedOtherCallerOrSpoke(
        address caller,
        address spoke,
        uint256 maxAmount,
        uint256 deficit,
        uint256 funded
    ) public {
        vm.assume(caller != COVERAGE || spoke != BORROW);
        _coverDeficitBounded(caller, spoke, maxAmount, deficit, funded);
    }

    // PROP-039 verifies: REQ-FLR-016, REQ-FLR-018, REQ-FLR-019, REQ-FLR-029, REQ-FLR-030, SPEC-FLR-001, INV-042, Q-101, Q-142, Q-190, Q-236
    /// @notice The same property for the coverage role on the allowlisted Spoke (the rest of the domain), every
    /// amount, deficit below 2^200 and funded balance below 2^128. The amount passed to the Hub equals the reference
    /// `min(min(maxAmount, Math.ceilDiv(deficit, RAY)), funded)`, the term the code computes, so the assertions hold
    /// without the semantics of the division; MATH-ST-130 proves `Math.ceilDiv(deficit, RAY) = ceil(deficit / RAY)`.
    function check_PROP_039_coverDeficitBoundedAndAllowlistedRoleAndSpoke(
        uint256 maxAmount,
        uint256 deficit,
        uint256 funded
    ) public {
        _coverDeficitBounded(COVERAGE, BORROW, maxAmount, deficit, funded);
    }

    /// @dev The body of both `coverDeficitBoundedAndAllowlisted` cases.
    function _coverDeficitBounded(
        address caller,
        address spoke,
        uint256 maxAmount,
        uint256 deficit,
        uint256 funded
    ) internal {
        vm.assume(deficit < (1 << 200));
        vm.assume(funded < (1 << 128));
        hub.setDeficitRay(ASSET_ID, spoke, deficit);
        hub.setFunded(funded);
        vm.prank(caller);
        (bool ok,) = address(cs).call(abi.encodeCall(IAvanaFirstLossReserve.coverDeficit, (spoke, maxAmount)));
        if (ok) {
            uint256 amount = hub.lastAmount();
            uint256 ceilDeficit = Math.ceilDiv(deficit, RAY); // ceil(deficit / RAY), MATH-ST-130
            assert(caller == COVERAGE);
            assert(spoke == BORROW);
            assert(hub.eliminateCalls() == 1 && hub.lastSpoke() == spoke && !hub.otherAssetTouched());
            assert(amount == Math.min(Math.min(maxAmount, ceilDeficit), funded));
            assert(amount > 0 && amount <= maxAmount && amount <= funded);
            assert(amount <= ceilDeficit);
            assert(cs.totalCovered() == amount);
        } else {
            assert(hub.eliminateCalls() == 0);
        }
    }

    // PROP-039 verifies: REQ-FLR-016, REQ-FLR-018, REQ-FLR-031, SPEC-FLR-001, Q-101, Q-142
    /// @notice The coverage role's call on an allowlisted Spoke succeeds whenever the deficit, `maxAmount` and the
    /// funded balance are all non-zero: a short reserve covers partially instead of reverting.
    /// @dev With the coverage role, the allowlisted Spoke and a deficit above 0, the reserve's only remaining revert is
    /// `NothingToCover` when `min(min(maxAmount, Math.ceilDiv(deficit, RAY)), funded)` is 0, which needs the ceiling
    /// term to be 0 here. MATH-ST-130 proves `Math.ceilDiv(deficit, RAY) ≥ 1` for every deficit above 0, so the last
    /// assumption excludes no input; it states the fact on the code's own term, so no query needs the division's
    /// semantics. The recording Hub cannot revert (its arithmetic is unchecked, equal to the checked form by
    /// MATH-ST-130).
    function check_PROP_039_coverDeficitLive(
        uint256 maxAmount,
        uint256 deficit,
        uint256 funded
    ) public {
        vm.assume(deficit > 0 && deficit < (1 << 200));
        vm.assume(funded > 0 && funded < (1 << 128));
        vm.assume(maxAmount > 0);
        vm.assume(Math.ceilDiv(deficit, RAY) > 0);
        hub.setDeficitRay(ASSET_ID, BORROW, deficit);
        hub.setFunded(funded);
        vm.prank(COVERAGE);
        (bool ok,) = address(cs).call(abi.encodeCall(IAvanaFirstLossReserve.coverDeficit, (BORROW, maxAmount)));
        assert(ok);
    }

    // PROP-060 verifies: REQ-FLR-004, REQ-FLR-040, INV-042, INV-071, Q-236
    /// @notice No call of any selector, by any caller, names another Hub asset or changes another asset's deficit.
    function check_PROP_060_noCallTouchesAnotherAsset(
        address caller,
        bytes4 selector,
        address a,
        uint256 v,
        uint256 otherDeficit
    ) public {
        hub.setDeficitRay(OTHER_ASSET_ID, BORROW, otherDeficit);
        hub.setDeficitRay(ASSET_ID, BORROW, 7e27);
        hub.setFunded(5000e18);
        vm.prank(caller);
        (bool ok,) = address(cs).call(abi.encodePacked(selector, abi.encode(a, v)));
        ok;
        assert(!hub.otherAssetTouched());
        assert(hub.getSpokeDeficitRay(OTHER_ASSET_ID, BORROW) == otherDeficit);
    }

    // PROP-060 verifies: REQ-FLR-005, REQ-FLR-010, REQ-FLR-040, INV-071, Q-236
    /// @notice `fund(amount)` moves exactly `amount` of the asset from the caller to the Hub, adds once on
    /// `ASSET_ID`, eliminates nothing and moves no other token.
    function check_PROP_060_fundMovesExactlyItsAsset(
        uint256 amount
    ) public {
        vm.assume(amount <= (1 << 128));
        uint256 callerBefore = token.balanceOf(FUNDER);
        uint256 hubBefore = token.balanceOf(address(hub));
        uint256 otherBefore = otherToken.balanceOf(FUNDER);
        vm.prank(FUNDER);
        (bool ok,) = address(cs).call(abi.encodeCall(IAvanaFirstLossReserve.fund, (amount)));
        if (ok) {
            assert(amount > 0);
            assert(token.balanceOf(FUNDER) == callerBefore - amount);
            assert(token.balanceOf(address(hub)) == hubBefore + amount);
            assert(hub.addCalls() == 1 && hub.lastAmount() == amount && !hub.otherAssetTouched());
            assert(hub.eliminateCalls() == 0 && hub.removeCalls() == 0);
            assert(token.balanceOf(address(cs)) == 0);
        } else {
            assert(amount == 0);
        }
        assert(otherToken.balanceOf(FUNDER) == otherBefore);
    }
}
