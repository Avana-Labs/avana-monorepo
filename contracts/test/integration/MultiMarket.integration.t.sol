// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountView} from "../../src/lens/lens/types/AccountView.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title MultiMarketIntegrationTest
/// @notice The deployed stack with several markets at once on two AMM integrations, each with its own CDP Spoke and
/// LPVault: Uniswap v3 WETH/USDC, WBTC/WETH and a thin MEME/WETH pool, Slipstream USDC/USDT and WETH/USDC (pool tokens
/// of 6, 8 and 18 decimals, vault tokens of 6 and 18). Borrowers open accounts through the real AaveAdapter against
/// USDC or GHO; token prices crash; the Lens sizes each liquidation and the real LPVaultSwap settles it, swapping every
/// released token into the repaid debt asset.
/// forge-config: default.isolate = false
contract MultiMarketIntegrationTest is IntegrationFlows {
    struct Case {
        uint256 marketId;
        address wallet;
        uint128 units;
        uint256 reserveId;
        uint256 borrowed;
    }

    Case[] internal cases;

    function setUp() public {
        _deployIntegration();
        _addLaunchMarkets();
        uint32 slip = SLIPSTREAM;
        cases.push(Case(ETH_USDC, makeAddr("ethUsdc"), 10e18, usdcReserveId, 38_000e6));
        cases.push(Case(WBTC_ETH, makeAddr("wbtcEth"), 10e18, usdcReserveId, 38_000e6));
        cases.push(Case(MEME_ETH, makeAddr("memeEth"), 100e18, usdcReserveId, 21_500e6));
        cases.push(Case(SLIP_ETH_USDC, makeAddr("slipEthGho"), 10e18, cdp[slip].ghoReserveId, 38_000e18));
        cases.push(Case(SLIP_USDC_USDT, makeAddr("slipStable"), 10_000e6, cdp[slip].usdcReserveId, 18_000e6));
    }

    function _open(
        Case memory c
    ) internal returns (address proxy) {
        if (c.marketId == SLIP_USDC_USDT) _setPrice(c.marketId, 250_000_000);
        (, proxy) = _pledgeVia(c.wallet, c.marketId, c.units);
        _borrowVia(c.wallet, c.marketId, c.reserveId, c.borrowed);
    }

    // TEST-047 verifies: REQ-SWAP-011, REQ-SWAP-020, REQ-SWAP-022, REQ-ADAPTER-070, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-010, Q-233
    // TEST-205 verifies: REQ-LENS-016, REQ-LENS-017, REQ-LENS-028, REQ-LENS-029
    function test_TEST_047_everyMarketAndSpokeLiquidates() public {
        address[] memory proxies = new address[](cases.length);
        for (uint256 i = 0; i < cases.length; ++i) {
            proxies[i] = _open(cases[i]);
            assertEq(_spokeOf(proxies[i]), markets[cases[i].marketId].spoke, "the market's own CDP Spoke");
            assertGt(_hf(proxies[i]), 1e18, "healthy after the borrow");
        }
        // Crash: WETH -20 %, WBTC -20 %, MEME -40 %; the stable Slipstream market's vault price $2.50 -> $2.10.
        _moveTokenPrice(address(weth), 2400e8);
        _moveTokenPrice(address(wbtc), 48_000e8);
        _moveTokenPrice(address(meme), 18_000_000);
        _setPrice(SLIP_USDC_USDT, P_VAULT);
        for (uint256 i = 0; i < cases.length; ++i) {
            _liquidateCase(cases[i], proxies[i]);
        }
    }

    function _liquidateCase(
        Case memory c,
        address proxy
    ) internal {
        assertLt(_hf(proxy), 1e18, "underwater after the crash");
        LiquidationPreview memory p = lens.previewLiquidation(proxy, c.reserveId, block.timestamp + 60);
        assertTrue(p.aaveLiquidatable && p.pricesUsable, "liquidatable with usable prices");
        p.params.maxShortfall = p.params.debtToCover / 20;
        uint256 debtBefore = _debtOf(proxy, c.reserveId);
        LiquidationResult memory r = _liquidateAs(keeper, p.params);
        assertEq(r.debtRepaid, p.expectedDebtRepaid, "D as previewed");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        assertEq(debtBefore - _debtOf(proxy, c.reserveId), r.debtRepaid, "debt fell by D");
        assertEq(
            r.callerFunds + r.recovered + r.shortfall,
            r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut,
            "conservation"
        );
        assertGe(r.recovered + r.shortfall, r.minOut, "floor");
        _assertNeutral();
        AccountView memory a = lens.getAccount(c.wallet, c.marketId);
        assertEq(a.healthFactor, _hf(proxy), "Lens HF = the market's Spoke");
        assertEq(a.spoke, markets[c.marketId].spoke, "Lens: the account's Spoke");
    }

    /// @notice A debt-free exit returns the position in every market, on either integration.
    // TEST-193 verifies: REQ-ADAPTER-086, REQ-PROXY-035, INV-045
    function test_TEST_193_debtFreeExitOnEveryIntegration() public {
        for (uint256 i = 0; i < cases.length; ++i) {
            Case memory c = cases[i];
            (bytes32 key, address proxy) = _pledgeVia(c.wallet, c.marketId, c.units);
            _withdrawVia(c.wallet, c.marketId, key, c.units);
            assertEq(markets[c.marketId].vault.ownerOf(key), c.wallet, "position returned");
            assertEq(_suppliedOf(proxy, c.marketId), 0, "nothing supplied");
        }
    }

    function _assertNeutral() internal view {
        CollPoolToken[6] memory ts = [usdc, usdt, debt, weth, wbtc, meme];
        for (uint256 k = 0; k < ts.length; ++k) {
            assertEq(ts[k].balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no token");
        }
        assertFalse(lock.isLocked(), "Lock free");
    }
}
