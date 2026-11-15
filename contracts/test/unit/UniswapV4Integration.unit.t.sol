// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClMarketConfig} from "../../src/amm/types/ClMarketConfig.sol";
import {IntegrationCapabilities} from "../../src/amm/types/IntegrationCapabilities.sol";
import {PoolKeying} from "../../src/amm/types/PoolKeying.sol";
import {RiskMetadata} from "../../src/amm/types/RiskMetadata.sol";
import {RiskStatus} from "../../src/amm/types/RiskStatus.sol";
import {IUniswapV4Integration} from "../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {UniswapV4State} from "../../src/amm/uniswap-v4/UniswapV4State.sol";
import {IUniswapV4PoolManager} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";
import {V4TestSubscriber} from "../utils/fixtures/UniswapV4WorldFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Unit suite of the Uniswap v4 LPVault on the local v4 world: binding guards, custody, the fees-first removal
/// batch on an ERC-20 pool and a native-ETH pool, the read guard, consistency, depth and wrapped fee growth.
/// forge-config: default.isolate = false
contract UniswapV4IntegrationUnitTest is UniswapV4IntegrationFixture {
    address internal recipient = makeAddr("recipient");

    // ─── Binding ───

    // TEST-331 verifies: REQ-AMM-V4-001, REQ-AMM-V4-007, REQ-AMM-CORE-003, REQ-AMM-CORE-004
    function test_TEST_331_bindStoresThePoolKeyTokensAndReference() public view {
        (address pool, bytes32 poolId, PositionShape memory shape, address[] memory tokens) = vault.marketOf(M2);
        assertEq(pool, address(0), "id-keyed");
        assertEq(poolId, _poolId(ethKey), "pool id");
        assertEq(shape.tickLower, M2_LOWER);
        assertEq(shape.tickUpper, M2_UPPER);
        assertEq(tokens[0], address(weth), "native ETH as WETH");
        assertEq(tokens[1], address(usdc));
        IUniswapV4Integration.V4Market memory v = vault.v4Market(M2);
        assertEq(v.referencePool, address(ethRef));
        assertEq(v.key.currency0, address(0));
        assertEq(v.key.tickSpacing, 10);
        ClMarketConfig memory cfg = vault.clMarket(M2);
        assertEq(cfg.positionManager, address(posm));
        assertEq(cfg.factory, address(pm));
        assertEq(cfg.fee, 500);
        assertEq(vault.wrappedNative(), address(weth));
        assertEq(vault.AMM_PROTOCOL(), keccak256("UNISWAP_V4"));
        assertEq(vault.POOL_MANAGER(), address(pm));
        assertEq(vault.HOOK_MASK(), 0x30d);
        IntegrationCapabilities memory caps = vault.capabilities();
        assertEq(uint8(caps.poolKeying), uint8(PoolKeying.Id));
        assertTrue(caps.hasTwap && caps.nativeToken && caps.reentrancyGuarded);
    }

    // TEST-331 verifies: REQ-AMM-V4-001, REQ-AMM-V4-006
    function test_TEST_331_bindRefusesHookedPools() public {
        PoolKey memory hooked = stableKey;
        // Any hook is refused while the allowlist is empty, even one that clears the mask (bit 7 only).
        hooked.hooks = IHooks(address(uint160(0x0080)));
        _expectBind(
            hooked,
            address(stableRef),
            abi.encodeWithSelector(IUniswapV4Integration.HookNotAllowed.selector, address(0x80))
        );
        hooked.hooks = IHooks(address(uint160(0x0300)));
        _expectBind(
            hooked,
            address(stableRef),
            abi.encodeWithSelector(IUniswapV4Integration.HookNotAllowed.selector, address(0x300))
        );
        hooked.hooks = IHooks(address(uint160(0x0008)));
        _expectBind(
            hooked,
            address(stableRef),
            abi.encodeWithSelector(IUniswapV4Integration.HookNotAllowed.selector, address(0x8))
        );
        assertTrue(vault.isAllowedPoolHook(address(0)));
        assertFalse(vault.isAllowedPoolHook(address(0x80)));
    }

    // TEST-331 verifies: REQ-AMM-V4-007, REQ-AMM-V4-009, REQ-AMM-V4-011
    function test_TEST_331_bindRefusesBadPoolsReferencesAndSupplies() public {
        // Uninitialized pool.
        PoolKey memory fresh =
            _key(Currency.unwrap(stableKey.currency0), Currency.unwrap(stableKey.currency1), 3000, 60);
        _expectBind(fresh, address(stableRef), abi.encodeWithSelector(InvalidPool.selector));
        // Reference pool of another pair.
        PoolKey memory k = stableKey;
        _expectBindRange(k, address(ethRef), -10, 10, abi.encodeWithSelector(InvalidPool.selector));
        // Reference pool not created by the factory.
        _expectBindRange(k, address(this), -10, 10, abi.encodeWithSelector(InvalidPool.selector));
        // A second market of the same pool naming another reference pool.
        IClPool other = IClPool(factory.createPool(Currency.unwrap(k.currency0), Currency.unwrap(k.currency1), 3000));
        _expectBindRange(k, address(other), -10, 10, abi.encodeWithSelector(InvalidPool.selector));
        // A token with a supply of 2^127.
        ClTestToken big = new ClTestToken("BIG", 18);
        big.mint(address(1), 1 << 127);
        (address a, address b) =
            address(big) < address(usdc) ? (address(big), address(usdc)) : (address(usdc), address(big));
        PoolKey memory bigKey = _key(a, b, 500, 10);
        pm.initialize(bigKey, 1 << 96);
        IClPool bigRef = IClPool(factory.createPool(a, b, 500));
        _expectBindRange(bigKey, address(bigRef), -100, 100, abi.encodeWithSelector(InvalidPool.selector));
        // pool != 0 or a wrong id.
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(
            9,
            address(1),
            _poolId(k),
            PositionShape(ShapeKind.TickRange, -10, 10),
            _bindData(k, address(stableRef), ONE, ONE)
        );
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(
            9,
            address(0),
            bytes32(uint256(1)),
            PositionShape(ShapeKind.TickRange, -10, 10),
            _bindData(k, address(stableRef), ONE, ONE)
        );
    }

    // ─── Custody ───

    // TEST-333 verifies: REQ-AMM-V4-003, REQ-AMM-CORE-005, SPEC-UNIT-002
    function test_TEST_333_receiveReadsLiquidityFromThePoolManager() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        assertEq(units, uint128(1e15 / 10 ** vault.unitExponent(M1)), "units");
        assertEq(posm.ownerOf(uint256(key)), address(vault), "custody");
        _lock();
        vm.prank(coll);
        assertEq(vault.depositorOf(key), alice);
        _unlock();
        assertEq(vault.unitsOf(key), units);
    }

    // TEST-333 verifies: REQ-AMM-V4-003, REQ-VAULT-008, REQ-VAULT-009
    function test_TEST_333_receiveRequiresThePoolAndTheExactRange() public {
        bytes32 wrongRange = _mintFor(alice, stableKey, -40, 40, 1e15);
        vm.expectRevert(abi.encodeWithSelector(RangeMismatch.selector, int24(-40), int24(40)));
        vault.validatePosition(M1, alice, wrongRange);
        bytes32 otherPool = _mintFor(alice, ethKey, M2_LOWER, M2_UPPER, 1e15);
        vm.expectRevert(PoolMismatch.selector);
        vault.validatePosition(M1, alice, otherPool);
    }

    // TEST-333 verifies: REQ-AMM-V4-002, REQ-AMM-V4-006
    function test_TEST_333_receiveRefusesASubscribedPosition() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        V4TestSubscriber sub = new V4TestSubscriber();
        vm.prank(alice);
        posm.subscribe(uint256(key), address(sub), "");
        vm.expectRevert(IUniswapV4Integration.SubscribedPosition.selector);
        vault.validatePosition(M1, alice, key);
    }

    // TEST-333 verifies: REQ-AMM-V4-003, REQ-AMM-V4-011, REQ-AMM-CORE-018
    function test_TEST_333_readsFailClosedWhileThePoolManagerIsUnlocked() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        (bool ok, bytes memory ret) =
            v4Actor.callInside(address(vault), abi.encodeCall(vault.validatePosition, (M1, alice, key)));
        assertFalse(ok);
        assertEq(bytes4(ret), PoolLocked.selector);
        (ok, ret) = v4Actor.callInside(address(vault), abi.encodeCall(vault.checkReadSafe, (M1)));
        assertFalse(ok);
        assertEq(bytes4(ret), PoolLocked.selector);
        RiskMetadata memory meta = vault.riskMetadata(M1, bytes32(0));
        assertTrue(meta.readSafe, "safe outside unlock");
        // Review S7: the consistency read is unavailable inside an unlock and available outside it.
        _observe(ethRef, 10);
        (ok, ret) = v4Actor.callInside(
            address(vault), abi.encodeCall(vault.consistencyDeviation, (M2, 60, _vec(ETH_PRICE, ONE)))
        );
        assertTrue(ok);
        (, bool available) = abi.decode(ret, (uint256, bool));
        assertFalse(available, "unavailable while the PoolManager is unlocked");
        (, available) = vault.consistencyDeviation(M2, 60, _vec(ETH_PRICE, ONE));
        assertTrue(available, "available outside the unlock");
    }

    // ─── Removal ───

    // TEST-334 verifies: REQ-AMM-V4-004, SPEC-AMM-V4-003, SPEC-BACK-008
    function test_TEST_334_unwindPaysPrincipalToRecipientAndFeesToDepositor() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        _washV4(stableKey, 1e12);
        (uint256 a0, uint256 a1) = _balances(M1, alice);
        uint256[] memory amounts = _unwind(key, units / 2, _zeros(), recipient);
        (uint256 r0, uint256 r1) = _balances(M1, recipient);
        assertEq(r0, amounts[0], "principal0");
        assertEq(r1, amounts[1], "principal1");
        assertGt(r0 + r1, 0);
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertGt(b0 - a0 + b1 - a1, 0, "fees to depositor");
        assertEq(vault.unitsOf(key), units - units / 2, "units left");
    }

    // TEST-334 verifies: REQ-AMM-V4-013, REQ-AMM-V4-004, REQ-AMM-V4-010
    /// @notice Review V4-01: a token that refuses the depositor's address cannot block a removal to another recipient:
    /// the first batch reverts at the depositor's fee transfer, the second takes the principal and the fees to the
    /// recipient, and the returned amounts are the principal plus the fees.
    function test_TEST_334_refusedDepositorFeesGoToTheRecipient() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        _washV4(stableKey, 1e12);
        (uint256 f0, uint256 f1) = _feesNow(stableKey, key, M1_LOWER, M1_UPPER);
        assertGt(f0, 0, "token0 fees accrued");
        assertGt(f1, 0, "token1 fees accrued");
        uint256 snap = vm.snapshotState();
        uint256[] memory principal = _unwind(key, units, _zeros(), lpVaultSwap);
        vm.revertToState(snap);
        (uint256 a0, uint256 a1) = _balances(M1, alice);
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector, alice), bytes("blocklisted"));
        uint256[] memory amounts = _unwind(key, units, _zeros(), lpVaultSwap);
        vm.clearMockedCalls();
        assertEq(amounts[0], principal[0] + f0, "token0: principal plus fees");
        assertEq(amounts[1], principal[1] + f1, "token1: principal plus fees");
        (uint256 r0, uint256 r1) = _balances(M1, lpVaultSwap);
        assertEq(r0, amounts[0], "token0 delivered as returned");
        assertEq(r1, amounts[1], "token1 delivered as returned");
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertEq(b0, a0, "the depositor received no token0");
        assertEq(b1, a1, "the depositor received no token1");
        assertEq(vault.unitsOf(key), 0, "every unit removed");
    }

    // TEST-334 verifies: REQ-AMM-V4-013, REQ-AMM-V4-004
    /// @notice A removal to the depositor runs one batch: a token that refuses the depositor reverts it.
    function test_TEST_334_refusedDepositorBlocksOnlyTheirOwnRelease() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        _washV4(stableKey, 1e12);
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector, alice), bytes("blocklisted"));
        _lock();
        vm.prank(coll);
        vm.expectRevert();
        vault.releaseToDepositor(key, units / 2, _zeros());
        _unlock();
        vm.clearMockedCalls();
        assertEq(vault.unitsOf(key), units, "nothing removed");
    }

    // TEST-334 verifies: REQ-AMM-V4-004, REQ-AMM-V4-013
    /// @notice A depositor that can receive keeps the fee step: the recipient gets the principal and the depositor
    /// exactly the accrued fees.
    function test_TEST_334_acceptedDepositorFeesStayWithTheDepositor() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        _washV4(stableKey, 1e12);
        (uint256 f0, uint256 f1) = _feesNow(stableKey, key, M1_LOWER, M1_UPPER);
        (uint256 a0, uint256 a1) = _balances(M1, alice);
        uint256[] memory amounts = _unwind(key, units, _zeros(), lpVaultSwap);
        (uint256 r0, uint256 r1) = _balances(M1, lpVaultSwap);
        assertEq(r0, amounts[0], "token0 principal");
        assertEq(r1, amounts[1], "token1 principal");
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertEq(b0 - a0, f0, "token0 fees to the depositor");
        assertEq(b1 - a1, f1, "token1 fees to the depositor");
    }

    // TEST-334 verifies: REQ-AMM-V4-014, REQ-AMM-CORE-011
    /// @notice Review V4-02: only the NFT's owner, the LPVault, may add liquidity to a pledged v4 position, so neither
    /// the depositor nor anyone else can, and the LPVault offers no top-up.
    function test_TEST_334_pledgedPositionCannotTakeMoreLiquidity() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        bytes memory increase = _increaseData(stableKey, uint256(key), 1e15);
        vm.prank(alice);
        vm.expectRevert();
        posm.modifyLiquidities(increase, block.timestamp);
        vm.expectRevert();
        posm.modifyLiquidities(increase, block.timestamp);
        _lock();
        vm.prank(coll);
        vm.expectRevert(TopUpNotSupported.selector);
        vault.topUpPosition(key, alice, hex"01");
        _unlock();
        assertEq(vault.unitsOf(key), units, "nothing to re-credit");
    }

    // TEST-334 verifies: REQ-AMM-V4-004, REQ-AMM-CORE-010
    function test_TEST_334_nativeEthIsWrappedForRecipientAndDepositor() public {
        bytes32 key = _mintFor(alice, ethKey, M2_LOWER, M2_UPPER, 1e18);
        uint128 units = _receive(M2, alice, key);
        _washEth();
        (uint256 a0,) = _balances(M2, alice);
        uint256[] memory amounts = _unwind(key, units, _zeros(), recipient);
        (uint256 r0, uint256 r1) = _balances(M2, recipient);
        assertEq(r0, amounts[0], "WETH principal");
        assertEq(r1, amounts[1], "USDC principal");
        assertGt(r0, 0);
        (uint256 b0,) = _balances(M2, alice);
        assertGt(b0, a0, "ETH fees as WETH");
        assertEq(address(vault).balance, 0, "no ETH held");
        assertEq(recipient.balance, 0, "no ETH sent");
    }

    // TEST-334 verifies: REQ-AMM-V4-004, REQ-AMM-CORE-007
    function test_TEST_334_unwindEnforcesMinimums() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        _lock();
        vm.prank(coll);
        vm.expectRevert();
        vault.unwind(key, units, _vec(type(uint128).max, 0), recipient);
        _unlock();
    }

    // TEST-334 verifies: REQ-AMM-V4-004, REQ-AMM-V4-010, REQ-VAULT-064
    function test_TEST_334_collectFeesPaysExactlyTheAccruedFees() public {
        bytes32 key = _mintFor(alice, ethKey, M2_LOWER, M2_UPPER, 1e18);
        _receive(M2, alice, key);
        _washEth();
        (uint256 a0, uint256 a1) = _balances(M2, alice);
        uint256[] memory fees = _collectAsAdapter(key, alice);
        (uint256 b0, uint256 b1) = _balances(M2, alice);
        assertEq(b0 - a0, fees[0], "fee0");
        assertEq(b1 - a1, fees[1], "fee1");
        assertGt(fees[0] + fees[1], 0);
    }

    // TEST-334 verifies: REQ-AMM-V4-010
    function test_TEST_334_wrappedFeeGrowthNeverPanics() public {
        // Push the pool's global fee growth to just below 2^256 before the position exists, so the swaps below wrap it.
        bytes32 state = UniswapV4State.poolStateSlot(_poolId(stableKey));
        vm.store(address(pm), bytes32(uint256(state) + 1), bytes32(type(uint256).max - 1e20));
        vm.store(address(pm), bytes32(uint256(state) + 2), bytes32(type(uint256).max - 1e20));
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 units = _receive(M1, alice, key);
        _washV4(stableKey, 1e14);
        uint256 g0 = uint256(IUniswapV4PoolManager(address(pm)).extsload(bytes32(uint256(state) + 1)));
        assertLt(g0, 1e40, "global fee growth wrapped");
        (uint256 a0, uint256 a1) = _balances(M1, alice);
        uint256[] memory fees = _collectAsAdapter(key, alice);
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertEq(b0 - a0, fees[0]);
        assertEq(b1 - a1, fees[1]);
        assertGt(fees[0] + fees[1], 0);
        _unwind(key, units, _zeros(), recipient);
    }

    // ─── Risk, depth and consistency ───

    // TEST-333 verifies: REQ-AMM-V4-008, SPEC-CAP-005
    function test_TEST_333_depthIsTheReferencePoolsHarmonicMeanLiquidity() public {
        _observe(stableRef, 10);
        RiskStatus memory st = vault.riskStatus(M1, 60);
        assertTrue(st.depthAvailable);
        uint256 k = vault.unitExponent(M1);
        assertApproxEqRel(st.depthUnits, (1e18 + 13e6) / 10 ** k, 1e16);
        assertFalse(vault.riskStatus(M1, 0).depthAvailable);
        assertFalse(vault.riskStatus(M1, 1_000_000).depthAvailable, "older than the buffer");
    }

    // TEST-333 verifies: REQ-AMM-V4-005, SPEC-AMM-V4-002
    function test_TEST_333_consistencyCombinesSpotGateAndReferenceTwap() public {
        _observe(ethRef, 10);
        (uint256 dev, bool ok) = vault.consistencyDeviation(M2, 60, _vec(ETH_PRICE, ONE));
        assertTrue(ok);
        assertLe(dev, 2, "both at the oracle price");
        // Park the v4 pool 10% off: the spot gate alone fails it.
        (uint160 s,) = _slot0V4(ethKey);
        _swapV4To(ethKey, uint160((uint256(s) * 95) / 100));
        (dev, ok) = vault.consistencyDeviation(M2, 60, _vec(ETH_PRICE, ONE));
        assertTrue(ok);
        assertGt(dev, 1000, "spot parked off-price");
        // Unavailable without enough observations for the window.
        (, ok) = vault.consistencyDeviation(M2, 1_000_000, _vec(ETH_PRICE, ONE));
        assertFalse(ok);
    }

    // TEST-333 verifies: REQ-AMM-CORE-008
    function test_TEST_333_riskMetadataReadsTheSingleton() public {
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        _receive(M1, alice, key);
        RiskMetadata memory meta = vault.riskMetadata(M1, key);
        assertTrue(meta.inRange);
        assertEq(meta.positionUnits, vault.unitsOf(key));
        assertGt(meta.poolUnits, 0);
    }

    // ─── Helpers ───

    /// @dev Sells 0.01 ETH and buys back with 20 USDC, so both legs pay fees and the price ends near where it started.
    function _washEth() internal {
        v4Actor.swap(ethKey, true, -1e16, 4_295_128_740);
        v4Actor.swap(ethKey, false, -20e6, 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341);
    }

    function _expectBind(
        PoolKey memory key,
        address ref,
        bytes memory err
    ) internal {
        _expectBindRange(key, ref, -60, 60, err);
    }

    function _expectBindRange(
        PoolKey memory key,
        address ref,
        int24 lower,
        int24 upper,
        bytes memory err
    ) internal {
        vm.prank(registry);
        vm.expectRevert(err);
        vault.bindMarket(
            9, address(0), _poolId(key), PositionShape(ShapeKind.TickRange, lower, upper), _bindData(key, ref, ONE, ONE)
        );
    }

    function _collectAsAdapter(
        bytes32 key,
        address depositor
    ) internal returns (uint256[] memory fees) {
        _lock();
        vm.prank(coll);
        fees = vault.collectFees(key, depositor);
        _unlock();
    }

    // TEST-336 verifies: REQ-AMM-V4-012, REQ-AMM-CORE-020
    function test_TEST_336_recordCapIsTwelve() public view {
        assertEq(vault.maxRecordsPerAccountMarket(), 12);
    }

    /// @dev The fees the PoolManager would credit a PositionManager position now (`Position.update`).
    function _feesNow(
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

    /// @dev `INCREASE_LIQUIDITY(tokenId, liquidity, max, max, "")` then `SETTLE_PAIR`.
    function _increaseData(
        PoolKey memory k,
        uint256 tokenId,
        uint128 liquidity
    ) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(0x00), A_SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(k.currency0, k.currency1);
        return abi.encode(actions, params);
    }
}
