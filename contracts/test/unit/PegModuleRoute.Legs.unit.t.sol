// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PegModuleRoute} from "../../src/liquidation/settlement-routes/PegModuleRoute.sol";
import {PegModuleKind, PegModuleStep} from "../../src/liquidation/settlement-routes/types/PegModuleStep.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {RawAnswer} from "../utils/mocks/RouteReadTargets.sol";
import {MockDaiUsds, MockGsm, MockLitePsm, MockPsmAndConverter, MockVault4626} from "../utils/mocks/SwapRouteMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PegModuleRouteLegsUnitTest
/// @notice The peg-module legs in depth: the GSM route's fee-switch probe and wrapper reads, every LitePSM and
/// DAI/USDS converter check at deployment (conversion factor, gem, DAI, the output's decimals at and above 18, a module
/// that is also the converter), and the LitePSM purchase against an independent computation of `gemAmt` over random
/// DAI amounts and fees (the largest affordable gem amount, the DAI residue returned to LPVaultSwap, the exact DAI the
/// LitePSM charges), with the halt boundary `tout = 10^36`.
contract PegModuleRouteLegsUnitTest is SwapRouteFixture {
    uint256 internal constant C = 1e12;

    MockLitePsm internal psm;
    MockDaiUsds internal converter;

    function setUp() public override {
        super.setUp();
        psm = new MockLitePsm(address(dai), address(usdc), 6);
        usdc.mint(address(psm), 1e40);
        converter = new MockDaiUsds(address(usds), address(dai));
    }

    function _psmStep(
        address module
    ) internal pure returns (PegModuleStep memory) {
        return
            PegModuleStep({kind: PegModuleKind.LitePsm, module: module, wrapper: address(0), intermediate: address(0)});
    }

    function _usdsStep(
        address module,
        address conv
    ) internal view returns (PegModuleStep memory) {
        return PegModuleStep({kind: PegModuleKind.LitePsm, module: module, wrapper: conv, intermediate: address(dai)});
    }

    // ─── GSM deployment checks (REQ-ROUTE-008, REQ-ROUTE-045) ───

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-008 (a GSM input must not answer the fee-switch probe, fee on or off)
    /// @notice A GSM route whose input answers `basisPointsRate()` is refused with the fee off and on; the same legs
    /// over USDC are accepted and list USDC as their exact-amount input.
    function test_TEST_221_gsmInputMustNotAnswerTheProbe() public {
        MockVault4626 stataT = new MockVault4626(IERC20(address(tether)), "stataUSDT");
        MockGsm gsmT = new MockGsm(address(stataT), address(gho));
        PegModuleStep memory stepT = PegModuleStep({
            kind: PegModuleKind.Gsm, module: address(gsmT), wrapper: address(stataT), intermediate: address(stataT)
        });
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new PegModuleRoute(_config(address(tether), address(gho)), stepT);
        tether.setFeeBps(5);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new PegModuleRoute(_config(address(tether), address(gho)), stepT);
        MockVault4626 stataU = new MockVault4626(IERC20(address(usdc)), "stataUSDC");
        MockGsm gsmU = new MockGsm(address(stataU), address(gho));
        PegModuleRoute ok = new PegModuleRoute(
            _config(address(usdc), address(gho)),
            PegModuleStep({
                kind: PegModuleKind.Gsm, module: address(gsmU), wrapper: address(stataU), intermediate: address(stataU)
            })
        );
        address[] memory ex = ok.exactAmountInputs();
        assertEq(ex.length, 1);
        assertEq(ex[0], address(usdc));
    }

    // TEST-054 verifies: REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045 (a named contract that reverts or returns too little fails the check)
    /// @notice A GSM route whose static aToken's `asset()` reverts, or whose GSM's `UNDERLYING_ASSET()` or
    /// `GHO_TOKEN()` reverts, is refused.
    function test_TEST_054_gsmReadsFailClosed() public {
        RawAnswer bad = new RawAnswer();
        bad.setReverts(true);
        MockVault4626 stata = new MockVault4626(IERC20(address(usdc)), "stataUSDC");
        MockGsm gsm = new MockGsm(address(stata), address(gho));
        _expectBad(
            address(usdc), address(gho), PegModuleStep(PegModuleKind.Gsm, address(gsm), address(bad), address(bad))
        );
        _expectBad(
            address(usdc), address(gho), PegModuleStep(PegModuleKind.Gsm, address(bad), address(stata), address(stata))
        );
    }

    // ─── LitePSM and converter deployment checks (REQ-ROUTE-045) ───

    // TEST-054 verifies: REQ-ROUTE-045, REQ-ROUTE-012
    // Sources: 2.12 REQ-ROUTE-045 (gem() is TOKEN_OUT, dai() the DAI spent, to18ConversionFactor 10^(18 - decimals))
    /// @notice A LitePSM whose conversion factor does not match the output's decimals, whose `gem()` is another token
    /// or whose `dai()` is not the DAI the route spends is refused; an output whose `decimals()` reverts is refused; an
    /// output of 18 decimals with a factor of 1 is accepted.
    function test_TEST_054_litePsmChecks() public {
        MockLitePsm wrongFactor = new MockLitePsm(address(dai), address(usdc), 18);
        _expectBad(address(dai), address(usdc), _psmStep(address(wrongFactor)));
        MockLitePsm wrongGem = new MockLitePsm(address(dai), address(usdt), 6);
        _expectBad(address(dai), address(usdc), _psmStep(address(wrongGem)));
        MockLitePsm wrongDai = new MockLitePsm(address(usds), address(usdc), 6);
        _expectBad(address(dai), address(usdc), _psmStep(address(wrongDai)));
        RawAnswer noDecimals = new RawAnswer();
        noDecimals.setReverts(true);
        MockLitePsm psmNoDec = new MockLitePsm(address(dai), address(noDecimals), 6);
        _expectBad(address(dai), address(noDecimals), _psmStep(address(psmNoDec)));
        PayoutToken gem18 = new PayoutToken("G18", 18);
        MockLitePsm psm18 = new MockLitePsm(address(dai), address(gem18), 18);
        PegModuleRoute ok = new PegModuleRoute(_config(address(dai), address(gem18)), _psmStep(address(psm18)));
        assertEq(ok.exactAmountInputs().length, 0, "the LitePSM credits what it pulls");
        assertEq(ok.dependencies()[0], address(psm18));
    }

    // TEST-054 verifies: REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045 (the converter's usds() is TOKEN_IN, its dai() the step's output)
    /// @notice A USDS route whose converter answers another `usds()` or another `dai()`, or whose converter reverts,
    /// is refused; a contract that is both the LitePSM and the converter is refused as one contract named twice; the
    /// correct legs list the converter and the LitePSM, and DAI as the intermediate.
    function test_TEST_054_converterChecks() public {
        MockDaiUsds otherUsds = new MockDaiUsds(address(usdt), address(dai));
        _expectBad(address(usds), address(usdc), _usdsStep(address(psm), address(otherUsds)));
        MockDaiUsds otherDai = new MockDaiUsds(address(usds), address(gho));
        _expectBad(address(usds), address(usdc), _usdsStep(address(psm), address(otherDai)));
        RawAnswer bad = new RawAnswer();
        bad.setReverts(true);
        _expectBad(address(usds), address(usdc), _usdsStep(address(psm), address(bad)));
        MockPsmAndConverter both = new MockPsmAndConverter(address(dai), address(usdc), address(usds), 6);
        _expectBad(address(usds), address(usdc), _usdsStep(address(both), address(both)));
        PegModuleRoute ok =
            new PegModuleRoute(_config(address(usds), address(usdc)), _usdsStep(address(psm), address(converter)));
        address[] memory deps = ok.dependencies();
        assertEq(deps.length, 2);
        assertEq(deps[0], address(converter));
        assertEq(deps[1], address(psm));
        assertEq(ok.intermediates()[0], address(dai));
        assertEq(ok.exactAmountInputs().length, 0);
    }

    // ─── LitePSM purchase (REQ-ROUTE-012, REQ-ROUTE-015) ───

    // TEST-054 verifies: REQ-ROUTE-012, REQ-ROUTE-015, REQ-ROUTE-010, REQ-ROUTE-016, INV-021
    // Sources: 2.12 REQ-ROUTE-012 (g0 = floor(D x 10^18 / ((10^18 + tout) x c)), g0 + 1 when cost(g0 + 1) <= D)
    /// @notice For DAI amounts from 1 wei to 10^27 and fees up to 10 %: the route buys exactly the largest affordable
    /// gem amount (computed here independently), the LitePSM charges `cost(gemAmt)` DAI, the rest of the DAI returns to
    /// LPVaultSwap, no allowance is left, and an amount below one gem unit buys nothing and reverts `MinOutNotMet(0,1)`.
    function testFuzz_TEST_054_litePsmBuysTheLargestAffordableAmount(
        uint256 d,
        uint256 tout
    ) public {
        d = bound(d, 1, 1e27);
        tout = bound(tout, 0, 1e17);
        psm.setTout(tout);
        PegModuleRoute route = new PegModuleRoute(_config(address(dai), address(usdc)), _psmStep(address(psm)));
        uint256 g = d * 1e18 / ((1e18 + tout) * C);
        if (_cost(g + 1, tout) <= d) g += 1;
        assertLe(_cost(g, tout), d, "affordable");
        assertGt(_cost(g + 1, tout), d, "largest");
        dai.mint(address(swapper), d);
        if (g == 0) {
            vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
            swapper.swapUnderLock(route, d, 1);
            return;
        }
        uint256 out = swapper.swapUnderLock(route, d, g);
        assertEq(out, g, "gem bought");
        assertEq(psm.lastDaiIn(), _cost(g, tout), "DAI charged");
        assertEq(dai.balanceOf(address(swapper)), d - _cost(g, tout), "DAI residue back to LPVaultSwap");
        assertEq(dai.allowance(address(route), address(psm)), 0);
        assertEq(dai.balanceOf(address(route)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-012
    // Sources: 2.12 REQ-ROUTE-012 (tout >= 10^36 buys nothing)
    /// @notice With 10^40 DAI, a fee of `10^36 - 1` still affords a gem amount and buys it; a fee of exactly `10^36`
    /// buys nothing, makes no LitePSM call and reverts `MinOutNotMet(0, 1)`.
    function test_TEST_054_haltBoundaryAtTenToThe36() public {
        PegModuleRoute route = new PegModuleRoute(_config(address(dai), address(usdc)), _psmStep(address(psm)));
        uint256 d = 1e40;
        uint256 tout = 1e36 - 1;
        psm.setTout(tout);
        uint256 g = d * 1e18 / ((1e18 + tout) * C);
        if (_cost(g + 1, tout) <= d) g += 1;
        assertGt(g, 0);
        dai.mint(address(swapper), 2 * d);
        assertEq(swapper.swapUnderLock(route, d, g), g, "just below the halt value");
        psm.setTout(1e36);
        uint256 lastDai = psm.lastDaiIn();
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
        swapper.swapUnderLock(route, d, 1);
        assertEq(psm.lastDaiIn(), lastDai, "no purchase at the halt value");
    }

    // TEST-054 verifies: REQ-ROUTE-012, REQ-ROUTE-015, REQ-ROUTE-010
    // Sources: 2.12 REQ-ROUTE-012 (a USDS route first calls usdsToDai)
    /// @notice A USDS route converts the measured USDS into DAI, buys the largest affordable gem amount with it and
    /// returns the DAI residue; neither the converter nor the LitePSM keeps an allowance.
    function test_TEST_054_usdsRouteBuysWithConvertedDai() public {
        psm.setTout(1e15);
        PegModuleRoute route =
            new PegModuleRoute(_config(address(usds), address(usdc)), _usdsStep(address(psm), address(converter)));
        uint256 d = 12_345_678_901_234_567_890_123;
        uint256 g = d * 1e18 / ((1e18 + 1e15) * C);
        if (_cost(g + 1, 1e15) <= d) g += 1;
        usds.mint(address(swapper), d);
        assertEq(swapper.swapUnderLock(route, d, g), g);
        assertEq(dai.balanceOf(address(swapper)), d - _cost(g, 1e15), "DAI residue to LPVaultSwap");
        assertEq(usds.allowance(address(route), address(converter)), 0);
        assertEq(dai.allowance(address(route), address(psm)), 0);
        assertEq(usds.balanceOf(address(route)) + dai.balanceOf(address(route)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-011, REQ-ROUTE-015, REQ-ROUTE-010, REQ-ROUTE-016, INV-021
    // Sources: 2.12 REQ-ROUTE-011 (sell the largest amount the lot size allows; unsold shares return as a residue)
    /// @notice For any input and lot size, the GSM leg deposits the input, sells `shares - shares % lot` and returns the
    /// rest of the shares to LPVaultSwap; GHO arrives at LPVaultSwap at the GSM's rate; a lot larger than the shares
    /// leaves the GSM nothing to sell, its refusal reverts the whole swap and LPVaultSwap uses the other slot; the
    /// route ends with no shares and no allowance.
    function testFuzz_TEST_054_gsmLotSizeResidue(
        uint256 amountIn,
        uint256 lot
    ) public {
        amountIn = bound(amountIn, 1, 1e15);
        lot = bound(lot, 1, 1e9);
        MockVault4626 stata = new MockVault4626(IERC20(address(usdc)), "stataUSDC");
        MockGsm gsm = new MockGsm(address(stata), address(gho));
        gsm.setRate(1e12, 1);
        gsm.setLot(lot);
        PegModuleRoute route = new PegModuleRoute(
            _config(address(usdc), address(gho)),
            PegModuleStep({
                kind: PegModuleKind.Gsm, module: address(gsm), wrapper: address(stata), intermediate: address(stata)
            })
        );
        usdc.mint(address(swapper), amountIn);
        uint256 sold = amountIn - amountIn % lot;
        if (sold == 0) {
            vm.expectRevert(bytes("INVALID_AMOUNT"));
            swapper.swapUnderLock(route, amountIn, 1);
            return;
        }
        uint256 out = swapper.swapUnderLock(route, amountIn, sold * 1e12);
        assertEq(out, sold * 1e12, "GHO for the sold shares");
        assertEq(IERC20(address(stata)).balanceOf(address(swapper)), amountIn - sold, "unsold shares returned");
        assertEq(IERC20(address(stata)).balanceOf(address(route)), 0);
        assertEq(usdc.allowance(address(route), address(stata)), 0);
        assertEq(IERC20(address(stata)).allowance(address(route), address(gsm)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-011, REQ-ROUTE-026
    // Sources: 2.12 REQ-ROUTE-011 (the GSM's exposure cap bounds what it buys)
    /// @notice A sale that fills the GSM's exposure cap exactly succeeds; one unit more reverts the whole swap with the
    /// GSM's error, and LPVaultSwap keeps its input.
    function test_TEST_054_gsmExposureCapBoundary() public {
        MockVault4626 stata = new MockVault4626(IERC20(address(usdc)), "stataUSDC");
        MockGsm gsm = new MockGsm(address(stata), address(gho));
        gsm.setRate(1e12, 1);
        gsm.setCap(1_000_000);
        PegModuleRoute route = new PegModuleRoute(
            _config(address(usdc), address(gho)),
            PegModuleStep({
                kind: PegModuleKind.Gsm, module: address(gsm), wrapper: address(stata), intermediate: address(stata)
            })
        );
        usdc.mint(address(swapper), 1_000_001);
        assertEq(swapper.swapUnderLock(route, 1_000_000, 1e18), 1e18, "exactly at the cap");
        vm.expectRevert(bytes("EXOGENOUS_ASSET_EXPOSURE_TOO_HIGH"));
        swapper.swapUnderLock(route, 1, 1);
        assertEq(usdc.balanceOf(address(swapper)), 1, "the input stays with LPVaultSwap");
    }

    function _cost(
        uint256 g,
        uint256 tout
    ) internal pure returns (uint256) {
        uint256 g18 = g * C;
        return g18 + g18 * tout / 1e18;
    }

    function _expectBad(
        address tokenIn,
        address tokenOut,
        PegModuleStep memory step
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new PegModuleRoute(_config(tokenIn, tokenOut), step);
    }
}
