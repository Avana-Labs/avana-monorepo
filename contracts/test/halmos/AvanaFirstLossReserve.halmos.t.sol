// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserveAdmin} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserveAdmin.sol";
import {MockAuthority} from "../utils/mocks/MockAuthority.sol";
import {MockDebtAsset} from "../utils/mocks/MockDebtAsset.sol";
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
        uint256 dRay = amount < (d + RAY - 1) / RAY ? amount * RAY : d;
        deficitRay[assetId][spoke] = d - dRay;
        return (amount, (dRay + RAY - 1) / RAY);
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
/// two-holder stand-in. Unit and fuzz tests run the same properties against the pinned Aave V4 Hub. The two
/// PROP-039 checks time out on the 256-bit division by RAY (60 s per query); their 10,000-run fuzz twins are
/// `testFuzz_TEST_199_coverOnlyByRoleForAllowlistedAndLive` and `testFuzz_TEST_199_coverageIsThreeWayMin`.
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
    function check_PROP_039_coverDeficitBoundedAndAllowlisted(
        address caller,
        address spoke,
        uint256 maxAmount,
        uint256 deficit,
        uint256 funded
    ) public {
        vm.assume(deficit < (1 << 200));
        vm.assume(funded < (1 << 128));
        hub.setDeficitRay(ASSET_ID, spoke, deficit);
        hub.setFunded(funded);
        vm.prank(caller);
        (bool ok,) = address(cs).call(abi.encodeCall(IAvanaFirstLossReserve.coverDeficit, (spoke, maxAmount)));
        if (ok) {
            uint256 amount = hub.lastAmount();
            assert(caller == COVERAGE);
            assert(spoke == BORROW);
            assert(hub.eliminateCalls() == 1 && hub.lastSpoke() == spoke && !hub.otherAssetTouched());
            assert(amount > 0 && amount <= maxAmount && amount <= funded);
            assert(amount <= (deficit + RAY - 1) / RAY);
            assert(cs.totalCovered() == amount);
        } else {
            assert(hub.eliminateCalls() == 0);
        }
    }

    // PROP-039 verifies: REQ-FLR-016, REQ-FLR-018, REQ-FLR-031, SPEC-FLR-001, Q-101, Q-142
    /// @notice The coverage role's call on an allowlisted Spoke succeeds whenever the deficit, `maxAmount` and the
    /// funded balance are all non-zero: a short reserve covers partially instead of reverting.
    function check_PROP_039_coverDeficitLive(
        uint256 maxAmount,
        uint256 deficit,
        uint256 funded
    ) public {
        vm.assume(deficit > 0 && deficit < (1 << 200));
        vm.assume(funded > 0 && funded < (1 << 128));
        vm.assume(maxAmount > 0);
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
