// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";

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

    // TEST-174 verifies: REQ-HELPER-010
    /// @notice A credit standing before the call is not this caller's: it stays for `claimEscrowed`, while the new one
    /// is not merged into it.
    function test_TEST_174_standingCreditStaysForClaimEscrowed() public {
        weth.setBlocked(address(helper), true);
        weth.setBlocked(caller, true);
        lvs.addResidue(weth, 0.4e18);
        _run(address(helper));
        assertEq(escrow.claimable(address(weth), address(helper)), 0.4e18, "caller blocked: credit stands");
        weth.setBlocked(caller, false);
        _run(address(helper));
        assertEq(weth.balanceOf(caller), 0, "a standing credit never goes to a later caller");
        assertEq(escrow.claimable(address(weth), address(helper)), 0.8e18, "both credits stand");
        uint256 claimed = helper.claimEscrowed(address(weth));
        assertEq(claimed, 0.8e18);
        assertEq(weth.balanceOf(feeRecipient), 0.8e18, "to feeRecipient");
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
