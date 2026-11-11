// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveV3FlashSource} from "../../../src/flash/AaveV3FlashSource.sol";
import {MockAaveV3ACLManager, MockAaveV3AddressesProvider, MockAaveV3Pool} from "../mocks/AaveV3PoolMocks.sol";
import {MockFlashReceiver} from "../mocks/MockFlashReceiver.sol";
import {PayoutToken} from "../mocks/PayoutToken.sol";
import {ParameterStoreFixture} from "./ParameterStoreFixture.sol";

/// @title FlashSourceFixture
/// @notice The chain's AaveV3FlashSource over a mocked Aave V3.4 Pool (ACLManager and PoolAddressesProvider mocked,
/// 5 bps premium charged half-up, virtual accounting, a USDC reserve with 18,000,000 USDC idle and recorded, the Base figure of 2.11 `REQ-FLASH-008`), reading
/// `maxFlashFeeBps` from the real ParameterStore (launch value 10), with a `MockFlashReceiver` at the LPVaultSwap address
/// holding 1,000,000 USDC to pay premiums. The liquidated Spoke's Hub is the fixture's MockHub.
abstract contract FlashSourceFixture is ParameterStoreFixture {
    uint128 internal constant POOL_PREMIUM_BPS = 5;
    uint256 internal constant IDLE_USDC = 18_000_000e6;
    uint256 internal constant RECEIVER_FUNDS = 1_000_000e6;

    MockAaveV3ACLManager internal acl;
    MockAaveV3AddressesProvider internal provider;
    MockAaveV3Pool internal aavePool;
    PayoutToken internal usdcToken;
    address internal aUsdc;
    MockFlashReceiver internal swap;
    AaveV3FlashSource internal source;

    function _deployFlashSource() internal {
        _deployStore(false);
        acl = new MockAaveV3ACLManager();
        provider = new MockAaveV3AddressesProvider(address(acl));
        aavePool = new MockAaveV3Pool(address(provider), POOL_PREMIUM_BPS);
        usdcToken = new PayoutToken("USDC", 6);
        aUsdc = aavePool.listReserve(address(usdcToken));
        usdcToken.mint(aUsdc, IDLE_USDC);
        aavePool.recordSupply(address(usdcToken), IDLE_USDC);
        swap = new MockFlashReceiver();
        source = new AaveV3FlashSource(address(aavePool), address(swap), address(store));
        swap.setSource(address(source));
        usdcToken.mint(address(swap), RECEIVER_FUNDS);
        vm.label(address(aavePool), "AaveV3Pool");
        vm.label(address(source), "AaveV3FlashSource");
        vm.label(address(swap), "LPVaultSwap");
        vm.label(address(usdcToken), "USDC");
    }

    /// @dev Sets `maxFlashFeeBps` through the timelock (the normal setter moves it either way within [0, 100]).
    function _setCap(
        uint256 bps
    ) internal {
        _tl();
        store.setMaxFlashFeeBps(uint16(bps));
    }

    /// @dev A second reserve: a fresh token listed on the Pool with `idle` units held by its aToken.
    function _listToken(
        string memory name,
        uint256 idle
    ) internal returns (PayoutToken token, address aToken) {
        token = new PayoutToken(name, 6);
        aToken = aavePool.listReserve(address(token));
        token.mint(aToken, idle);
        aavePool.recordSupply(address(token), idle);
    }
}
