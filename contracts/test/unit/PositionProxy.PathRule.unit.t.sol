// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PositionProxyPathRuleUnitTest
/// @notice The vault-token path rule with real PositionProxies (TEST-189): proxies the real ProxyManager created for
/// the real AaveAdapter, registered in the real vault token, on the real local Aave V4. A registered proxy holding
/// units (withdrawn from the Hub, the allowed path) cannot send them anywhere but the Hub, two registered proxies
/// cannot trade units, LPVaultSwap cannot pass seized units on, and the proxy itself runs calls only for the Adapter.
/// forge-config: default.isolate = false
contract PositionProxyPathRuleUnitTest is AaveAdapterFixture {
    uint256 internal constant HELD = 1_000_000;

    address internal pA;
    address internal pB;

    function setUp() public override {
        super.setUp();
        (, pA) = _pledgeAs(alice, MARKET_ID, UNITS);
        (, pB) = _pledgeAs(bob, MARKET_ID, UNITS);
        // The Hub-to-proxy path: the proxy's own withdrawal leaves units on the proxy.
        vm.prank(pA);
        IAaveV4Spoke(aave.cdpSpoke).withdraw(vtReserveId, HELD, pA);
        assertEq(token.balanceOf(pA), HELD, "units on the proxy");
    }

    function _refused(
        address from,
        address to
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, from, to));
        vm.prank(from);
        IERC20(vt).transfer(to, 1);
    }

    // TEST-189 verifies: REQ-VTOKEN-006, REQ-VTOKEN-040, REQ-VTOKEN-041, INV-012, ATTACK-125
    // Sources: 5.1 TEST-189, Q-120, Q-224
    /// @notice From a real registered proxy, a transfer to the Adapter, the LPVault, Collateralization, the CDP Spoke,
    /// the MarketRegistry, an EOA, an unregistered contract and another registered proxy reverts
    /// `UnauthorizedTransfer(from, to)`, and so does a `transferFrom` by the second proxy whatever the allowance; only
    /// the Hub accepts the units back.
    function test_TEST_189_registeredProxySendsOnlyToTheHub() public {
        address[8] memory targets =
            [adapter, address(lpVault), address(coll), aave.cdpSpoke, address(registry), carol, address(lock), pB];
        for (uint256 i = 0; i < targets.length; ++i) {
            _refused(pA, targets[i]);
        }
        assertTrue(token.isValidProxy(pB), "both proxies registered");
        vm.prank(pA);
        IERC20(vt).approve(pB, HELD);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, pA, pB));
        vm.prank(pB);
        IERC20(vt).transferFrom(pA, pB, 1);
        vm.prank(pA);
        IERC20(vt).transfer(aave.hub, HELD);
        assertEq(token.balanceOf(pA), 0, "back in the Hub");
    }

    // TEST-189 verifies: REQ-VTOKEN-040, REQ-VTOKEN-041, ATTACK-125
    /// @notice Senders are checked too: units seized by LPVaultSwap cannot go to the Hub or anywhere else, the Hub
    /// cannot send to itself, and the Adapter can send nowhere.
    function test_TEST_189_senderSideRefusals() public {
        _borrowAs(bob, MARKET_ID, debtReserveId, 15_000e18);
        vtPrice.set(1.6e8);
        uint256 kept = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, pB, 2000e18);
        assertGt(kept, 0, "seized units at LPVaultSwap");
        _refused(lpVaultSwap, aave.hub);
        _refused(lpVaultSwap, pA);
        _refused(lpVaultSwap, carol);
        _refused(aave.hub, aave.hub);
        deal(vt, adapter, 1);
        _refused(adapter, aave.hub);
    }

    // TEST-189 verifies: REQ-PROXY-008, REQ-PROXY-048, INV-012
    /// @notice The second barrier: a PositionProxy executes calls only for the chain's AaveAdapter, so neither its
    /// wallet, nor another proxy, nor LPVaultSwap can make it call the vault token; its units stay where they are.
    function test_TEST_189_proxyRunsNoCallButTheAdapters() public {
        bytes memory move = abi.encodeCall(IERC20.transfer, (alice, HELD));
        address[3] memory callers = [alice, pB, lpVaultSwap];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.expectRevert();
            vm.prank(callers[i]);
            IPositionProxy(pA).execute(vt, move);
        }
        assertEq(IPositionProxy(pA).ADAPTER(), adapter, "the Adapter is the only caller it serves");
        assertEq(token.balanceOf(pA), HELD, "units unmoved");
    }
}
