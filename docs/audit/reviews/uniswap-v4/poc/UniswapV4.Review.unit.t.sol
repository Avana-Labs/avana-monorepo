// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskStatus} from "../../src/integrations/types/RiskStatus.sol";
import {UniswapV4State} from "../../src/integrations/uniswap-v4/UniswapV4State.sol";
import {
    IUniswapV4PoolManager,
    UniswapV4PoolKey
} from "../../src/dependencies/uniswap-v4/IUniswapV4PoolManager.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleV4} from "../../src/oracle/lp-oracle/LPOracleV4.sol";
import {ClPriceStateView} from "../../src/oracle/lp-oracle/types/ClPriceStateView.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LPOracleV4Fixture} from "../utils/fixtures/LPOracleV4Fixture.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Review PoCs on the Uniswap v4 LPVault (production contract, real PoolManager and PositionManager of the
/// pinned v4 sources, real Lock). Run once on 2026-11-15 after the fixes (see the README).
/// forge-config: default.isolate = false
contract UniswapV4ReviewPoC is UniswapV4IntegrationFixture {
    address internal recipient = makeAddr("recipient");

    /// @dev v4-periphery `Actions.INCREASE_LIQUIDITY`.
    uint8 internal constant A_INCREASE_LIQUIDITY = 0x00;

    // V4-01: every v4 removal pays the accrued fees to the depositor inside the same PositionManager batch. A
    // depositor wallet that a pool token refuses (an issuer blocklist) makes the seizure unwind revert.
    function test_POC_V401_blocklistedDepositorBlocksSeizureUnwind() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        _washV4(stableKey, 1e12);
        (uint256 f0, uint256 f1) = _accruedFees(stableKey, key, M1_LOWER, M1_UPPER);
        uint256 usdcFee = address(usdc) < address(usdt) ? f0 : f1;
        assertGt(usdcFee, 0, "USDC fees accrued to the position");

        // USDC refuses every transfer to the depositor's wallet.
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector, alice), bytes("blocklisted"));

        // Seizure path (CollateralizationSeizure._settleDebits): unwind the seized units to LPVaultSwap, zero minimums.
        _lock();
        vm.prank(coll);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.unwind, (key, units, _zeros(), lpVaultSwap)));
        _unlock();
        assertFalse(ok, "the unwind to LPVaultSwap reverts on the fee transfer to the depositor");

        // Same call without the blocklist succeeds: the depositor's fee transfer is the only cause.
        vm.clearMockedCalls();
        uint256[] memory amounts = _unwind(key, units, _zeros(), lpVaultSwap);
        assertGt(amounts[0] + amounts[1], 0, "principal reaches LPVaultSwap once the depositor can receive");
    }

    // V4-02: the v4 PositionManager lets only the owner or an approved address add liquidity, and the LPVault (the
    // owner) never does, so a custodied v4 position can never grow and a re-credit has nothing to credit.
    function test_POC_V402_custodiedPositionCannotBeToppedUp() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);

        // Control: the same increase on a position this test contract owns succeeds (encoding and funding are right).
        uint256 own = _mintV4(address(this), stableKey, M1_LOWER, M1_UPPER, 1e15);
        posm.modifyLiquidities(_increaseData(stableKey, own, 1e15), block.timestamp);

        // The depositor cannot add to the custodied NFT (PositionManager._increase: onlyIfApproved -> NotApproved).
        vm.expectRevert();
        vm.prank(alice);
        posm.modifyLiquidities(_increaseData(stableKey, uint256(key), 1e15), block.timestamp);
        // Nor can anyone else.
        vm.expectRevert();
        posm.modifyLiquidities(_increaseData(stableKey, uint256(key), 1e15), block.timestamp);

        // The LPVault offers no top-up of its own.
        _lock();
        vm.expectRevert(TopUpNotSupported.selector);
        vm.prank(coll);
        vault.topUpPosition(key, alice, hex"01");
        _unlock();

        assertEq(vault.unitsOf(key), units, "live units never exceed the credited units: nothing to re-credit");
    }

    // V4-04: two fee tiers of one pair, bound to the same reference pool, report the same depth while Collateralization
    // counts their credited units under two different pool keys (one per PoolId).
    function test_POC_V404_twoFeeTiersShareOneReferenceDepth() public {
        PoolKey memory tier30 = _key(address(0), address(usdc), 3000, 60);
        _initPool(tier30, ETH_PRICE, ONE, 18, 6);
        _bindV4(3, tier30, address(ethRef), -207_000, -193_980, ETH_PRICE, ONE);
        _observe(ethRef, 10);

        RiskStatus memory a = vault.riskStatus(M2, 60);
        RiskStatus memory b = vault.riskStatus(3, 60);
        assertTrue(a.depthAvailable && b.depthAvailable, "both depths available");
        uint8 ka = vault.unitExponent(M2);
        uint8 kb = vault.unitExponent(3);
        uint256 la = a.depthUnits * 10 ** ka;
        uint256 lb = b.depthUnits * 10 ** kb;
        assertApproxEqAbs(la, lb, 10 ** (ka > kb ? ka : kb), "one reference pool's liquidity backs both caps");

        (, bytes32 idA,,) = vault.marketOf(M2);
        (, bytes32 idB,,) = vault.marketOf(3);
        assertTrue(idA != idB, "two PoolIds, so two pool-share counters against one depth");
        assertEq(vault.v4Market(M2).referencePool, vault.v4Market(3).referencePool);
    }

    // V4-05: on a native-ETH market the batch wraps the PositionManager's whole ETH balance and sweeps its whole WETH
    // balance; whatever sat there reaches the depositor beyond the amounts the LPVault reports.
    function test_POC_V405_wrapAndSweepDeliverStrayBalances() public {
        bytes32 key = _mintFor(alice, ethKey, M2_LOWER, M2_UPPER, 1e18);
        uint128 units = _receive(M2, alice, key);
        // Someone left 1 WETH and 0.5 ETH in the PositionManager.
        weth.mint(address(posm), 1e18);
        vm.deal(address(posm), 5e17);

        (uint256 a0,) = _balances(M2, alice);
        (uint256 r0,) = _balances(M2, recipient);
        uint256[] memory amounts = _unwind(key, units, _zeros(), recipient);
        (uint256 b0,) = _balances(M2, alice);
        (uint256 s0,) = _balances(M2, recipient);

        assertEq(s0 - r0, amounts[0], "recipient gets exactly the reported principal");
        assertEq(b0 - a0, 15e17, "no fee accrued, yet the depositor's fee step delivered 1.5 WETH of strays");
        assertEq(weth.balanceOf(address(posm)), 0);
        assertEq(address(posm).balance, 0);
    }

    // V4-06: a partial release measures the depositor's balance deltas (REQ-VAULT-088); on v4 the fee step pays the
    // same depositor in the same call, so the measured amounts are principal plus fees.
    function test_POC_V406_releaseToDepositorDeltaIncludesTheFees() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        _washV4(stableKey, 1e12);
        (uint256 f0, uint256 f1) = _accruedFees(stableKey, key, M1_LOWER, M1_UPPER);
        assertGt(f0 + f1, 0);

        (uint256 a0, uint256 a1) = _balances(M1, alice);
        uint256[] memory principal = abi.decode(
            _asColl(abi.encodeCall(vault.releaseToDepositor, (key, units / 2, _zeros()))), (uint256[])
        );
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertEq(b0 - a0, principal[0] + f0, "measured delta0 = principal0 + fee0");
        assertEq(b1 - a1, principal[1] + f1, "measured delta1 = principal1 + fee1");
    }

    // ─── Helpers ───

    /// @dev The fees the PoolManager would credit a PositionManager position now (`Position.update`).
    function _accruedFees(
        PoolKey memory k,
        bytes32 positionKey,
        int24 lower,
        int24 upper
    ) internal view returns (uint256 f0, uint256 f1) {
        IUniswapV4PoolManager m = IUniswapV4PoolManager(address(pm));
        bytes32 id = _poolId(k);
        UniswapV4State.PositionState memory p =
            UniswapV4State.position(m, id, UniswapV4State.positionId(address(posm), lower, upper, positionKey));
        (uint256 in0, uint256 in1) = UniswapV4State.feeGrowthInside(m, id, lower, upper);
        (f0, f1) = UniswapV4State.feesOwed(p, in0, in1);
    }

    /// @dev `INCREASE_LIQUIDITY(tokenId, liquidity, max, max, "")` then `SETTLE_PAIR`, paid by the caller via Permit2.
    function _increaseData(
        PoolKey memory k,
        uint256 tokenId,
        uint128 liquidity
    ) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(A_INCREASE_LIQUIDITY, A_SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(k.currency0, k.currency1);
        return abi.encode(actions, params);
    }
}

/// @notice Review PoC on the Uniswap v4 LPOracle (real `LPOracleV4`, integration stub of the fixture). Run once after the fixes.
/// forge-config: default.isolate = false
contract LPOracleV4ReviewPoC is LPOracleV4Fixture {
    function setUp() public {
        _deployV4Market();
    }

    // V4-03: the oracle's market encoding names its own PoolManager, PoolKey and range, and no listing check compares
    // them with the integration's market. An oracle on the fee-3000 pool and another range passes `checkConfig`, and
    // its spot gate ignores the market's own fee-500 pool.
    function test_POC_V403_listingAcceptsAnOracleOfAnotherV4PoolAndRange() public {
        // The integration's market (stub): native ETH/USDC, fee 500, spacing 10, the fixture's reference pool.
        integration.setBound(true);

        // Another initialized pool of the same pair.
        PoolKey memory other = _key(address(0), address(usdc), 3000, 60);
        _initPool(other, ETH, USD, 18, 6);
        UniswapV4PoolKey memory k = UniswapV4PoolKey(address(0), address(usdc), 3000, 60, address(0));
        InitParams memory p = _params();
        p.market = abi.encode(address(pm), k, int24(-206_940), int24(-194_040), uint256(0), address(ref));
        LPOracleV4 wrong = LPOracleV4(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (p))))
        );

        assertEq(oracle.checkConfig(_config()), 0, "honest feed: clean");
        assertEq(wrong.checkConfig(_config()), 0, "feed of another pool and another range: also clean");
        ClPriceStateView memory r = wrong.getClPriceState();
        assertEq(r.tickLower, -206_940, "prices a range the integration's market does not have");

        // Park the market's own pool 3% off the oracle price.
        (uint160 s,) = _slot0V4(key);
        _swapV4To(key, uint160((uint256(s) * 97) / 100));
        assertEq(uint8(oracle.getPriceState().state), uint8(PriceState.Drifting), "honest feed fails closed");
        assertEq(uint8(wrong.getPriceState().state), uint8(PriceState.Live), "the mis-encoded feed stays Live");
    }
}
