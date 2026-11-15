// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4PoolKey} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {ClPriceStateView} from "../../src/oracle/lp-oracle/types/ClPriceStateView.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleV4Fixture} from "../utils/fixtures/LPOracleV4Fixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice The Uniswap v4 LPOracle module on a native ETH/USDC v4 pool: composition at the oracle price, the spot gate
/// and the reference TWAP keeping the market Live, a parked pool failing closed to Drifting, the PoolManager's lock,
/// the quote-change cap, hooked keys refused at `initialize`, and the listing check of the reference pool.
/// forge-config: default.isolate = false
contract LPOracleV4UnitTest is LPOracleV4Fixture {
    function setUp() public {
        _deployV4Market();
    }

    // TEST-331 verifies: REQ-AMM-V4-005, SPEC-AMM-V4-001, SPEC-AMM-V4-002, REQ-ORACLE-014
    function test_TEST_331_liveAtTheOraclePriceWithBothReadsInTolerance() public view {
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "Live, not Drifting");
        assertEq(v.reasons & (LPOracleCodes.CONSISTENCY_UNAVAILABLE | LPOracleCodes.CONSISTENCY_DEVIATION), 0);
        assertGt(oracle.latestAnswer(), 0);
        ClPriceStateView memory r = oracle.getClPriceState();
        assertLe(r.tickDeviation, 2);
        assertEq(r.tickLower, LOWER);
    }

    // TEST-331 verifies: REQ-AMM-V4-005, SPEC-AMM-V4-001, SPEC-AMM-V4-002, REQ-AMM-CORE-006
    function test_TEST_331_parkedPoolFailsClosedAndTheQuoteHolds() public {
        int256 before = oracle.latestAnswer();
        (uint160 s,) = _slot0V4(key);
        _swapV4To(key, uint160((uint256(s) * 97) / 100));
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "spot gate stops borrowing");
        assertTrue(v.reasons & LPOracleCodes.CONSISTENCY_DEVIATION != 0);
        assertFalse(v.borrowAllowed);
        assertEq(oracle.latestAnswer(), before, "composition at the oracle price");
    }

    // TEST-331 verifies: REQ-AMM-V4-003, REQ-AMM-V4-011
    function test_TEST_331_readInsideUnlockIsPoolLocked() public {
        (bool ok, bytes memory ret) = v4Actor.callInside(address(oracle), abi.encodeCall(oracle.getPriceState, ()));
        assertTrue(ok);
        PriceStateView memory v = abi.decode(ret, (PriceStateView));
        assertTrue(v.reasons & LPOracleCodes.POOL_REENTRANCY_LOCKED != 0, "locked");
        assertEq(uint8(v.state), uint8(PriceState.Cached));
    }

    // TEST-331 verifies: REQ-AMM-V4-005, REQ-AMM-CORE-014
    function test_TEST_331_quoteChangeCapHoldsAOneBlockMove() public {
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live));
        vm.warp(block.timestamp + 1);
        // Both tokens 2% lower: the price ratio, and so the spot gate and the TWAP check, are unchanged, while the quote
        // moves 2%, past the 1% cap.
        _setPrices(price0 * 98 / 100, price1 * 98 / 100);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "capped in the poke's block");
        assertTrue(v.reasons & LPOracleCodes.QUOTE_CHANGE_CAPPED != 0);
    }

    // TEST-331 verifies: REQ-AMM-V4-001, REQ-AMM-V4-007, REQ-ORACLE-058
    function test_TEST_331_initializeRefusesHookedKeysAndForeignReferences() public {
        UniswapV4PoolKey memory hooked = _v4Key();
        hooked.hooks = address(0x80);
        _expectInitRefused(_market(hooked, address(ref)));
        _expectInitRefused(_market(_v4Key(), address(usdc)));
        UniswapV4PoolKey memory other = _v4Key();
        other.fee = 3000;
        other.tickSpacing = 60;
        _expectInitRefused(_market(other, address(ref)));
    }

    // TEST-331 verifies: REQ-AMM-V4-007, REQ-ORACLE-105
    function test_TEST_331_listingChecksTheIntegrationsReferencePool() public {
        integration.setBound(true);
        assertEq(oracle.checkConfig(_config()), 0, "clean");
        integration.setMarket(_v4Key(), address(0xBEEF), 0);
        uint256 failed = oracle.checkConfig(_config());
        assertTrue(failed & ((1 << 9) << LPOracleCodes.MODULE_CHECKS_SHIFT) != 0, "reference mismatch");
    }

    function _expectInitRefused(
        bytes memory market
    ) internal {
        address impl = address(implementation);
        bytes memory init = abi.encodeCall(ILPOracle.initialize, (_withMarket(market)));
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, MARKET));
        new ERC1967Proxy(impl, init);
    }

    function _withMarket(
        bytes memory market
    ) internal view returns (InitParams memory p) {
        p = _params();
        p.market = market;
    }
}
