// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../src/custody/collateralization/ICollateralizationAdapter.sol";
import {ICollateralizationEvents} from "../../src/custody/collateralization/ICollateralizationEvents.sol";
import {CounterKind} from "../../src/custody/collateralization/types/CounterKind.sol";
import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {IMarketRegistryFreeze} from "../../src/policy/market-registry/IMarketRegistryFreeze.sol";
import {IMarketRegistryPause} from "../../src/policy/market-registry/IMarketRegistryPause.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {BytecodeInspector} from "../utils/BytecodeInspector.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollateralizationLedgerHarness, HarnessLock} from "../utils/harness/CollateralizationLedgerHarness.sol";
import {CollOracleMock, CollRiskModuleMock} from "../utils/mocks/CollateralizationMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice The ledger harness with settable exposure counters, to drive a counter below the amount a release
/// subtracts.
contract CollateralizationSaturationHarness is CollateralizationLedgerHarness {
    address public constant DEPOSITOR = address(uint160(0xD0D0));

    constructor(
        address adapter,
        address lpVaultSwap,
        address lock
    ) CollateralizationLedgerHarness(adapter, lpVaultSwap, lock) {}

    function setCounters(
        uint256 regular,
        uint256 token0,
        uint256 depositor
    ) external {
        marketUsd[VT][Bucket.Regular] = regular;
        tokenUsd[HUB][TOKEN0] = token0;
        depositorUsd[HUB][DEPOSITOR] = depositor;
    }

    function counters() external view returns (uint256 regular, uint256 token0, uint256 token1, uint256 depositor) {
        return
            (marketUsd[VT][Bucket.Regular], tokenUsd[HUB][TOKEN0], tokenUsd[HUB][TOKEN1], depositorUsd[HUB][DEPOSITOR]);
    }
}

/// @title CollateralizationSurfaceUnitTest
/// @notice What Collateralization is not: it has no sweep, rescue, borrow, multicall, ERC-1271 or token-receiver entry
/// point; its code makes no AMM protocol call, no PositionProxy call, no Spoke supply or borrow and reads no price
/// state, pause state, freeze or liquidation bonus; in a full pledge, liquidation, pending settlement and withdrawal
/// sequence every call it makes goes to the market's LPVault, the RiskModule (views only), the LPOracle's `poke`, the
/// Lock, the factory, the vault token, Aave and the market tokens, and it ends holding no vault token and no
/// position. Upstream errors (LPOracle, RiskModule, LPVault, market token) reach the caller unchanged and move
/// nothing; a counter subtraction below zero clamps and emits `CounterSaturated`.
/// forge-config: default.isolate = false
contract CollateralizationSurfaceUnitTest is CollateralizationFixture {
    using BytecodeInspector for bytes;

    bytes32 internal constant KEY_A = bytes32(uint256(42));
    bytes32 internal constant KEY_B = bytes32(uint256(7));

    function setUp() public {
        _deployCollateralization();
    }

    // ─── Entry points ───

    /// @notice No sweep or rescue (tokens, vault tokens, ETH, positions), no borrow, multicall or combined
    /// pledge-and-borrow, no `execute`, no ERC-1271 `isValidSignature`, no ERC-721 or ERC-1155 receiver and no
    /// approval function exist: each call reaches no function and reverts with empty data, and plain ETH is refused.
    /// @dev Kills: any such function added to Collateralization or one of its abstract parts.
    // TEST-032 verifies: REQ-COLL-009, REQ-VAULT-023, REQ-VAULT-090, REQ-VAULT-100
    function test_TEST_032_noSweepBorrowMulticallSignatureOrReceiverEntryPoints() public {
        string[22] memory absent = [
            "sweep(address,address,uint256)",
            "sweep(address)",
            "sweepToken(address,address)",
            "rescue(address,address,uint256)",
            "rescueTokens(address,address,uint256)",
            "rescueERC20(address,uint256)",
            "rescueETH(address)",
            "rescuePosition(uint32,bytes32,address)",
            "recoverERC20(address,uint256)",
            "returnStray(bytes32,address)",
            "skim(address)",
            "borrow(address,uint256,uint256,address)",
            "borrow(uint256,uint256,address)",
            "pledgeAndBorrow(address,address,address,bytes32,uint256,uint256)",
            "multicall(bytes[])",
            "multicall(uint256,bytes[])",
            "execute(address,bytes)",
            "isValidSignature(bytes32,bytes)",
            "onERC721Received(address,address,uint256,bytes)",
            "onERC1155Received(address,address,uint256,uint256,bytes)",
            "setApprovalForAll(address,bool)",
            "approve(address,uint256)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok, bytes memory ret) =
                address(coll).call(abi.encodePacked(bytes4(keccak256(bytes(absent[i]))), new bytes(32 * 6)));
            assertFalse(ok, absent[i]);
            assertEq(ret.length, 0, absent[i]);
        }
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        (bool sent,) = address(coll).call{value: 1}("");
        assertFalse(sent, "ETH accepted");
        assertEq(
            ICollateralizationAdapter.pledge.selector,
            bytes4(keccak256("pledge(address,address,address,bytes32,bool)")),
            "pledge takes no deadline and no borrow"
        );
    }

    /// @notice Collateralization's runtime code carries no selector of an AMM protocol call (position manager,
    /// pool), of `PositionProxy.execute`, of a Spoke supply, collateral switch, borrow or liquidation, of a price-state,
    /// pause-state or freeze read, or of the liquidation bonus.
    /// @dev Kills: a call of any of these added to Collateralization (the selector constant would appear in its code).
    // TEST-032 verifies: REQ-COLL-004, REQ-VAULT-019, REQ-VAULT-020, REQ-VAULT-063, REQ-VAULT-090
    function test_TEST_032_codeCallsNoAmmProxySupplyOrPolicyRead() public view {
        bytes memory code = address(coll).code;
        bytes4[20] memory forbidden = [
            INonfungiblePositionManager.positions.selector,
            INonfungiblePositionManager.mint.selector,
            INonfungiblePositionManager.increaseLiquidity.selector,
            INonfungiblePositionManager.decreaseLiquidity.selector,
            INonfungiblePositionManager.collect.selector,
            bytes4(keccak256("safeTransferFrom(address,address,uint256)")),
            bytes4(keccak256("setApprovalForAll(address,bool)")),
            IUniswapV3Pool.slot0.selector,
            IUniswapV3Pool.observe.selector,
            IUniswapV3Pool.swap.selector,
            IPositionProxy.execute.selector,
            IAaveV4Spoke.supply.selector,
            IAaveV4Spoke.setUsingAsCollateral.selector,
            IAaveV4Spoke.borrow.selector,
            IAaveV4Spoke.liquidationCall.selector,
            IAaveV4Spoke.getLiquidationBonus.selector,
            ILPOracle.getPriceState.selector,
            ILPOracle.latestAnswer.selector,
            IMarketRegistryPause.pauseState.selector,
            IMarketRegistryFreeze.isFrozenAddress.selector
        ];
        for (uint256 i = 0; i < forbidden.length; ++i) {
            assertFalse(_pushes(code, forbidden[i]), "forbidden call in Collateralization");
        }
        assertFalse(_pushes(code, IMarketRegistryPause.pauseReason.selector), "pause reason read");
        assertFalse(_pushes(code, bytes4(keccak256("isValidSignature(bytes32,bytes)"))), "ERC-1271");
        assertFalse(code.hasOpcode(0, code.length, 0xf4), "DELEGATECALL");
        assertTrue(_pushes(code, ILPOracle.poke.selector), "scan sanity: the pledge's poke");
        assertTrue(_pushes(code, ICollateralizationAdapter.pledge.selector), "scan sanity: the dispatcher");
    }

    /// @dev Whether `code` builds `selector` as a call's first word in any of the forms the via-IR optimizer emits:
    /// a PUSH of the selector shifted into the top bytes (`PUSHn v; PUSH1 k; SHL` with `v << k == selector << 224`,
    /// which also covers `PUSH4 selector; PUSH1 224; SHL`), a left-aligned PUSH32, or a plain PUSH4.
    function _pushes(
        bytes memory code,
        bytes4 selector
    ) private pure returns (bool) {
        uint256 target = uint256(uint32(selector)) << 224;
        uint256 i = 0;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op < 0x60 || op > 0x7f) {
                ++i;
                continue;
            }
            uint256 n = op - 0x5f;
            if (i + n >= code.length) break;
            uint256 v = 0;
            for (uint256 k = 1; k <= n; ++k) {
                v = (v << 8) | uint8(code[i + k]);
            }
            if (n == 4 && v == uint32(selector)) return true;
            if (n == 32 && v == target) return true;
            uint256 j = i + n + 1;
            if (n <= 4 && j + 2 < code.length && uint8(code[j]) == 0x60 && uint8(code[j + 2]) == 0x1b) {
                uint256 shift = uint8(code[j + 1]);
                if (v != 0 && shift < 256 && (v << shift) == target && (v << shift) >> shift == v) return true;
            }
            i = j;
        }
        return false;
    }

    // ─── Calls in a full sequence ───

    /// @notice Two pledges, a borrow, a kept seizure, an honest liquidation that reconciles it into pending, the
    /// pending settlement and a withdrawal: every call Collateralization makes goes to the market's LPVault, the
    /// RiskModule (static calls only: it computes over the ledger and stores nothing), the LPOracle's `poke`, the Lock,
    /// the factory, the vault token, the Aave Hub and Spoke and the market tokens; never to a proxy. Collateralization
    /// ends holding no vault token, no position and no market token.
    /// @dev Kills: a call from Collateralization to a proxy, to an AMM contract or to any other address, a
    /// state-changing RiskModule call, or units or positions left in Collateralization.
    // TEST-032 verifies: REQ-COLL-004, REQ-VAULT-019, REQ-VAULT-028, REQ-VAULT-063, REQ-VAULT-090
    function test_TEST_032_fullSequenceCallsOnlyItsNeighbours() public {
        vm.startStateDiffRecording();
        _pledge(alice, aliceProxy, KEY_A, 5_000_000_000);
        _pledge(bob, bobProxy, KEY_B, 2_000_000_000);
        _borrow(aliceProxy, 7000e18);
        vtPrice.set(1.6e8);
        uint256 kept = _seizeAndKeep(aliceProxy, 1000e18);
        _liquidate(aliceProxy, 1000e18);
        _settlePending(kept);
        _withdraw(bobProxy, KEY_B, 2_000_000_000);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        address[11] memory allowed = [
            address(lpVault),
            address(riskModule),
            address(oracle),
            address(lock),
            address(factory),
            vt,
            aave.cdpSpoke,
            aave.hub,
            address(usdc),
            address(usdt),
            address(coll)
        ];
        uint256 calls;
        uint256 riskReads;
        for (uint256 i = 0; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.accessor != address(coll)) continue;
            // A DELEGATECALL inside an Aave proxy keeps Collateralization as its caller; Collateralization's own code
            // has no DELEGATECALL (`test_TEST_032_codeCallsNoAmmProxySupplyOrPolicyRead`).
            if (a.kind != VmSafe.AccountAccessKind.Call && a.kind != VmSafe.AccountAccessKind.StaticCall) continue;
            ++calls;
            assertTrue(a.account != aliceProxy && a.account != bobProxy, "Collateralization called a proxy");
            bool ok = false;
            for (uint256 k = 0; k < allowed.length; ++k) {
                if (a.account == allowed[k]) ok = true;
            }
            assertTrue(ok, "call to an address outside the market's neighbours");
            if (a.account == address(riskModule)) {
                ++riskReads;
                // `checkPledge` is reached by a plain CALL: it charges the market's pledge-speed window when
                // Collateralization calls (REQ-RISK-006, REQ-RISK-095); it is the only RiskModule call Collateralization makes.
                assertTrue(a.kind == VmSafe.AccountAccessKind.Call, "checkPledge reached by a plain call");
                assertEq(
                    bytes4(a.data), IRiskModuleChecks.checkPledge.selector, "Collateralization calls only checkPledge"
                );
            }
        }
        assertGt(calls, 0, "sanity: calls recorded");
        assertGt(riskReads, 0, "sanity: the pledge's RiskModule check recorded");
        assertEq(token.balanceOf(address(coll)), 0, "vault tokens in Collateralization");
        assertEq(lpVault.ownerOf(KEY_A), address(lpVault), "the open position sits in the LPVault");
        assertEq(lpVault.ownerOf(KEY_B), bob, "the withdrawn position is back with its depositor");
        assertEq(usdc.balanceOf(address(coll)) + usdt.balanceOf(address(coll)), 0, "market tokens left");
    }

    // ─── Upstream errors ───

    /// @notice A failing LPOracle `poke`, a RiskModule refusal and a locked pool in the LPVault each reach the caller
    /// with the upstream error unchanged, and the pledge moves nothing: the position stays with its owner, no record,
    /// no credit and no counter.
    /// @dev Kills: Collateralization catching, re-wrapping or skipping an upstream revert in `pledge`, or a supply check
    /// added to `pledge` (the last pledge, made before any supply, would revert).
    // TEST-011 verifies: REQ-VAULT-092, REQ-VAULT-144, REQ-VAULT-020
    function test_TEST_011_upstreamErrorsPassThroughAndMoveNothing() public {
        lpVault.mintPosition(KEY_A, alice, MARKET_ID, 5_000_000_000);
        uint256 before = coll.getCounters(vt, alice).depositorUsed;
        vm.startPrank(adapter);
        lock.acquire();
        token.addValidProxy(aliceProxy);

        CollOracleMock(address(oracle)).setFail(true);
        vm.expectRevert(CollOracleMock.PokeFailed.selector);
        coll.pledge(alice, aliceProxy, vt, KEY_A, false);
        CollOracleMock(address(oracle)).setFail(false);

        CollRiskModuleMock(address(riskModule)).setRefuse(true);
        vm.expectRevert(abi.encodeWithSelector(CollRiskModuleMock.Refused.selector, uint128(5_000_000_000)));
        coll.pledge(alice, aliceProxy, vt, KEY_A, false);
        CollRiskModuleMock(address(riskModule)).setRefuse(false);

        lpVault.setPoolLocked(true);
        vm.expectRevert(bytes4(keccak256("PoolLocked()")));
        coll.pledge(alice, aliceProxy, vt, KEY_A, false);
        lpVault.setPoolLocked(false);

        lock.release();
        vm.stopPrank();
        assertEq(lpVault.ownerOf(KEY_A), alice, "position not taken");
        assertEq(coll.recordIdOf(INTEGRATION, KEY_A), 0, "no record");
        assertEq(coll.getTotalCredited(vt), 0, "no credit");
        assertEq(coll.getCounters(vt, alice).depositorUsed, before, "no counter");

        // With every upstream answering, `pledge` completes before any supply: the proxy has supplied nothing and
        // Collateralization checks no supply (the Adapter's check runs after the proxy's supply).
        vm.startPrank(adapter);
        lock.acquire();
        (, uint128 credited) = coll.pledge(alice, aliceProxy, vt, KEY_A, false);
        lock.release();
        vm.stopPrank();
        assertEq(credited, 5_000_000_000, "credited");
        assertEq(_shares(aliceProxy), 0, "nothing supplied when pledge returned");
    }

    /// @notice A market token that reverts on the transfer in `settlePending` reverts the call with the token's own
    /// error; the burn, the pending balance and the pending units stay as they were, and a later settlement pays them.
    /// @dev The burn and the settlement run in one external call, as LPVaultSwap makes them, so the revert undoes both.
    /// Kills: a `settlePending` that swallows a failed transfer or writes the pending balance down before it.
    // TEST-170 verifies: REQ-VAULT-142, REQ-VAULT-092
    function test_TEST_170_tokenRevertInSettlePendingChangesNothing() public {
        _pledge(alice, aliceProxy, KEY_A, 5_000_000_000);
        _borrow(aliceProxy, 7000e18);
        vtPrice.set(1.6e8);
        uint256 kept = _seizeAndKeep(aliceProxy, 1000e18);
        _liquidate(aliceProxy, 1000e18);
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, kept, "kept units reconciled into pending");
        uint256 supply = token.totalSupply();
        uint256 swapUnits = token.balanceOf(lpVaultSwap);
        uint256 collUsdc = usdc.balanceOf(address(coll));

        bytes memory frozen = abi.encodeWithSignature("TokenFrozen(address)", address(coll));
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector), frozen);
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.expectRevert(frozen);
        this.burnAndSettlePending(kept);
        vm.prank(lpVaultSwap);
        lock.release();

        Pending memory q = coll.getPending(vt);
        assertEq(q.units, p.units, "pending units");
        assertEq(q.amounts[0], p.amounts[0], "pending amount 0");
        assertEq(q.amounts[1], p.amounts[1], "pending amount 1");
        assertEq(token.totalSupply(), supply, "the burn reverted with the call");
        assertEq(token.balanceOf(lpVaultSwap), swapUnits, "LPVaultSwap keeps its units");
        assertEq(usdc.balanceOf(address(coll)), collUsdc, "pending USDC still held");

        vm.clearMockedCalls();
        uint256[] memory paid = _settlePending(kept);
        assertEq(paid[0], p.amounts[0], "a later settlement pays the pending amounts");
        assertEq(coll.getPending(vt).units, 0);
    }

    /// @dev LPVaultSwap's settlement step in one call: the Adapter burns the kept units, then `settlePending`.
    function burnAndSettlePending(
        uint256 units
    ) external {
        vm.prank(adapter);
        token.burn(lpVaultSwap, units);
        vm.prank(lpVaultSwap);
        coll.settlePending(vt, units);
    }

    // ─── Counter saturation ───

    /// @notice A release whose charge exceeds a counter clamps that counter at 0 and emits `CounterSaturated` with the
    /// value before and the amount; counters with room are lowered normally, and nothing reverts.
    /// @dev Kills: a checked subtraction (the release would revert) or a clamp without the event.
    // TEST-097 verifies: REQ-VAULT-127, REQ-VAULT-037
    function testFuzz_TEST_097_counterBelowZeroClampsAndEmits(
        uint64 charge,
        uint256 regular,
        uint256 token0,
        uint256 depositor
    ) public {
        charge = uint64(bound(charge, 2, type(uint64).max));
        regular = bound(regular, 0, charge - 1);
        token0 = bound(token0, 0, charge - 1);
        depositor = bound(depositor, 0, charge - 1);
        HarnessLock hl = new HarnessLock();
        CollateralizationSaturationHarness h = new CollateralizationSaturationHarness(adapter, lpVaultSwap, address(hl));
        uint256 id = h.seed(aliceProxy, 1e9, charge, 0, 0);
        h.setCounters(regular, token0, depositor);
        address hubAddr = h.HUB();

        vm.expectEmit(address(h));
        emit ICollateralizationEvents.CounterSaturated(CounterKind.MarketRegular, hubAddr, h.VT(), regular, charge);
        vm.expectEmit(address(h));
        emit ICollateralizationEvents.CounterSaturated(CounterKind.Token, hubAddr, h.TOKEN0(), token0, charge);
        vm.expectEmit(address(h));
        emit ICollateralizationEvents.CounterSaturated(CounterKind.Depositor, hubAddr, h.DEPOSITOR(), depositor, charge);
        h.close(id);

        (uint256 r, uint256 t0, uint256 t1, uint256 d) = h.counters();
        assertEq(r, 0, "market counter clamped");
        assertEq(t0, 0, "token0 counter clamped");
        assertEq(t1, 0, "token1 counter lowered by exactly the charge");
        assertEq(d, 0, "depositor counter clamped");
    }
}
