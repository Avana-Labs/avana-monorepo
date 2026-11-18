// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {DebtReserveParams} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @notice Loosen setters: strictly looser, within bounds, one step, at most once per `normalDelay` per key.
contract ParameterStoreLoosenUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore();
        _listMarket();
    }

    function _key(
        bytes32 name,
        bytes32 scope
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(name, scope));
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-CONFIG-071, SPEC-GOV-011, Q-246, REQ-ACCESS-041
    function test_TEST_225_slippageStep() public {
        bytes32 key = _key("slippageAllowanceBps", bytes32(M));
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.LoosenStepTooLarge.selector, key));
        store.loosenSlippageAllowanceBps(M, 126);
        _tl();
        store.loosenSlippageAllowanceBps(M, 125);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotLooser.selector);
        store.loosenSlippageAllowanceBps(M, 125);
        vm.warp(block.timestamp + 432_000);
        _tl();
        store.loosenSlippageAllowanceBps(M, 150);
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 150);
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-RISK-043, REQ-RISK-044, SPEC-CAP-006, SPEC-GOV-011, REQ-ACCESS-049
    function test_TEST_225_marketCapStepAndAddCap() public {
        bytes32 key = _key("marketUsdCap", bytes32(M));
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.LoosenStepTooLarge.selector, key));
        store.loosenMarketUsdCap(M, 7_500_000e8 + 1);
        // Registered: activation checks the Hub addCap, so a small addCap does not block the write.
        hub.setAddCap(1);
        _tl();
        store.loosenMarketUsdCap(M, 7_500_000e8);
        assertEq(store.marketUsdCap(M), 7_500_000e8);
        _activate();
        vm.warp(block.timestamp + 432_000);
        // Active: (7.6M + 0.5M) / $1.00 = 8.1M whole tokens needed.
        hub.setAddCap(8_099_999);
        _tl();
        vm.expectRevert(IParameterStoreBase.AddCapTooSmall.selector);
        store.loosenMarketUsdCap(M, 7_600_000e8);
        hub.setAddCap(8_100_000);
        _tl();
        store.loosenMarketUsdCap(M, 7_600_000e8);
    }

    // TEST-225 verifies: SPEC-CAP-006, REQ-RISK-044
    function test_TEST_225_addCapUsesBookedCounters() public {
        _activate();
        // R above the new cap: the bound is (max(cap, R) + max(slice, S)) / floor.
        collateralization.setUsed(9_000_000e8, 0);
        hub.setAddCap(9_400_000);
        _tl();
        vm.expectRevert(IParameterStoreBase.AddCapTooSmall.selector);
        store.loosenMarketUsdCap(M, 6_000_000e8);
        hub.setAddCap(9_500_000);
        _tl();
        store.loosenMarketUsdCap(M, 6_000_000e8);
        // MAX_ALLOWED_SPOKE_CAP passes whatever the counters.
        hub.setAddCap(type(uint40).max);
        _tl();
        store.loosenTopUpSliceUsd(M, 600_000e8);
    }

    // TEST-225 verifies: REQ-PSTORE-017, SPEC-GOV-011, REQ-ACCESS-049
    function test_TEST_225_sliceRestoredFromTenthOfCap() public {
        _tl();
        store.tightenTopUpSliceUsd(M, 0);
        // base = max(0, ⌊5,000,000 / 10⌋) = 500,000; 1.5 × base = 750,000.
        bytes32 key = _key("topUpSliceUsd", bytes32(M));
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.LoosenStepTooLarge.selector, key));
        store.loosenTopUpSliceUsd(M, 750_000e8 + 1);
        _tl();
        store.loosenTopUpSliceUsd(M, 750_000e8);
        vm.warp(block.timestamp + 432_000);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenTopUpSliceUsd(M, 5_000_000e8 + 1);
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-PSTORE-026, Q-246
    function test_TEST_225_hubCapsHaveTheirOwnKeys() public {
        address h = address(hub);
        _tl();
        store.loosenTokenUsdCap(h, usdc, 30_000_000e8);
        // Another scope (the market cap) is spaced independently.
        _tl();
        store.loosenMarketUsdCap(M, 7_500_000e8);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(
                IParameterStoreBase.LoosenTooSoon.selector,
                _key("tokenUsdCap", keccak256(abi.encode(h, usdc))),
                block.timestamp + 432_000
            )
        );
        store.loosenTokenUsdCap(h, usdc, 31_000_000e8);
        // A pair with no cap cannot be loosened into existence, not even to the $1,000 reopen base (REQ-PSTORE-026).
        bytes memory noCap = abi.encodeWithSelector(
            IParameterStoreBase.LoosenStepTooLarge.selector, _key("tokenUsdCap", keccak256(abi.encode(h, usdt)))
        );
        _tl();
        vm.expectRevert(noCap);
        store.loosenTokenUsdCap(h, usdt, 1);
        _tl();
        vm.expectRevert(noCap);
        store.loosenTokenUsdCap(h, usdt, 1000e8);
        // Its listing then writes the cap it intends, once.
        _tl();
        store.setInitialTokenCap(h, usdt, 12_000_000e8);
        assertEq(store.tokenUsdCap(h, usdt), 12_000_000e8, "the listing's cap");
        _tl();
        vm.expectRevert(IParameterStoreBase.NotInListing.selector);
        store.setInitialTokenCap(h, usdt, 20_000_000e8);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenTokenUsdCap(h, usdc, uint256(type(uint128).max) + 1);
    }

    // TEST-225 verifies: REQ-PSTORE-016, REQ-PSTORE-018, REQ-PSTORE-020, REQ-PSTORE-030, REQ-PSTORE-005, Q-399, REQ-ACCESS-165
    function test_TEST_225_breakerShortfallStressPledge() public {
        address h = address(hub);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenBreakerDeficitMax(h, gho, 100_000e18 + 1);
        _tl();
        store.loosenBreakerDeficitMax(h, gho, 100_000e18);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.UnknownDebtReserve.selector, address(0), 0));
        store.loosenBreakerDeficitMax(h, usdc, 1);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.UnknownHub.selector, address(0)));
        store.loosenBreakerDeficitMax(address(0), gho, 1);
        _tl();
        store.loosenGateRecoverySeconds(600);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenGateRecoverySeconds(300);
        _tl();
        store.loosenMaxShortfallBps(5000);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenMaxShortfallBps(5001);
        _tl();
        store.tightenDebtStressRiseBps(usdc, 500);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenDebtStressRiseBps(usdc, 99);
        _tl();
        store.loosenDebtStressRiseBps(usdc, 100);
        _tl();
        store.loosenMinPledgeUsd(M, 0);
        assertEq(store.minPledgeUsd(M), 0);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotLooser.selector);
        store.loosenMinPledgeUsd(M, 0);
    }

    // TEST-246 verifies: REQ-CONFIG-050, REQ-PSTORE-006, Q-380, Q-397, REQ-ACCESS-132
    function test_TEST_246_roundingAllowanceWorthOneDollar() public {
        _tl();
        store.setDebtAssetParams(gho, DebtReserveParams(5e17));
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenFloorRoundingAllowance(gho, 1e18 + 1);
        _tl();
        store.loosenFloorRoundingAllowance(gho, 1e18);
        // A price source above $1 lowers the bound; a failed read refuses any raise.
        ghoPrice.setAnswer(2e8);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setDebtAssetParams(gho, DebtReserveParams(5e17 + 1));
        ghoPrice.setAnswer(0);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setDebtAssetParams(gho, DebtReserveParams(1));
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.TokenNotListed.selector, usdc));
        store.setDebtAssetParams(usdc, DebtReserveParams(1));
    }

    // TEST-225 verifies: REQ-PSTORE-017, SPEC-GOV-011, Q-246
    function testFuzz_TEST_225_capStepExact(
        uint256 value
    ) public {
        value = bound(value, 5_000_000e8 + 1, 20_000_000e8);
        _tl();
        (bool ok,) = address(store).call(abi.encodeCall(store.loosenMarketUsdCap, (M, value)));
        assertEq(ok, value * 10_000 <= 5_000_000e8 * 15_000);
    }

    // TEST-225 verifies: REQ-PSTORE-017, SPEC-GOV-011
    function testFuzz_TEST_225_spacing(
        uint256 dt
    ) public {
        dt = bound(dt, 0, 1_000_000);
        _tl();
        store.loosenSlippageAllowanceBps(M, 110);
        vm.warp(block.timestamp + dt);
        _tl();
        (bool ok,) = address(store).call(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 120)));
        assertEq(ok, dt >= 432_000);
    }
}
