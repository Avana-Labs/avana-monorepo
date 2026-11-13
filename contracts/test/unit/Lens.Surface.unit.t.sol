// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILens} from "../../src/lens/lens/ILens.sol";
import {ILensAccount} from "../../src/lens/lens/ILensAccount.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {ILensLiquidation} from "../../src/lens/lens/ILensLiquidation.sol";
import {ILensMarket} from "../../src/lens/lens/ILensMarket.sol";
import {ILensMarkets} from "../../src/lens/lens/ILensMarkets.sol";
import {ILensPositions} from "../../src/lens/lens/ILensPositions.sol";
import {ILensPreview} from "../../src/lens/lens/ILensPreview.sol";
import {ILensRisk} from "../../src/lens/lens/ILensRisk.sol";
import {ILensSpeed} from "../../src/lens/lens/ILensSpeed.sol";
import {Lens} from "../../src/lens/lens/Lens.sol";
import {LensBase} from "../../src/lens/lens/LensBase.sol";
import {LensConstants} from "../../src/lens/lens/LensConstants.sol";
import {LensLiquidationModule} from "../../src/lens/lens/LensLiquidationModule.sol";
import {BytecodeInspector} from "../utils/BytecodeInspector.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensSurfaceUnitTest
/// @notice The Lens's form: every function a view, no state-changing opcode in any deployed part, no storage, the Lock
/// refusing every view, the entry point forwarding calldata, return data and revert data unchanged, and the
/// constructor's module check.
/// forge-config: default.isolate = false
contract LensSurfaceUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
    }

    // ─── form ───

    // TEST-247 verifies: REQ-LENS-001, Q-119, Q-226
    function test_TEST_247_everyFunctionIsView() public view {
        string[9] memory artifacts = [
            "out/Lens.sol/Lens.json",
            "out/LensAccountModule.sol/LensAccountModule.json",
            "out/LensMarketModule.sol/LensMarketModule.json",
            "out/LensPriceModule.sol/LensPriceModule.json",
            "out/LensLiquidationModule.sol/LensLiquidationModule.json",
            "out/LensRiskModule.sol/LensRiskModule.json",
            "out/LensPreviewModule.sol/LensPreviewModule.json",
            "out/LensMarketsModule.sol/LensMarketsModule.json",
            "out/LensPositionsModule.sol/LensPositionsModule.json"
        ];
        for (uint256 i = 0; i < artifacts.length; ++i) {
            string memory json = vm.readFile(artifacts[i]);
            uint256 functions = 0;
            for (uint256 j = 0; vm.keyExistsJson(json, string.concat(".abi[", vm.toString(j), "]")); ++j) {
                string memory at = string.concat(".abi[", vm.toString(j), "]");
                bytes32 k = keccak256(bytes(vm.parseJsonString(json, string.concat(at, ".type"))));
                assertTrue(k != keccak256("fallback") && k != keccak256("receive"), "no fallback or receive");
                if (k != keccak256("function")) continue;
                bytes32 m = keccak256(bytes(vm.parseJsonString(json, string.concat(at, ".stateMutability"))));
                assertTrue(m == keccak256("view") || m == keccak256("pure"), artifacts[i]);
                ++functions;
            }
            assertGt(functions, 4, "functions found");
        }
    }

    // TEST-247 verifies: REQ-LENS-001, REQ-LENS-003
    function test_TEST_247_noStateChangingOpcode() public view {
        uint8[12] memory forbidden = [0x55, 0x5d, 0xf0, 0xf1, 0xf2, 0xf4, 0xf5, 0xff, 0xa0, 0xa1, 0xa2, 0xa3];
        address[10] memory parts = _parts();
        for (uint256 i = 0; i < parts.length; ++i) {
            bytes memory code = parts[i].code;
            for (uint256 k = 0; k < forbidden.length; ++k) {
                assertFalse(
                    BytecodeInspector.hasOpcode(code, 0, code.length, forbidden[k]), "no SSTORE, CALL, LOG, ..."
                );
            }
            assertTrue(BytecodeInspector.hasOpcode(code, 0, code.length, 0xfa), "reads by STATICCALL");
        }
    }

    // TEST-247 verifies: REQ-LENS-001
    function test_TEST_247_noStorage() public view {
        address[10] memory parts = _parts();
        for (uint256 i = 0; i < parts.length; ++i) {
            for (uint256 slot = 0; slot < 8; ++slot) {
                assertEq(vm.load(parts[i], bytes32(slot)), bytes32(0), "no storage");
            }
        }
    }

    // TEST-247 verifies: REQ-LENS-001, REQ-LENS-002, REQ-LENS-040
    function test_TEST_247_gettersAndModules() public view {
        assertEq(lens.COLLATERALIZATION(), address(coll), "Collateralization");
        assertEq(lens.PROXY_MANAGER(), address(proxyManager), "ProxyManager");
        assertEq(lens.ADAPTER(), adapter, "AaveAdapter");
        assertEq(lens.LOCK(), address(lock), "Lock");
        assertEq(lens.MARKET_REGISTRY(), address(reg), "MarketRegistry");
        assertEq(lens.PARAMETER_STORE(), address(store), "ParameterStore");
        assertEq(lens.RISK_MODULE(), address(rm), "RiskModule");
        assertEq(lens.LP_VAULT_SWAP(), lpVaultSwap, "LPVaultSwap");
        assertEq(lens.PAYOUT_ESCROW(), address(escrow), "PayoutEscrow");
        assertEq(lens.LENS_MAX_PAGE(), 200, "page limit");
        assertEq(lens.LENS_DUST_MARGIN_BPS(), 500, "dust margin");
        address[9] memory m = lens.MODULES();
        for (uint256 i = 0; i < 9; ++i) {
            assertEq(m[i], modules[i], "module order");
            LensBase b = LensBase(m[i]);
            assertEq(b.COLLATERALIZATION(), address(coll), "module core");
            assertEq(b.PAYOUT_ESCROW(), address(escrow), "module core");
            assertEq(b.LENS_MAX_PAGE(), LensConstants.LENS_MAX_PAGE, "module constant");
        }
        assertEq(LensLiquidationModule(m[3]).AAVE_SIZING(), sizing, "the pinned Aave sizing");
    }

    // TEST-247 verifies: REQ-LENS-028, REQ-LENS-035, REQ-LENS-036, REQ-LENS-044
    function test_TEST_247_constants() public pure {
        assertEq(LensConstants.LENS_MAX_PAGE, 200, "200 records");
        assertEq(LensConstants.LENS_DUST_MARGIN_BPS, 500, "5 %");
        assertEq(LensConstants.RECOMMENDED_HEALTH_FACTOR, 1.1e18, "1.10");
        assertEq(LensConstants.BORROW_MAX_MARGIN_BPS, 50, "0.5 %");
        assertEq(LensConstants.REPAY_ALL_MARGIN_BPS, 10, "0.1 %");
    }

    // TEST-247 verifies: REQ-LENS-001, REQ-LENS-002
    function test_TEST_247_constructorRejectsMismatchedModules() public {
        address[9] memory other = core;
        other[5] = makeAddr("otherStore");
        address[9] memory mixed = modules;
        mixed[4] = _deployModules(other)[4];
        vm.expectRevert(ILensErrors.InvalidModules.selector);
        new Lens(mixed);
        mixed = modules;
        mixed[0] = _deployModules(other)[0];
        vm.expectRevert(ILensErrors.InvalidModules.selector);
        new Lens(mixed);
    }

    // TEST-247 verifies: REQ-LENS-001
    function test_TEST_247_constructorRejectsMissingModule() public {
        address[9] memory mixed = modules;
        mixed[2] = address(0);
        vm.expectRevert();
        new Lens(mixed);
        mixed[2] = makeAddr("noCode");
        vm.expectRevert();
        new Lens(mixed);
    }

    // TEST-247 verifies: REQ-LENS-040, REQ-LENS-002
    function test_TEST_247_secondLensServesTheSameChain() public {
        ILens second = ILens(address(new Lens(_deployModules(core))));
        assertEq(
            keccak256(abi.encode(second.getAccount(alice, MARKET_ID))),
            keccak256(abi.encode(lens.getAccount(alice, MARKET_ID))),
            "a new deployment answers identically; nothing migrates"
        );
    }

    // ─── forwarding ───

    // TEST-247 verifies: REQ-LENS-001, REQ-LENS-007
    function test_TEST_247_entryPointReturnsModuleAnswers() public view {
        _same(abi.encodeCall(ILensAccount.getAccount, (alice, MARKET_ID)), modules[0]);
        _same(abi.encodeCall(ILensAccount.predictProxy, (bob, MARKET_ID)), modules[0]);
        _same(abi.encodeCall(ILensAccount.getRecords, (aliceProxy, 0, 16)), modules[0]);
        _same(abi.encodeCall(ILensMarket.checkBacking, (vt)), modules[1]);
        _same(abi.encodeCall(ILensMarket.checkRecordBacking, (vt, 0, 200)), modules[1]);
        _same(abi.encodeCall(ILensMarket.getCapHeadroom, (vt, alice)), modules[1]);
        _same(abi.encodeCall(ILensMarket.getPendingSettlement, (vt)), modules[1]);
        _same(abi.encodeCall(ILensLiquidation.getPriceState, (vt)), modules[2]);
        _same(abi.encodeCall(ILensLiquidation.getDebtPriceState, (aave.cdpSpoke, usdcReserveId)), modules[2]);
        _same(abi.encodeCall(ILensLiquidation.getApplicationState, (aave.hub)), modules[2]);
        _same(abi.encodeCall(ILensLiquidation.getPauseReason, (aave.hub)), modules[2]);
        _same(abi.encodeCall(ILensLiquidation.previewLiquidation, (aliceProxy, debtReserveId, T0)), modules[3]);
        _same(abi.encodeCall(ILensRisk.getBreakerStatus, (MARKET_ID)), modules[4]);
        _same(abi.encodeCall(ILensRisk.isFrozenAddress, (alice)), modules[4]);
        _same(abi.encodeCall(ILensRisk.uncoveredDeficit, (aave.hub, address(debt))), modules[4]);
        _same(abi.encodeCall(ILensRisk.getTailCoverage, (aave.hub, address(debt))), modules[4]);
        _same(abi.encodeCall(ILensRisk.getHubAssetExposure, (aave.hub, address(debt))), modules[4]);
        _same(abi.encodeCall(ILensPreview.previewBorrowMax, (alice, MARKET_ID, debtReserveId, T0)), modules[5]);
        _same(abi.encodeCall(ILensPreview.quoteRepayAll, (alice, MARKET_ID, debtReserveId, T0)), modules[5]);
        _same(abi.encodeCall(ILensPreview.previewRecredit, (MARKET_ID, _key(1))), modules[5]);
        _same(abi.encodeCall(ILensMarkets.getMarket, (MARKET_ID)), modules[6]);
        _same(abi.encodeCall(ILensMarkets.getDebtReserves, (aave.cdpSpoke)), modules[6]);
        _same(abi.encodeCall(ILensPositions.getAccountRisk, (alice, MARKET_ID)), modules[7]);
        _same(abi.encodeCall(ILensPositions.previewWithdraw, (alice, MARKET_ID, _key(1), 0)), modules[7]);
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-022, REQ-LENS-032, REQ-LENS-033
    function test_TEST_247_entryPointReturnsModuleRevertData() public view {
        _sameRevert(abi.encodeCall(ILensLiquidation.previewLiquidation, (bobProxy, debtReserveId, T0)), modules[3]);
        _sameRevert(abi.encodeCall(ILensLiquidation.getDebtPriceState, (aave.cdpSpoke, 77)), modules[2]);
        _sameRevert(abi.encodeCall(ILensAccount.getAccount, (alice, 99)), modules[0]);
        _sameRevert(abi.encodeCall(ILensMarket.checkRecordBacking, (vt, 0, 201)), modules[1]);
        _sameRevert(abi.encodeCall(ILensRisk.getTailCoverage, (aave.hub, address(usdt))), modules[4]);
    }

    // TEST-247 verifies: REQ-LENS-001
    function test_TEST_247_unknownSelectorReverts() public {
        (bool ok,) = address(lens).call(abi.encodeWithSignature("liquidate(uint256)", 1));
        assertFalse(ok, "no fallback");
        (ok,) = address(lens).call{value: 1}("");
        assertFalse(ok, "no receive");
    }

    // TEST-247 verifies: REQ-LENS-025, REQ-LENS-007
    function test_TEST_247_dependencyInterfaceChangeReverts() public {
        vm.etch(address(reg), hex"00");
        (bool ok,) = address(lens).staticcall(abi.encodeCall(ILensAccount.getAccount, (alice, MARKET_ID)));
        assertFalse(ok, "a registry without the expected interface makes the call revert, never a hidden default");
        (ok,) = address(lens).staticcall(abi.encodeCall(ILensRisk.getBreakerStatus, (MARKET_ID)));
        assertTrue(ok, "views that do not read it still answer");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-025
    function test_TEST_247_dependencyRevertPropagates() public {
        vm.mockCallRevert(address(rm), abi.encodeWithSignature("getBreakerStatus(uint256)"), bytes("boom"));
        (bool ok, bytes memory ret) = address(lens).staticcall(abi.encodeCall(ILensRisk.getBreakerStatus, (MARKET_ID)));
        assertFalse(ok, "no try/catch");
        assertEq(ret, bytes("boom"), "the dependency's revert data");
        vm.clearMockedCalls();
    }

    // ─── Lock ───

    // TEST-060 verifies: REQ-LENS-006, REQ-LENS-021, REQ-LOCK-016, INV-054
    // TEST-222 verifies: ATTACK-093
    function test_TEST_060_everyViewRefusesWhileLocked() public {
        bytes[] memory calls = _allCalls();
        _holdLock();
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(lens).staticcall(calls[i]);
            assertFalse(ok, string.concat("refused while an Avana call is in flight #", vm.toString(i)));
            assertEq(bytes4(ret), ILensErrors.Locked.selector, string.concat("Locked() #", vm.toString(i)));
        }
        _releaseLock();
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok,) = address(lens).staticcall(calls[i]);
            assertTrue(ok, "answers once the Lock is free");
        }
    }

    // TEST-060 verifies: REQ-LENS-006, REQ-LENS-021
    // TEST-222 verifies: ATTACK-093
    function test_TEST_060_modulesRefuseDirectlyWhileLocked() public {
        vm.prank(lpVaultSwap);
        lock.acquire();
        (bool ok, bytes memory ret) = modules[0].staticcall(abi.encodeCall(ILensAccount.getAccount, (alice, MARKET_ID)));
        assertFalse(ok, "account module");
        assertEq(bytes4(ret), ILensErrors.Locked.selector, "Locked()");
        (ok, ret) =
            modules[3].staticcall(abi.encodeCall(ILensLiquidation.previewLiquidation, (aliceProxy, debtReserveId, T0)));
        assertFalse(ok, "liquidation module");
        assertEq(bytes4(ret), ILensErrors.Locked.selector, "Locked()");
        vm.prank(lpVaultSwap);
        lock.release();
    }

    // TEST-270 verifies: REQ-LENS-001, REQ-LENS-006
    function test_TEST_270_lensIsNoLockMember() public {
        vm.prank(address(lens));
        vm.expectRevert();
        lock.acquire();
        assertTrue(lock.AAVE_ADAPTER() != address(lens) && lock.LP_VAULT_SWAP() != address(lens), "not a member");
    }

    // TEST-060 verifies: REQ-LENS-006
    function test_TEST_060_gettersAnswerWhileLocked() public {
        _holdLock();
        assertEq(lens.LOCK(), address(lock), "immutable getters read no state");
        assertEq(lens.MODULES()[0], modules[0], "modules");
        _releaseLock();
    }

    // ─── helpers ───

    function _parts() internal view returns (address[10] memory p) {
        p[0] = address(lens);
        for (uint256 i = 0; i < 9; ++i) {
            p[i + 1] = modules[i];
        }
    }

    function _same(
        bytes memory data,
        address module
    ) internal view {
        (bool okA, bytes memory a) = address(lens).staticcall(data);
        (bool okB, bytes memory b) = module.staticcall(data);
        assertTrue(okA && okB, "both answer");
        assertEq(keccak256(a), keccak256(b), "byte for byte");
    }

    function _sameRevert(
        bytes memory data,
        address module
    ) internal view {
        (bool okA, bytes memory a) = address(lens).staticcall(data);
        (bool okB, bytes memory b) = module.staticcall(data);
        assertFalse(okA || okB, "both revert");
        assertEq(keccak256(a), keccak256(b), "revert data unchanged");
        assertGt(a.length, 3, "a custom error");
    }

    function _allCalls() internal view returns (bytes[] memory c) {
        c = new bytes[](34);
        address[] memory toks = new address[](1);
        toks[0] = address(usdc);
        uint256[] memory ids = new uint256[](1);
        ids[0] = MARKET_ID;
        c[0] = abi.encodeCall(ILensAccount.predictProxy, (alice, MARKET_ID));
        c[1] = abi.encodeCall(ILensAccount.getAccount, (alice, MARKET_ID));
        c[2] = abi.encodeCall(ILensAccount.getAccounts, (alice, ids));
        c[3] = abi.encodeCall(ILensAccount.getRecords, (aliceProxy, 0, 16));
        c[4] = abi.encodeCall(ILensAccount.getEscrowClaimable, (alice, toks));
        c[5] = abi.encodeCall(ILensMarket.checkBacking, (vt));
        c[6] = abi.encodeCall(ILensMarket.checkRecordBacking, (vt, 0, 10));
        c[7] = abi.encodeCall(ILensMarket.getPendingSettlement, (vt));
        c[8] = abi.encodeCall(ILensMarket.getCapHeadroom, (vt, alice));
        c[9] = abi.encodeCall(ILensLiquidation.getPriceState, (vt));
        c[10] = abi.encodeCall(ILensLiquidation.getDebtPriceState, (aave.cdpSpoke, debtReserveId));
        c[11] = abi.encodeCall(ILensLiquidation.getApplicationState, (aave.hub));
        c[12] = abi.encodeCall(ILensLiquidation.getPauseReason, (aave.hub));
        c[13] = abi.encodeCall(ILensLiquidation.previewLiquidation, (aliceProxy, debtReserveId, T0));
        c[14] = abi.encodeCall(ILensRisk.getBreakerStatus, (MARKET_ID));
        c[15] = abi.encodeCall(ILensRisk.getDebtBreakerStatus, (aave.cdpSpoke, debtReserveId));
        c[16] = abi.encodeCall(ILensRisk.isFrozenAddress, (alice));
        c[17] = abi.encodeCall(ILensRisk.getTailCoverage, (aave.hub, address(debt)));
        c[18] = abi.encodeCall(ILensRisk.uncoveredDeficit, (aave.hub, address(debt)));
        c[19] = abi.encodeCall(ILensRisk.getHubAssetExposure, (aave.hub, address(debt)));
        c[20] = abi.encodeCall(ILensPreview.previewBorrowMax, (alice, MARKET_ID, debtReserveId, T0));
        c[21] = abi.encodeCall(ILensPreview.previewBorrowRecommended, (alice, MARKET_ID, debtReserveId, T0));
        c[22] = abi.encodeCall(ILensPreview.quoteRepayAll, (alice, MARKET_ID, debtReserveId, T0));
        c[23] = abi.encodeCall(ILensPreview.previewRecredit, (MARKET_ID, _key(1)));
        c[24] =
            abi.encodeCall(ILensPreview.previewRepayWithCollateral, (alice, MARKET_ID, _key(1), 100e6, debtReserveId));
        c[25] = abi.encodeCall(ILensMarkets.getMarkets, (0, 10));
        c[26] = abi.encodeCall(ILensMarkets.getMarket, (MARKET_ID));
        c[27] = abi.encodeCall(ILensMarkets.getDebtReserve, (aave.cdpSpoke, debtReserveId));
        c[28] = abi.encodeCall(ILensMarkets.getDebtReserves, (aave.cdpSpoke));
        c[29] = abi.encodeCall(ILensPositions.getAccountRisk, (alice, MARKET_ID));
        c[30] = abi.encodeCall(ILensPositions.previewPledge, (alice, MARKET_ID, _key(1)));
        c[31] = abi.encodeCall(ILensPositions.previewWithdraw, (alice, MARKET_ID, _key(1), 0));
        c[32] = abi.encodeCall(ILensSpeed.getBorrowSpeed, (MARKET_ID, debtReserveId));
        c[33] = abi.encodeCall(ILensSpeed.getPledgeSpeed, (MARKET_ID));
    }
}
