// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../src/custody/lp-vault/ILPVault.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {MarketDef} from "../../src/types/MarketTypes.sol";
import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPOracleMock, RegistryLPVaultMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice The MarketRegistry holds nothing and changes no other contract: across every kind of write its only
/// non-static external call is the integration's `bindMarket` at listing, its only delegatecalls go to its own
/// implementation and logic contracts, no call carries value, it refuses ETH and NFT transfers, and a failed listing
/// leaves no trace in the registry or the integration.
contract MarketRegistryNoCustodyUnitTest is MarketRegistryFixture {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        _setUpWorld();
    }

    function _allowedDelegate(
        address target
    ) internal view returns (bool) {
        address impl = address(uint160(uint256(vm.load(address(registry), IMPLEMENTATION_SLOT))));
        return target == impl || target == logics.hubs || target == logics.listing || target == logics.activation
            || target == logics.routes || target == logics.windDown;
    }

    /// @dev Checks every access made from the registry's context: a CALL only to the LPVault's bindMarket, a
    /// DELEGATECALL only to the implementation or a logic contract, no value, no creation; returns the bindMarket count.
    function _checkAccesses(
        VmSafe.AccountAccess[] memory acc
    ) internal view returns (uint256 binds) {
        for (uint256 i = 0; i < acc.length; ++i) {
            VmSafe.AccountAccess memory a = acc[i];
            if (a.accessor != address(registry)) continue;
            assertEq(a.value, 0, "the registry sends no value");
            if (a.kind == VmSafe.AccountAccessKind.Call) {
                assertEq(a.account, address(lpVault), "a state-changing call to another contract");
                assertEq(bytes4(a.data), ILPVault.bindMarket.selector, "a call other than bindMarket");
                ++binds;
            } else if (a.kind == VmSafe.AccountAccessKind.DelegateCall) {
                assertTrue(_allowedDelegate(a.account), "a delegatecall outside the registry's own code");
            } else {
                assertTrue(
                    a.kind != VmSafe.AccountAccessKind.CallCode && a.kind != VmSafe.AccountAccessKind.Create
                        && a.kind != VmSafe.AccountAccessKind.SelfDestruct,
                    "callcode, create or selfdestruct from the registry"
                );
            }
        }
    }

    // TEST-168 verifies: REQ-CONFIG-003, REQ-CONFIG-004, REQ-MREG-028, Q-067, Q-104, Q-124, Q-248
    // Sources: 5.1 TEST-168
    // Every kind of write in one recorded sequence: listing (one bindMarket), routes, activation, the debt-reserve
    // record, offboarding, the wind-down and the close.
    function test_TEST_168_onlyBindMarketChangesAnotherContract() public {
        vm.startStateDiffRecording();
        (uint256 id, address vt,) = _listMarket();
        _prepareActivation(id, vt);
        vm.startPrank(governor);
        registry.activateMarket(id);
        registry.setSettlementReserve(id, GHO_RESERVE);
        registry.disableRoute(id, address(usdc), address(gho), 1);
        registry.setMarketOffboarding(id);
        vm.stopPrank();
        vm.warp(block.timestamp + 6 days);
        registry.closeMarket(id);
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertEq(_checkAccesses(acc), 1, "exactly one bindMarket for one listing");
    }

    // TEST-252 verifies: REQ-CONFIG-003, REQ-MREG-030
    // A relisting reads the integration's existing binding and makes no second bindMarket.
    function test_TEST_252_relistingMakesNoSecondBind() public {
        (uint256 id, address vt, RegistryLPOracleMock o) = _listMarket();
        vm.prank(governor);
        registry.cancelRegistration(id);
        vm.startStateDiffRecording();
        vm.prank(governor);
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        assertEq(_checkAccesses(vm.stopAndReturnStateDiff()), 0);
    }

    // TEST-168 verifies: REQ-CONFIG-003
    // The registry refuses ETH and has no NFT or multi-token receiver hook, so nothing can be parked in it.
    function test_TEST_168_refusesEthAndNftTransfers() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(registry).call{value: 1}("");
        assertFalse(ok, "ETH accepted");
        vm.prank(alice);
        (ok,) = address(registry).call{value: 1}(abi.encodeWithSignature("closeMarket(uint256)", uint256(1)));
        assertFalse(ok, "a payable path exists");
        bytes memory onNft =
            abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", alice, alice, 1, "");
        (ok,) = address(registry).call(onNft);
        assertFalse(ok, "ERC-721 receiver hook");
        bytes memory on1155 =
            abi.encodeWithSignature("onERC1155Received(address,address,uint256,uint256,bytes)", alice, alice, 1, 1, "");
        (ok,) = address(registry).call(on1155);
        assertFalse(ok, "ERC-1155 receiver hook");
        assertEq(address(registry).balance, 0);
    }

    // TEST-168 verifies: REQ-CONFIG-003, REQ-ACCESS-113
    // No rescue, sweep or approval selector exists on the registry.
    function test_TEST_168_noRescueSweepOrApprove() public {
        string[6] memory absent = [
            "sweep(address,address,uint256)",
            "rescue(address,address,uint256)",
            "rescueTokens(address,uint256)",
            "approve(address,uint256)",
            "setApprovalForAll(address,bool)",
            "withdraw(address,uint256)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            vm.prank(governor);
            (bool ok, bytes memory ret) = address(registry).call(abi.encodeWithSignature(absent[i], alice, alice, 1));
            assertFalse(ok);
            assertEq(ret.length, 0, "no such selector");
        }
    }

    // TEST-138 verifies: REQ-CONFIG-065, REQ-CONFIG-066, REQ-CONFIG-007
    // Sources: 5.1 TEST-138
    // A listing that fails any check after the integration bound the market reverts as a whole: no record, no index,
    // no count, and no binding left in the integration.
    function test_TEST_138_failedListingLeavesNoTrace() public {
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        o.setSeed(8, 0);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.ListingCheckFailed.selector, bytes32("lpOracle")));
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        assertEq(registry.marketCount(), 0);
        assertEq(registry.marketOfVaultToken(vt), 0);
        assertEq(registry.marketOfLpOracle(address(o)), 0);
        assertEq(registry.marketsOfSpoke(address(spoke)).length, 0);
        assertEq(uint8(registry.getMarket(1).status), 0);
        vm.expectRevert(RegistryLPVaultMock.MarketBinding.selector);
        lpVault.marketOf(1);
        // The same definition lists once the check passes, with the same identifier.
        o.setSeed(8, 1e8);
        vm.prank(governor);
        assertEq(registry.listCollateralMarket(_marketDef(vt, address(o))), 1);
    }

    // TEST-138 verifies: REQ-CONFIG-065, REQ-CONFIG-037
    // The LPOracle seed check: 8 decimals and an answer above 0, for this market and this integration; each part alone
    // fails.
    function test_TEST_138_lpOracleSeedEachPart() public {
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        bytes memory err = abi.encodeWithSelector(IMarketRegistryBase.ListingCheckFailed.selector, bytes32("lpOracle"));
        o.setSeed(18, 1e8);
        vm.prank(governor);
        vm.expectRevert(err);
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        o.setSeed(8, -1);
        vm.prank(governor);
        vm.expectRevert(err);
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        // An oracle of another market, and one of another integration, each behind its own vault token.
        _expectSeedRefused(new RegistryLPOracleMock(2, address(lpVault)), PositionShape(ShapeKind.TickRange, -10, 10));
        _expectSeedRefused(new RegistryLPOracleMock(1, alice), PositionShape(ShapeKind.TickRange, -20, 20));
        o.setSeed(8, 1);
        vm.prank(governor);
        assertEq(registry.listCollateralMarket(_marketDef(vt, address(o))), 1);
    }

    function _expectSeedRefused(
        RegistryLPOracleMock o,
        PositionShape memory sh
    ) internal {
        vm.prank(governor);
        address token = factory.deployVaultToken(
            V3, pool, bytes32(0), sh, address(hub), address(spoke), 1, address(o), 18, "Avana X", "avX"
        );
        MarketDef memory d = _marketDef(token, address(o));
        d.shape = sh;
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.ListingCheckFailed.selector, bytes32("lpOracle")));
        registry.listCollateralMarket(d);
    }
}
