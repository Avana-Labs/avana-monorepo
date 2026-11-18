// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashLiquidator} from "../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";

/// @notice A token-transfer hook that tries to reenter the helper and records the revert selector of its first try.
contract ReentryRecorder {
    address internal immutable TARGET;
    bytes internal data;
    bytes4 public firstSelector;
    uint256 public attempts;

    constructor(
        address target,
        bytes memory data_
    ) {
        TARGET = target;
        data = data_;
    }

    function poke() external {
        ++attempts;
        (, bytes memory ret) = TARGET.call(data);
        if (attempts == 1) firstSelector = ret.length >= 4 ? bytes4(ret) : bytes4(0);
    }
}

/// @notice A swap route as the helper reads it: only its `intermediates()`.
contract IntermediatesRoute {
    address[] internal _mids;
    bool public reverts;

    constructor(
        address[] memory mids
    ) {
        _mids = mids;
    }

    function setReverts(
        bool on
    ) external {
        reverts = on;
    }

    function intermediates() external view returns (address[] memory) {
        require(!reverts, "intermediates");
        return _mids;
    }
}

/// @title FlashLiquidatorResiduesUnitTest
/// @notice Every token LPVaultSwap pays the flash helper reaches the helper's caller: the market's tokens and the
/// intermediates of the market's swap routes (a partly filled multi-hop route returns its intermediate as a residue),
/// directly or, when the helper cannot receive it, through the PayoutEscrow in the same call (2.11 `REQ-HELPER-001`,
/// `REQ-HELPER-008`, `REQ-HELPER-010`).
/// forge-config: default.isolate = false
contract FlashLiquidatorResiduesUnitTest is FlashLiquidatorFixture {
    PayoutToken internal weth;
    PayoutToken internal dai;
    IntermediatesRoute internal primary;
    IntermediatesRoute internal backup;

    function setUp() public {
        _deployHelpers();
        weth = new PayoutToken("WETH", 18);
        dai = new PayoutToken("DAI", 18);
        address[] memory one = new address[](1);
        one[0] = address(weth);
        primary = new IntermediatesRoute(one);
        one[0] = address(dai);
        backup = new IntermediatesRoute(one);
        // USDT → WETH → USDC primary and USDT → DAI → USDC backup into the debt asset USDC.
        registry.setRouteRecord(MARKET_ID, address(usdtToken), address(usdcToken), 0, address(primary));
        registry.setRouteRecord(MARKET_ID, address(usdtToken), address(usdcToken), 1, address(backup));
    }

    function _run(
        address helperAddr
    ) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) =
            helperAddr.call(abi.encodeWithSelector(helper.flashLiquidate.selector, _exampleRequest()));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    // TEST-174 verifies: REQ-HELPER-001, REQ-HELPER-008
    /// @notice A 0.4 WETH intermediate of the primary route and 3 DAI of the backup's, paid to the helper as residues,
    /// are forwarded to the caller with the market-token residue; the helper keeps nothing.
    function test_TEST_174_routeIntermediatesForwardedToTheCaller() public {
        lvs.addResidue(weth, 0.4e18);
        lvs.addResidue(dai, 3e18);
        lvs.addResidue(usdtToken, 0.2e6);
        _run(address(helper));
        assertEq(weth.balanceOf(caller), 0.4e18, "WETH forwarded");
        assertEq(dai.balanceOf(caller), 3e18, "DAI forwarded");
        assertEq(usdtToken.balanceOf(caller), 0.2e6, "market token forwarded");
        assertEq(weth.balanceOf(address(helper)), 0, "nothing stranded");
        assertEq(dai.balanceOf(address(helper)), 0, "nothing stranded");
    }

    // TEST-174 verifies: REQ-HELPER-010, REQ-HELPER-008
    /// @notice An intermediate the helper cannot receive is escrowed for it and claimed to the caller in the same call.
    function test_TEST_174_escrowedIntermediateClaimedToTheCaller() public {
        weth.setBlocked(address(helper), true);
        lvs.addResidue(weth, 0.4e18);
        _run(address(helper));
        assertEq(escrow.claimable(address(weth), address(helper)), 0, "credit claimed in the call");
        assertEq(weth.balanceOf(caller), 0.4e18, "to the caller");
    }

    // TEST-174 verifies: REQ-HELPER-010, REQ-ESCROW-020
    /// @notice Audit finding L-04 (fresh audit 2026-11-15), option A: a credit standing before the call is not this
    /// caller's, so the call claims to its caller only the rise of the helper's credit over the call, with the
    /// amount-limited `PayoutEscrow.claim`. The standing 0.4 WETH is neither paid to the caller nor merged with its
    /// residue, and stays for `claimEscrowed`.
    function test_TEST_174_onlyTheCallsIncreaseClaimedToTheCaller() public {
        weth.setBlocked(address(helper), true);
        weth.setBlocked(caller, true);
        lvs.addResidue(weth, 0.4e18);
        _run(address(helper));
        assertEq(escrow.claimable(address(weth), address(helper)), 0.4e18, "caller blocked: the credit stands");
        weth.setBlocked(caller, false);
        // The next call is paid two WETH residues, 0.4 and 0.3, both escrowed for the helper.
        lvs.addResidue(weth, 0.3e18);
        _run(address(helper));
        assertEq(weth.balanceOf(caller), 0.7e18, "the caller received exactly its own residues");
        assertEq(escrow.claimable(address(weth), address(helper)), 0.4e18, "the standing credit is untouched");
        assertEq(weth.balanceOf(feeRecipient), 0, "nothing claimed to feeRecipient during the call");
        assertEq(helper.claimEscrowed(address(weth)), 0.4e18, "the standing credit goes through claimEscrowed");
        assertEq(weth.balanceOf(feeRecipient), 0.4e18, "to feeRecipient");
        assertEq(escrow.claimable(address(weth), address(helper)), 0, "nothing left");
    }

    // TEST-174 verifies: REQ-HELPER-010, REQ-ESCROW-020
    /// @notice A token that blocks both the helper and `feeRecipient` (the remainder option B of L-04 left): the later
    /// caller still receives only its own residue, the standing credit stays standing while `feeRecipient` cannot
    /// receive it, and `claimEscrowed` pays exactly the standing credit once it can.
    function test_TEST_174_helperAndFeeRecipientBlockedCallerGetsOnlyItsOwn() public {
        weth.setBlocked(address(helper), true);
        weth.setBlocked(caller, true);
        lvs.addResidue(weth, 0.4e18);
        _run(address(helper));
        weth.setBlocked(caller, false);
        weth.setBlocked(feeRecipient, true);
        _run(address(helper));
        assertEq(weth.balanceOf(caller), 0.4e18, "the later caller received its own residue");
        assertEq(weth.balanceOf(address(helper)), 0, "the helper holds nothing");
        assertEq(escrow.claimable(address(weth), address(helper)), 0.4e18, "only the standing credit remains");
        vm.expectRevert();
        helper.claimEscrowed(address(weth));
        weth.setBlocked(feeRecipient, false);
        assertEq(helper.claimEscrowed(address(weth)), 0.4e18);
        assertEq(weth.balanceOf(feeRecipient), 0.4e18, "to feeRecipient");
        assertEq(weth.balanceOf(caller), 0.4e18, "the caller never received the standing credit");
    }

    // TEST-174 verifies: REQ-HELPER-010, REQ-HELPER-004
    /// @notice `claimEscrowed` refuses to run while a call's context is open: a market-token callback during the call
    /// that tries it meets `ContextActive`, so it cannot move the call's new WETH credit, or the standing one, to
    /// `feeRecipient` before the call claims its rise to the caller.
    function test_TEST_174_claimEscrowedRefusedInsideTheContext() public {
        weth.setBlocked(address(helper), true);
        weth.setBlocked(caller, true);
        lvs.addResidue(weth, 0.4e18);
        _run(address(helper));
        weth.setBlocked(caller, false);
        ReentryRecorder recorder =
            new ReentryRecorder(address(helper), abi.encodeCall(helper.claimEscrowed, (address(weth))));
        // The USDT residue moves to the helper and on to the caller before the WETH credit is claimed.
        lvs.addResidue(usdtToken, 0.2e6);
        usdtToken.setHook(address(recorder), abi.encodeCall(ReentryRecorder.poke, ()));
        _run(address(helper));
        usdtToken.setHook(address(0), "");
        assertGt(recorder.attempts(), 0, "the USDT transfers called back");
        assertEq(recorder.firstSelector(), IFlashLiquidator.ContextActive.selector, "claim refused in the call");
        assertEq(weth.balanceOf(caller), 0.4e18, "the caller received its own residue");
        assertEq(weth.balanceOf(feeRecipient), 0, "nothing moved to feeRecipient during the call");
        assertEq(escrow.claimable(address(weth), address(helper)), 0.4e18, "the standing credit stands");
        assertEq(helper.claimEscrowed(address(weth)), 0.4e18, "claimEscrowed runs once the call is over");
    }

    // TEST-174 verifies: REQ-HELPER-008
    /// @notice A route whose `intermediates()` reverts adds nothing (LPVaultSwap does not swap through it either) and
    /// does not stop the liquidation.
    function test_TEST_174_revertingRouteReadSkipped() public {
        primary.setReverts(true);
        lvs.addResidue(dai, 3e18);
        _run(address(helper));
        assertEq(dai.balanceOf(caller), 3e18, "the backup's intermediate still forwarded");
    }

    // TEST-174 verifies: REQ-HELPER-008
    /// @notice A token named by both route slots is watched once: its residue is forwarded once, in full.
    function test_TEST_174_sharedIntermediateWatchedOnce() public {
        registry.setRouteRecord(MARKET_ID, address(usdtToken), address(usdcToken), 1, address(primary));
        lvs.addResidue(weth, 0.4e18);
        _run(address(helper));
        assertEq(weth.balanceOf(caller), 0.4e18, "forwarded once, in full");
        assertEq(weth.balanceOf(address(helper)), 0);
    }
}
