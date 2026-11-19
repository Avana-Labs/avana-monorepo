// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {PositionRef} from "../../src/types/PositionTypes.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackSlipstream} from "../utils/fixtures/RealStackSlipstream.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title MultiMarketSlipstreamIntegrationTest
/// @notice The Slipstream cases of the multi-market suite, on the real stack (`RealStackSlipstream`): a Slipstream
/// USDC/USDT market (generation 2, spacing 1) on the Stable LP Hub and a WETH/USDC market (generation 3, spacing 100) on
/// the Volatile LP Hub, each on the second AMM integration's own CDP Spoke and the real `SlipstreamIntegration`,
/// alongside the Uniswap v3 USDC/USDT market. Borrowers open accounts through the real AaveAdapter against USDC or GHO;
/// token prices crash; the Lens sizes each liquidation and the real LPVaultSwap settles it, unwinding through the real
/// Slipstream position manager and swapping every released token into the repaid debt asset through real routes.
/// @dev Accounts open at HF about 1.05 (CF 30 %): $60,000 of WETH/USDC against 17,142 GHO, and $20,000 of USDC/USDT
/// against 5,714 USDC. The crash: WETH -20 % (a full-range WETH/USDC unit -10.6 %) and USDT at $0.85 (a USDC/USDT unit
/// -7.8 %, inside the USD band), the pools moved and the TWAP window waited.
/// forge-config: default.isolate = false
contract MultiMarketSlipstreamIntegrationTest is RealStackSlipstream {
    struct Case {
        uint256 marketId;
        address wallet;
        uint256 usd;
        uint256 reserveId;
        uint256 borrowed;
    }

    Case[] internal cases;
    uint256 internal mA;
    uint256 internal slipEthUsdc;
    uint256 internal slipUsdcUsdt;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        _setUpSlipstream();
        IClPool[] memory pools = new IClPool[](2);
        pools[0] = _newSlipPool(2, usdc, usdt, 1, 1e15);
        pools[1] = _newSlipPool(3, weth, usdc, 100, 1e18);
        _ageNewPools(pools);
        slipUsdcUsdt = _addSlipMarket(pools[0], VT_CF);
        slipEthUsdc = _addSlipMarket(pools[1], VT_CF);
        // The route DEX's WETH -> GHO pools hold about 0.018 WETH at `ROUTE_LIQUIDITY` (an 18/18-decimal pair): deepen
        // each to about $540,000 a side, as the 6-decimal pairs are.
        for (uint256 k = 0; k < 2; ++k) {
            IClPool r = routePoolOf[address(weth)][address(gho)][k];
            (int24 lower, int24 upper) = _fullRange(r);
            actor.mint(r, lower, upper, 1e22);
        }
        cases.push(Case(slipEthUsdc, makeAddr("slipEthGho"), 60_000, slipGhoReserveV, 17_142e18));
        cases.push(Case(slipUsdcUsdt, makeAddr("slipStable"), 20_000, slipUsdcReserveS, 5714e6));
    }

    function _spokeOf(
        uint256 marketId
    ) internal view returns (address) {
        return registry.getMarket(marketId).spoke;
    }

    function _open(
        Case memory c
    ) internal returns (address proxy) {
        (, proxy) = _slipPledgeUsd(c.wallet, c.marketId, c.usd);
        _borrowAs(c.wallet, c.marketId, c.reserveId, c.borrowed);
    }

    /// @notice A debt-free exit returns the position in every Slipstream market.
    // TEST-193 verifies: REQ-ADAPTER-086, REQ-PROXY-035, INV-045
    function test_TEST_193_debtFreeExitOnSlipstream() public {
        for (uint256 i = 0; i < cases.length; ++i) {
            Case memory c = cases[i];
            (bytes32 key, address proxy) = _slipPledgeUsd(c.wallet, c.marketId, c.usd);
            uint256 units = coll.getRecord(coll.recordIdOf(SLIP, key)).credited;
            vm.prank(c.wallet);
            adapterC.withdraw(c.marketId, PositionRef(SLIP, key), units, _deadline(), 0);
            address npm = slipNpms[uint256(key) >> 248];
            assertEq(IERC721(npm).ownerOf(uint256(key) & ((1 << 248) - 1)), c.wallet, "position returned");
            assertEq(_sharesOn(_spokeOf(c.marketId), proxy, mkt[c.marketId].reserveId), 0, "nothing supplied");
        }
    }

    function _assertNeutral() internal view {
        ClTestToken[6] memory ts = [usdc, usdt, gho, weth, wbtc, meme];
        for (uint256 k = 0; k < ts.length; ++k) {
            assertEq(ts[k].balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no token");
        }
        assertFalse(lock.isLocked(), "Lock free");
    }
}
