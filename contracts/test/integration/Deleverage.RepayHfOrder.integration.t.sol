// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DeleverageRepayHfOrderIntegrationTest
/// @notice Repay with collateral reads `hfBefore` after LPVaultSwap pokes both oracles, on the real stack
/// (`RealStackFlows`): the real AaveAdapter, LPVaultSwap, market LPOracle and USDC DebtOracle. The other
/// repay-with-collateral tests are in `Deleverage.RepayWithCollateral.integration.t.sol`.
/// @dev Bob: 10,000 vault tokens at $2.00 ($20,000, CF 30 %) against 3,571 USDC (HF 1.68).
/// forge-config: default.isolate = false
contract DeleverageRepayHfOrderIntegrationTest is RealStackFlows {
    uint128 internal constant RELEASE = 150e6;

    uint256 internal mA;
    address internal proxy;
    bytes32 internal key;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        (key, proxy) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, usdcReserveId, 3571e6);
    }

    function _rwc(
        uint128 units,
        uint256 reserveId
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = _rwcParams(mA, key, units, reserveId);
    }

    /// @dev USDT at `price8` on every feed and in the market pool, the TWAP window waited, every feed republished and the
    /// route pools aligned, with no oracle poked: the LPOracle still holds the price it accepted at Bob's borrow.
    function _moveUsdtUnpoked(
        uint256 price8
    ) internal {
        _publish(address(usdt), price8);
        IClPool p = mkt[mA].pool;
        (ClTestToken t0, ClTestToken t1) = (ClTestToken(p.token0()), ClTestToken(p.token1()));
        _swapTo(
            p, ClPriceMath.oracleSqrtPrice(_usdPrice(address(t0)), _usdPrice(address(t1)), t0.decimals(), t1.decimals())
        );
        vm.warp(block.timestamp + TWAP_WAIT);
        vm.roll(block.number + TWAP_WAIT / BLOCK_TIME);
        _refreshFeeds();
        _alignRoutes();
    }

    /// @notice `hfBefore` is the health factor at the price Aave applies after LPVaultSwap's pokes. A poke that clears a
    /// token-decimals mark moves the price Aave reads within the block (REQ-ORACLE-107, `LPOraclePokeInvarianceUnitTest`):
    /// USDT falls to $0.82 (the vault token to about $1.81) and, while an issuer upgrade gives USDT 18 decimals, a poke
    /// marks the market's configuration invalid; USDT's decimals return to 6 and the market serves its accepted $2.00
    /// (Cached) until the next poke, then its fresh $1.81 (Live). At $1.81 Bob's HF is about 1.52 and releasing 150 units
    /// raises it to about 1.62; compared with the pre-poke 1.68 the call would revert `HealthFactorNotImproved` although
    /// it improves the account at the price Aave applies, and with the prices the other way round it would let a call
    /// that lowers the health factor through. Regression for `hfBefore` read before the pokes.
    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, SPEC-PROXY-009, REQ-ORACLE-107
    function test_TEST_239_hfBeforeIsReadAfterThePokes() public {
        _moveUsdtUnpoked(82_000_000);
        vm.mockCall(address(usdt), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        mkt[mA].oracle.poke();
        vm.clearMockedCalls();
        assertEq(uint8(mkt[mA].oracle.getPriceState().state), uint8(PriceState.Cached), "the mark holds until a poke");
        uint256 snap = vm.snapshotState();
        mkt[mA].oracle.poke();
        usdcOracle.poke();
        uint256 hfFresh = _hf(proxy);
        vm.revertToState(snap);
        uint256 hfAccepted = _hf(proxy);
        vm.recordLogs();
        vm.prank(bob);
        (uint256 repaid,) = adapterC.repayWithCollateral(_rwc(RELEASE, usdcReserveId));
        (uint256 hfBefore, uint256 hfAfter) = _hfLog(vm.getRecordedLogs());
        assertGt(repaid, 0, "settled");
        assertLt(hfFresh, hfAccepted, "the poke lowered the health factor Aave reads");
        assertEq(hfBefore, hfFresh, "hfBefore is the post-poke health factor");
        assertGt(hfAfter, hfBefore, "the call improved the account at the price Aave applies");
        assertLt(hfAfter, hfAccepted, "below the pre-poke health factor the old check compared with");
        assertEq(hfAfter, _hf(proxy), "hfAfter is Aave's");
    }

    function _hfLog(
        Vm.Log[] memory logs
    ) internal view returns (uint256 hfBefore, uint256 hfAfter) {
        bytes32 sig = IAaveAdapterEvents.RepaidWithCollateral.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == adapter && logs[i].topics[0] == sig) {
                (,,,,, hfBefore, hfAfter) =
                    abi.decode(logs[i].data, (bytes32, uint128, uint256, uint256, uint256, uint256, uint256));
                return (hfBefore, hfAfter);
            }
        }
        revert("no RepaidWithCollateral");
    }
}
