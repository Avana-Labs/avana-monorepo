// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapter} from "../../src/policy/aave-adapter/AaveAdapter.sol";
import {AaveAdapterCollateralLogic} from "../../src/policy/aave-adapter/AaveAdapterCollateralLogic.sol";
import {AaveAdapterExitLogic} from "../../src/policy/aave-adapter/AaveAdapterExitLogic.sol";
import {AaveAdapterSettlementLogic} from "../../src/policy/aave-adapter/AaveAdapterSettlementLogic.sol";
import {AaveAdapterUserLogic} from "../../src/policy/aave-adapter/AaveAdapterUserLogic.sol";
import {AaveAdapterLogics} from "../../src/policy/aave-adapter/types/AaveAdapterTypes.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @title AaveAdapterUpgradeRowsUnitTest
/// @notice No proxy upgrade path through the real AccessManager (TEST-191): an AaveAdapter upgrade to a second
/// reviewed implementation, scheduled by the governance multisig, waits the normal delay, changes nothing before it
/// ends, and after execution leaves every existing PositionProxy (three wallets, two markets on the fixture's CDP
/// Spoke) with its code, binding, Spoke supply and debt, driven by the new Adapter.
/// @dev The Adapter's authority is the suite's AccessManager (the governance multisig holds the governance role with
/// a 5-day execution delay; the DAO can cancel). The fixture has one CDP
/// Spoke; the second-Spoke case of the row is the same proxy code at another `SPOKE()` immutable.
/// forge-config: default.isolate = false
contract AaveAdapterUpgradeRowsUnitTest is AaveAdapterFixture {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address[3] internal wallets;
    address[6] internal proxies;
    bytes32[6] internal keys;
    uint256[6] internal marketOf;

    function setUp() public override {
        super.setUp();
        wallets = [alice, bob, carol];
        for (uint256 w = 0; w < 3; ++w) {
            for (uint256 m = 0; m < 2; ++m) {
                uint256 i = w * 2 + m;
                marketOf[i] = m == 0 ? MARKET_ID : MARKET_B;
                (keys[i], proxies[i]) = _pledgeAs(wallets[w], marketOf[i], UNITS);
            }
            _borrowAs(wallets[w], MARKET_ID, debtReserveId, 1000e18 * (w + 1));
        }
    }

    /// @dev A second reviewed implementation: the same immutables and fresh logic contracts.
    function _newImplementation() internal returns (address) {
        AaveAdapterLogics memory l = AaveAdapterLogics({
            user: address(new AaveAdapterUserLogic(im)),
            exit: address(new AaveAdapterExitLogic(im)),
            collateral: address(new AaveAdapterCollateralLogic(im)),
            settlement: address(new AaveAdapterSettlementLogic(im))
        });
        return address(new AaveAdapter(im, l));
    }

    // TEST-191 verifies: REQ-PROXY-050, REQ-PROXY-054, REQ-PROXY-086, REQ-PROXY-103, INV-065, ATTACK-123
    // Sources: 5.1 TEST-191, Q-225, Q-226, Q-228
    /// @notice The upgrade scheduled for 12 hours ahead reverts `AccessManagerUnauthorizedCall`; at the governance delay it is pending and
    /// changes nothing; once executed, every proxy created before it keeps its code hash, `WALLET()`, `SPOKE()`,
    /// `MARKET_ID()` and `ADAPTER()`, its Spoke supply and its debt, and the upgraded Adapter repays and withdraws
    /// debt-free through each of them.
    function test_TEST_191_adapterUpgradeLeavesEveryProxyAndDrivesIt() public {
        address impl = _newImplementation();
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, ""));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector, governanceMultisig, adapter, bytes4(data)
            )
        );
        vm.prank(governanceMultisig);
        accessManager.schedule(adapter, data, uint48(block.timestamp + 12 hours));

        bytes32[6] memory codeHashes;
        uint256[6] memory supplied;
        uint256[6] memory owed;
        for (uint256 i = 0; i < 6; ++i) {
            codeHashes[i] = proxies[i].codehash;
            supplied[i] = _sharesOf(proxies[i], marketOf[i] == MARKET_ID ? vtReserveId : vtReserveIdB);
        }
        address oldImpl = address(uint160(uint256(vm.load(adapter, IMPL_SLOT))));
        vm.prank(governanceMultisig);
        accessManager.schedule(adapter, data, 0);
        bytes32 id = accessManager.hashOperation(governanceMultisig, adapter, data);
        vm.warp(block.timestamp + NORMAL_DELAY - 1);
        vm.expectRevert();
        vm.prank(governanceMultisig);
        accessManager.execute(adapter, data);
        assertEq(address(uint160(uint256(vm.load(adapter, IMPL_SLOT)))), oldImpl, "nothing before the delay ends");
        assertGt(accessManager.getSchedule(id), block.timestamp, "pending");

        vm.warp(block.timestamp + 1);
        // Debt accrues interest over the delay; the upgrade itself, in this block, must not move it.
        for (uint256 i = 0; i < 6; ++i) {
            owed[i] = _debtOf(proxies[i], debtReserveId);
        }
        vm.prank(governanceMultisig);
        accessManager.execute(adapter, data);
        assertEq(address(uint160(uint256(vm.load(adapter, IMPL_SLOT)))), impl, "new Adapter installed");

        for (uint256 i = 0; i < 6; ++i) {
            address p = proxies[i];
            assertEq(p.codehash, codeHashes[i], "proxy code unchanged");
            assertEq(IPositionProxy(p).WALLET(), wallets[i / 2], "wallet");
            assertEq(IPositionProxy(p).SPOKE(), aave.cdpSpoke, "spoke");
            assertEq(IPositionProxy(p).MARKET_ID(), marketOf[i], "market");
            assertEq(IPositionProxy(p).ADAPTER(), adapter, "the chain's Adapter address");
            assertEq(_sharesOf(p, marketOf[i] == MARKET_ID ? vtReserveId : vtReserveIdB), supplied[i], "supply");
            assertEq(_debtOf(p, debtReserveId), owed[i], "debt");
            assertEq(adapterC.proxyOf(wallets[i / 2], marketOf[i]), p, "binding");
        }

        // The upgraded Adapter drives every pre-upgrade proxy: repay, then debt-free withdrawal.
        for (uint256 w = 0; w < 3; ++w) {
            address pa = proxies[w * 2];
            uint256 d = owed[w * 2];
            _fund(wallets[w], debtReserveId, d);
            vm.prank(wallets[w]);
            adapterC.repay(wallets[w], MARKET_ID, debtReserveId, d, true, _deadline());
            assertEq(_debtOf(pa, debtReserveId), 0, "repaid through the new Adapter");
            for (uint256 m = 0; m < 2; ++m) {
                uint256 i = w * 2 + m;
                vm.prank(wallets[w]);
                adapterC.withdraw(marketOf[i], _ref(keys[i]), UNITS, _deadline(), 0);
                assertEq(lpVault.ownerOf(keys[i]), wallets[w], "withdrawn through the new Adapter");
            }
        }
        assertEq(token.totalSupply() + tokenB.totalSupply(), 0, "every unit burned");
    }
}
