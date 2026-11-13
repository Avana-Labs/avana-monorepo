// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CoverageSpoke} from "../../src/coverage/coverage-spoke/CoverageSpoke.sol";
import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationSeizure} from "../../src/custody/collateralization/ICollateralizationSeizure.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {IAaveAdapterSettlement} from "../../src/policy/aave-adapter/IAaveAdapterSettlement.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice A hostile LPVaultSwap implementation installed through the timelock: it makes any call the test names from
/// LPVaultSwap's own address (seizing and keeping vault tokens, Lock and ledger calls), bubbling every revert.
contract HostileLiquidatorImpl is UUPSUpgradeable {
    address internal immutable OWNER;

    constructor(
        address owner_
    ) {
        OWNER = owner_;
    }

    function run(
        address target,
        bytes calldata data
    ) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _authorizeUpgrade(
        address
    ) internal view override {
        require(msg.sender == OWNER, "owner");
    }
}

/// @title LPVaultSwapHostileIntegrationTest
/// @notice A hostile LPVaultSwap installed through the timelock on the full local stack (the real AaveAdapter,
/// Collateralization, RiskModule, Lock, vault token, PositionProxies, ProxyManager, PayoutEscrow, Coverage Spokes and
/// Aave V4): what it cannot do (TEST-131), the C-QNT-1 regression through the borrower's exits and the honest
/// pending settlement into the Coverage Spoke (TEST-154), the Adapter's seized-unit burn (TEST-208), each record's
/// proxy (TEST-089) and coverage of each asset's own deficits only (TEST-211).
/// forge-config: default.isolate = false
contract LPVaultSwapHostileIntegrationTest is IntegrationFlows {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal honestImpl;
    HostileLiquidatorImpl internal hostile;

    function setUp() public {
        _deployIntegration();
        honestImpl = address(uint160(uint256(vm.load(lpVaultSwap, IMPL_SLOT))));
        hostile = new HostileLiquidatorImpl(timelock);
    }

    function _installHostile() internal {
        vm.prank(timelock);
        UUPSUpgradeable(lpVaultSwap).upgradeToAndCall(address(hostile), "");
    }

    function _restoreHonest() internal {
        vm.prank(timelock);
        UUPSUpgradeable(lpVaultSwap).upgradeToAndCall(honestImpl, "");
        assertEq(address(uint160(uint256(vm.load(lpVaultSwap, IMPL_SLOT)))), honestImpl, "honest implementation");
    }

    function _run(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        return HostileLiquidatorImpl(lpVaultSwap).run(target, data);
    }

    /// @dev The hostile implementation repays `amount` of `proxy`'s USDC debt through `liquidationCall` and keeps the
    /// seized vault tokens. Returns the units it received.
    function _hostileSeizeAndKeep(
        address proxy,
        uint256 amount
    ) internal returns (uint256 c) {
        address vtAddr = _vtAddr(MARKET_ID);
        uint256 before = IERC20(vtAddr).balanceOf(lpVaultSwap);
        usdc.mint(lpVaultSwap, amount);
        _run(address(usdc), abi.encodeCall(IERC20.approve, (aave.cdpSpoke, amount)));
        _run(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.liquidationCall, (_vtReserve(MARKET_ID), usdcReserveId, proxy, amount, false))
        );
        c = IERC20(vtAddr).balanceOf(lpVaultSwap) - before;
    }

    /// @notice A hostile LPVaultSwap cannot seize a healthy account (Aave refuses it), mint vault tokens, burn more than
    /// it holds through the Adapter, or debit another account's records: settling bob's seizure under alice's snapshot
    /// reverts `SeizureMismatch` and settling alice for bob's units reverts `DebitMismatch`.
    // TEST-131 verifies: REQ-VAULT-049, REQ-VAULT-050, REQ-VAULT-051, REQ-ADAPTER-070, ATTACK-025, ATTACK-079
    function test_TEST_131_hostileLPVaultSwapBoundedByAaveAndTheLedger() public {
        (address healthy,) = _openAccount(alice, MARKET_ID, 10_000e6, 5000e6, 250_000_000);
        (address bobProxy,) = _bobAccount();
        _installHostile();
        address vtAddr = _vtAddr(MARKET_ID);
        usdc.mint(lpVaultSwap, 1000e6);
        _run(address(usdc), abi.encodeCall(IERC20.approve, (aave.cdpSpoke, 1000e6)));
        vm.expectRevert();
        _run(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.liquidationCall, (_vtReserve(MARKET_ID), usdcReserveId, healthy, 1000e6, false))
        );
        vm.expectRevert(IVaultToken.OnlyAdapter.selector);
        _run(vtAddr, abi.encodeWithSignature("mint(address,uint256)", lpVaultSwap, 1));

        _run(address(lock), abi.encodeCall(ILock.acquire, ()));
        _run(address(coll), abi.encodeCall(ICollateralizationSeizure.beginSeizure, (healthy, vtAddr)));
        uint256 c = _hostileSeizeAndKeep(bobProxy, 1000e6);
        assertGt(c, 0, "bob seized");
        vm.expectRevert();
        _run(adapter, abi.encodeCall(IAaveAdapterSettlement.burnSeized, (MARKET_ID, vtAddr, c + 1)));
        _run(adapter, abi.encodeCall(IAaveAdapterSettlement.burnSeized, (MARKET_ID, vtAddr, c)));
        vm.expectRevert(ICollateralizationErrors.SeizureMismatch.selector);
        _run(
            address(coll),
            abi.encodeCall(ICollateralizationSeizure.settleSeizure, (bobProxy, vtAddr, c, new uint256[](0)))
        );
        vm.expectRevert(ICollateralizationErrors.DebitMismatch.selector);
        _run(
            address(coll),
            abi.encodeCall(ICollateralizationSeizure.settleSeizure, (healthy, vtAddr, c, new uint256[](0)))
        );
        _run(address(lock), abi.encodeCall(ILock.release, ()));
        assertEq(coll.getAccountCredited(healthy, vtAddr), 10_000e6, "alice's records untouched");
    }

    /// @notice C-QNT-1: records of 1,000 and 800 units; a hostile LPVaultSwap installed through the timelock seizes
    /// about 315 units and keeps them. The borrower repays and withdraws NFT 42 (the shortfall reconciled into pending,
    /// NFT 42 back with its remaining liquidity), then NFT 7 (all 800 units); the honest LPVaultSwap restored through the
    /// timelock settles the pending units, after which the market's vault-token supply is 0 and the USDC recovered
    /// has gone to the USDC Coverage Spoke. No position stays in custody.
    // TEST-154 verifies: REQ-SWAP-066, REQ-VAULT-129, REQ-VAULT-131, INV-001, INV-042, Q-201
    function test_TEST_154_cQnt1ThroughTheExitsAndTheCoverageSpoke() public {
        address vtAddr = _vtAddr(MARKET_ID);
        IntegLPVaultLike lpv = IntegLPVaultLike(address(markets[MARKET_ID].vault));
        _setPrice(MARKET_ID, 250_000_000);
        (bytes32 k42, address proxy) = _pledgeVia(alice, MARKET_ID, 1000e6);
        (bytes32 k7,) = _pledgeVia(alice, MARKET_ID, 800e6);
        _borrowVia(alice, MARKET_ID, usdcReserveId, 3500e6);
        _setPrice(MARKET_ID, P_VAULT);
        _installHostile();
        uint256 c = _hostileSeizeAndKeep(proxy, 630e6);
        assertApproxEqAbs(c, 315e6, 1e6, "about 315 units seized and kept");

        _repayVia(alice, alice, MARKET_ID, usdcReserveId, 4000e6, true);
        uint256 units42 = coll.previewRelease(INTEGRATION, k42);
        assertEq(units42, 1000e6 - c, "NFT 42 previews its remaining units");
        _withdrawVia(alice, MARKET_ID, k42, units42);
        assertEq(lpv.ownerOf(k42), alice, "NFT 42 returned");
        assertEq(coll.getPending(vtAddr).units, c, "the kept units are pending");
        _withdrawVia(alice, MARKET_ID, k7, 800e6);
        assertEq(lpv.ownerOf(k7), alice, "NFT 7 returned");

        _restoreHonest();
        uint256 funded = usdcCoverage.fundedBalance();
        (uint256 units,, uint256 added) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(units, c, "the 315 pending units settled");
        assertEq(IERC20(vtAddr).totalSupply(), 0, "market supply 0");
        assertEq(coll.getPending(vtAddr).units, 0, "nothing pending");
        assertGt(added, 0, "USDC recovered");
        assertEq(usdcCoverage.fundedBalance(), funded + added, "recovered USDC funds the Coverage Spoke");
    }

    /// @notice The Adapter's seized-unit burn: any caller other than LPVaultSwap, and LPVaultSwap without the Lock,
    /// reverts `NotLPVaultSwap`; in a liquidation it burns exactly `c` from LPVaultSwap, emits `SeizedUnitsBurned`, and
    /// the proxy's share drop, `c` and the supply drop are equal, in the None, Frozen and Paused states alike.
    // TEST-208 verifies: REQ-ADAPTER-070, REQ-SWAP-020, REQ-SWAP-092
    function test_TEST_208_burnSeizedOnlyLPVaultSwapUnderTheLock() public {
        address vtAddr = _vtAddr(MARKET_ID);
        vm.prank(attacker);
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        IAaveAdapterSettlement(adapter).burnSeized(MARKET_ID, vtAddr, 1);
        vm.prank(lpVaultSwap);
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        IAaveAdapterSettlement(adapter).burnSeized(MARKET_ID, vtAddr, 1);
        PauseState[3] memory states = [PauseState.None, PauseState.Frozen, PauseState.Paused];
        (address proxy,) = _bobAccount();
        for (uint256 i = 0; i < 3; ++i) {
            reg.setPause(aave.hub, states[i], i == 0 ? PauseReason.None : PauseReason.General);
            uint256 shares = _suppliedOf(proxy, MARKET_ID);
            uint256 supply = IERC20(vtAddr).totalSupply();
            vm.recordLogs();
            LiquidationResult memory r = _liquidateAs(keeper, _liqParams(proxy, MARKET_ID, usdcReserveId, 1000e6));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 burns;
            for (uint256 k = 0; k < logs.length; ++k) {
                if (logs[k].emitter != adapter || logs[k].topics[0] != IAaveAdapterEvents.SeizedUnitsBurned.selector) {
                    continue;
                }
                ++burns;
                assertEq(uint256(logs[k].topics[1]), MARKET_ID, "event market");
                assertEq(address(uint160(uint256(logs[k].topics[2]))), vtAddr, "event vault token");
                assertEq(abi.decode(logs[k].data, (uint256)), r.unitsSeized, "event units = c");
            }
            assertEq(burns, 1, "one SeizedUnitsBurned");
            assertEq(shares - _suppliedOf(proxy, MARKET_ID), r.unitsSeized, "share drop = c");
            assertEq(supply - IERC20(vtAddr).totalSupply(), r.unitsSeized, "supply drop = c");
            assertEq(IERC20(vtAddr).balanceOf(lpVaultSwap), 0, "burned only from LPVaultSwap");
        }
    }

    /// @notice Every record's proxy is `proxyOf(depositor, marketId)` for its market, the proxy the ProxyManager
    /// deployed on the Adapter's call and the vault token registered: pledges into two markets from one wallet land on
    /// two proxies, each valid only in its own market's vault token.
    // TEST-089 verifies: REQ-PROXY-032, REQ-COLL-005, INV-043
    function test_TEST_089_recordProxyIsTheMarketsProxy() public {
        (bytes32 k1, address p1) = _pledgeVia(alice, MARKET_ID, 1000e6);
        (bytes32 k2, address p2) = _pledgeVia(alice, MARKET_B, 1000e6);
        assertEq(p1, adapterC.proxyOf(alice, MARKET_ID), "market A proxy");
        assertEq(p2, adapterC.proxyOf(alice, MARKET_B), "market B proxy");
        assertTrue(p1 != p2, "one proxy per market");
        assertEq(coll.getRecord(coll.recordIdOf(INTEGRATION, k1)).proxy, p1, "record A names proxy A");
        assertEq(coll.getRecord(coll.recordIdOf(INTEGRATION, k2)).proxy, p2, "record B names proxy B");
        assertEq(proxyManager.predictProxy(alice, aave.cdpSpoke, MARKET_ID), p1, "at the predicted address");
        assertTrue(IVaultToken(_vtAddr(MARKET_ID)).isValidProxy(p1), "valid in its market");
        assertFalse(IVaultToken(_vtAddr(MARKET_ID)).isValidProxy(p2), "not valid in another market");
        assertTrue(IVaultToken(_vtAddr(MARKET_B)).isValidProxy(p2), "valid in market B");
    }

    /// @notice Each Coverage Spoke covers only deficits of its own `(Hub, asset)`: an account owing USDC and GHO is
    /// liquidated to exhaustion so the CDP Spoke records a deficit in both assets; the USDC Coverage Spoke's cover lowers
    /// the USDC deficit and leaves the GHO deficit exactly unchanged.
    // TEST-211 verifies: SPEC-FLR-001, INV-079, ATTACK-173
    function test_TEST_211_coverageReducesOnlyItsOwnAssetsDeficit() public {
        (address p,) = _openAccount(carol, MARKET_ID, 10_000e6, 9000e6, 250_000_000);
        _setPrice(MARKET_ID, 250_000_000);
        _borrowVia(carol, MARKET_ID, debtReserveId, 5000e18);
        _setPrice(MARKET_ID, 30_000_000);
        _liquidateAs(keeper, _liqParams(p, MARKET_ID, usdcReserveId, 9000e6));
        IHubDeficitView h = IHubDeficitView(aave.hub);
        uint256 usdcDeficit = h.getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke);
        uint256 ghoDeficit = h.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke);
        assertGt(usdcDeficit, 0, "USDC deficit recorded");
        assertGt(ghoDeficit, 0, "GHO deficit recorded");
        _enableCover(address(usdcCoverage));
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(usdcCoverage), 1_000_000e6);
        usdcCoverage.fund(1_000_000e6);
        vm.prank(coverageCaller);
        (, uint256 covered) = usdcCoverage.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertGt(covered, 0, "USDC deficit covered");
        assertEq(h.getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke), 0, "USDC deficit cleared");
        assertEq(h.getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke), ghoDeficit, "GHO deficit unchanged");
    }

    function _enableCover(
        address cs
    ) internal {
        bytes4[] memory cover = new bytes4[](1);
        cover[0] = CoverageSpoke.coverDeficit.selector;
        bytes4[] memory admin = new bytes4[](1);
        admin[0] = CoverageSpoke.setAllowedBorrowSpoke.selector;
        IAccessManager m = IAccessManager(aave.accessManager);
        vm.startPrank(aaveDao);
        m.setTargetFunctionRole(cs, cover, 500);
        m.setTargetFunctionRole(cs, admin, 501);
        m.grantRole(500, coverageCaller, 0);
        m.grantRole(501, aaveGovernanceExecutor, 0);
        vm.stopPrank();
        vm.prank(aaveGovernanceExecutor);
        CoverageSpoke(cs).setAllowedBorrowSpoke(aave.cdpSpoke, true);
    }
}

interface IHubDeficitView {
    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);
}

interface IntegLPVaultLike {
    function ownerOf(
        bytes32 key
    ) external view returns (address);
}
