// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackVolatile} from "../utils/fixtures/RealStackVolatile.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title MultiMarketIntegrationTest
/// @notice The real stack (`RealStackVolatile`) with several markets at once on two Hubs and CDP Spokes of the real
/// Uniswap v3 LPVault: the Stable LP Hub's USDC/USDT market and, on the Volatile LP Hub's own CDP Spoke, the full ranges
/// of real Uniswap v3 WETH/USDC (0.05 %), WBTC/WETH (0.3 %) and a thin MEME/WETH (1 %) pool, each created at the feed
/// prices (pool tokens of 6, 8 and 18 decimals; vault-token decimals and unit exponents as the real LPVault binds them).
/// Borrowers open accounts through the real AaveAdapter against USDC on either Spoke; token prices crash; the Lens sizes
/// each liquidation and the real LPVaultSwap settles it, swapping every released token into USDC over real routes.
/// @dev Volatile accounts: $60,000 of WETH/USDC or WBTC/WETH liquidity, $6,000 of MEME/WETH (about 1 % of its pool),
/// each borrowing USDC at HF about 1.08 (the Lens's `previewBorrowMax` / 1.08; CF 30 %, 20 % for MEME/WETH); the stable
/// account 10,000 vault tokens against 5,880 USDC. Crash: WETH -20 %, WBTC -20 %, MEME -40 % and USDT -7 % on every
/// feed, every market pool swapped to the new prices and the TWAP window waited (`_repriceMarkets`); the volatile vault
/// tokens lose 10.6 %, 20 % and 30.7 %, the stable one 3.6 %. The Slipstream cases are in `MultiMarket.Slipstream`
/// (`RealStackSlipstream`).
/// forge-config: default.isolate = false
contract MultiMarketIntegrationTest is RealStackVolatile {
    struct Case {
        uint256 marketId;
        address wallet;
        uint256 usd;
        address spoke;
        uint256 reserveId;
    }

    Case[] internal cases;
    uint256 internal mStable;

    function setUp() public {
        _setUpFullStack();
        mStable = _addMarket(poolA);
        _setUpVolatile();
        IClPool[] memory pools = new IClPool[](3);
        pools[0] = _newVolatilePool(weth, usdc, 500, 1e18);
        pools[1] = _newVolatilePool(wbtc, weth, 3000, 1e16);
        pools[2] = _newVolatilePool(meme, weth, 10_000, 1e22);
        _ageNewPools(pools);
        uint256 ethUsdc = _addVolatileMarket(pools[0], 3000);
        uint256 wbtcEth = _addVolatileMarket(pools[1], 3000);
        uint256 memeEth = _addVolatileMarket(pools[2], 2000);
        cases.push(Case(ethUsdc, makeAddr("ethUsdc"), 60_000, spokeV, usdcReserveIdV));
        cases.push(Case(wbtcEth, makeAddr("wbtcEth"), 60_000, spokeV, usdcReserveIdV));
        cases.push(Case(memeEth, makeAddr("memeEth"), 6000, spokeV, usdcReserveIdV));
        cases.push(Case(mStable, makeAddr("stable"), 0, aave.cdpSpoke, usdcReserveId));
    }

    /// @notice A debt-free exit returns the NFT in every market, on either Spoke.
    // TEST-193 verifies: REQ-ADAPTER-086, REQ-PROXY-035, INV-045
    function test_TEST_193_debtFreeExitOnEveryIntegration() public {
        for (uint256 i = 0; i < cases.length; ++i) {
            Case memory c = cases[i];
            bytes32 key;
            address proxy;
            if (c.marketId == mStable) (key, proxy) = _pledgeAs(c.wallet, c.marketId, UNITS);
            else (key, proxy) = _pledgeUsd(c.wallet, c.marketId, c.usd);
            uint256 credited = coll.getRecord(coll.recordIdOf(V3, key)).credited;
            assertGt(credited, 0, "credited");
            _withdrawVia(c.wallet, c.marketId, key, credited);
            assertEq(IERC721(address(nfpm)).ownerOf(uint256(key)), c.wallet, "NFT returned");
            assertEq(_sharesOn(c.spoke, proxy, mkt[c.marketId].reserveId), 0, "nothing supplied");
            assertEq(IERC20(mkt[c.marketId].vaultToken).totalSupply(), 0, "no vault token left");
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
