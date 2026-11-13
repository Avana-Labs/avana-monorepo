// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../src/custody/collateralization/ICollateralizationAdapter.sol";
import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {IProxyManager} from "../../src/proxy/proxy-manager/IProxyManager.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PositionRef} from "../../src/types/PositionRef.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title AaveAdapterPledgeUnitTest
/// @notice `pledge` on the real Aave V4 Spoke, Collateralization, vault token, ProxyManager and PositionProxy: the
/// order of its checks, the proxy creation and binding, the empty-account rule at creation, the pause and freeze gates
/// with the rescue flag, the exact mint and supply, and the backing gap.
/// forge-config: default.isolate = false
contract AaveAdapterPledgeUnitTest is AaveAdapterFixture {
    // ─── Happy path, binding and mint ───

    // TEST-025 verifies: REQ-ADAPTER-066, REQ-PROXY-049, REQ-PROXY-053, REQ-PROXY-056, INV-064, Q-307
    // Sources: 5.1 TEST-025
    /// @notice The first pledge of a wallet to a market deploys its proxy at the ProxyManager's CREATE2 prediction,
    /// stores the binding once and emits `UserProxyCreated` before any supply through it.
    function test_TEST_025_firstPledgeCreatesAndBindsProxy() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        address predicted = proxyManager.predictProxy(alice, aave.cdpSpoke, MARKET_ID);
        assertEq(adapterC.predictProxy(alice, MARKET_ID), predicted, "predict before");
        assertEq(adapterC.proxyOf(alice, MARKET_ID), address(0), "no proxy yet");
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.UserProxyCreated(alice, aave.cdpSpoke, MARKET_ID, predicted);
        vm.prank(alice);
        (address proxy,,) = adapterC.pledge(MARKET_ID, _ref(key), _deadline());
        assertEq(proxy, predicted, "proxy at prediction");
        assertEq(adapterC.proxyOf(alice, MARKET_ID), proxy, "proxyOf");
        assertEq(adapterC.walletOf(proxy), alice, "walletOf");
        (address spoke, uint256 marketId, address vaultToken, uint256 reserveId) = adapterC.accountOf(proxy);
        assertEq(spoke, aave.cdpSpoke, "spoke");
        assertEq(marketId, MARKET_ID, "market");
        assertEq(vaultToken, vt, "vault token");
        assertEq(reserveId, vtReserveId, "reserve");
        assertEq(adapterC.predictProxy(alice, MARKET_ID), proxy, "predict after");
        assertEq(IPositionProxy(proxy).WALLET(), alice, "proxy wallet");
        assertEq(IPositionProxy(proxy).SPOKE(), aave.cdpSpoke, "proxy spoke");
        assertEq(IPositionProxy(proxy).MARKET_ID(), MARKET_ID, "proxy market");
        assertEq(IPositionProxy(proxy).ADAPTER(), adapter, "proxy adapter");
        assertTrue(token.isValidProxy(proxy), "registered proxy");
    }

    // TEST-010 verifies: REQ-ADAPTER-065, REQ-ADAPTER-068, REQ-PROXY-042, REQ-PROXY-043, REQ-PROXY-047, INV-001, INV-006, INV-008, INV-009, Q-224
    // Sources: 5.1 TEST-010, FLOW-001
    /// @notice A pledge mints exactly the credited units to the proxy, supplies them on the proxy's own account with
    /// an exact approval that ends at 0, enables the reserve as collateral, and records one open record.
    function test_TEST_010_pledgeMintsSuppliesAndEnables() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        address predicted = adapterC.predictProxy(alice, MARKET_ID);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralSupplied(predicted, MARKET_ID, UNITS, UNITS);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralAdded(alice, MARKET_ID, vt, predicted, 1, INTEGRATION, key, UNITS);
        vm.prank(alice);
        (address proxy, uint256 recordId, uint128 credited) = adapterC.pledge(MARKET_ID, _ref(key), _deadline());
        assertEq(recordId, coll.recordIdOf(INTEGRATION, key), "record id");
        assertEq(credited, UNITS, "credited");
        assertEq(token.totalSupply(), UNITS, "supply");
        assertEq(token.balanceOf(proxy), 0, "proxy keeps nothing");
        assertEq(token.balanceOf(aave.hub), UNITS, "hub holds the units");
        assertEq(token.allowance(proxy, aave.cdpSpoke), 0, "no allowance left");
        assertEq(_sharesOf(proxy, vtReserveId), UNITS, "supplied shares");
        (bool enabled, bool borrowing) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(vtReserveId, proxy);
        assertTrue(enabled, "enabled as collateral");
        assertFalse(borrowing, "no borrow");
        assertEq(coll.getTotalCredited(vt), UNITS, "credited total");
        assertEq(lpVault.ownerOf(key), address(lpVault), "custody");
        assertEq(lpVault.depositorOf(key), alice, "depositor");
        assertEq(token.balanceOf(adapter), 0, "adapter holds nothing");
    }

    // TEST-186 verifies: REQ-ADAPTER-005, REQ-ADAPTER-068, INV-066, Q-224
    // Sources: 5.1 TEST-186
    /// @notice The mint is exactly what Collateralization credited, even when the LPVault reports fewer units than
    /// the position's nominal liquidity.
    function test_TEST_186_mintEqualsCollateralizationCredit() public {
        lpVault.setReceiveOverride(7_777_777);
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        address predicted = adapterC.predictProxy(alice, MARKET_ID);
        vm.expectCall(vt, abi.encodeCall(IVaultToken.mint, (predicted, 7_777_777)), 1);
        vm.prank(alice);
        (,, uint128 credited) = adapterC.pledge(MARKET_ID, _ref(key), _deadline());
        assertEq(credited, 7_777_777, "credited");
        assertEq(token.totalSupply(), 7_777_777, "minted credited only");
        assertEq(_sharesOf(predicted, vtReserveId), 7_777_777, "supplied credited only");
    }

    // TEST-025 verifies: REQ-ADAPTER-066, REQ-PROXY-054
    /// @notice A top-up reuses the proxy: no second deployment, no second `UserProxyCreated`, no second
    /// `addValidProxy`, and the binding is unchanged.
    function test_TEST_025_topUpReusesProxy() public {
        (, address proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS / 2);
        vm.expectCall(vt, abi.encodeCall(IVaultToken.addValidProxy, (proxy)), 0);
        vm.expectCall(address(proxyManager), abi.encodeWithSelector(IProxyManager.deployProxy.selector), 0);
        vm.recordLogs();
        vm.prank(alice);
        (address again,,) = adapterC.pledge(MARKET_ID, _ref(key), _deadline());
        assertEq(again, proxy, "same proxy");
        assertEq(_sharesOf(proxy, vtReserveId), UNITS + UNITS / 2, "both supplied");
        assertEq(coll.getOpenRecordCount(proxy, vt), 2, "two records");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IAaveAdapterEvents.UserProxyCreated.selector, "no second creation");
        }
        assertEq(adapterC.walletOf(proxy), alice, "binding kept");
    }

    // TEST-271 verifies: REQ-ADAPTER-066, REQ-PROXY-018, REQ-PROXY-053, INV-064, Q-307
    // Sources: 5.1 TEST-271
    /// @notice One wallet in two markets of one Spoke has two proxies with separate accounts and health factors; a
    /// price move of one market changes only that account.
    function test_TEST_271_twoProxiesPerWallet() public {
        (, address pA) = _pledgeAs(alice, MARKET_ID, UNITS);
        (, address pB) = _pledgeAs(alice, MARKET_B, UNITS);
        assertTrue(pA != pB, "two proxies");
        assertEq(pB, proxyManager.predictProxy(alice, aave.cdpSpoke, MARKET_B), "B prediction");
        assertEq(adapterC.walletOf(pA), alice, "A wallet");
        assertEq(adapterC.walletOf(pB), alice, "B wallet");
        (,, address vA,) = adapterC.accountOf(pA);
        (,, address vB,) = adapterC.accountOf(pB);
        assertEq(vA, vt, "A token");
        assertEq(vB, vtB, "B token");
        assertTrue(token.isValidProxy(pA) && !token.isValidProxy(pB), "A registry");
        assertTrue(tokenB.isValidProxy(pB) && !tokenB.isValidProxy(pA), "B registry");
        _borrowAs(alice, MARKET_ID, debtReserveId, 5000e18);
        assertEq(_debtOf(pA, debtReserveId), 5000e18, "A debt");
        assertEq(_debtOf(pB, debtReserveId), 0, "B debt-free");
        assertEq(_borrowCountOf(pB), 0, "B borrow count");
        uint256 hfA = _hf(pA);
        _borrowAs(alice, MARKET_B, debtReserveId, 1000e18);
        assertEq(_hf(pA), hfA, "B borrow leaves A untouched");
        assertEq(adapterC.borrowNonce(pA), 1, "A nonce");
        assertEq(adapterC.borrowNonce(pB), 1, "B nonce");
    }

    // ─── Order of checks ───

    // TEST-010 verifies: REQ-ADAPTER-065, REQ-PROXY-058
    function test_TEST_010_deadlineExpired() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        uint256 d = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, d));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // TEST-010 verifies: REQ-ADAPTER-065, REQ-PROXY-058
    /// @notice A deadline equal to the block timestamp is still valid.
    function test_TEST_010_deadlineInclusive() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), block.timestamp);
        assertEq(token.totalSupply(), UNITS, "pledged");
    }

    // TEST-030 verifies: REQ-ADAPTER-065, REQ-PROXY-062, INV-017, Q-281
    /// @notice A market the registry does not know reverts `UnknownMarket`.
    function test_TEST_030_unknownMarket() public {
        bytes32 key = _newKey();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownMarket.selector, 77));
        vm.prank(alice);
        adapterC.pledge(77, _ref(key), _deadline());
    }

    // TEST-030 verifies: REQ-ADAPTER-065, REQ-ADAPTER-098, INV-017, ATTACK-106, Q-281
    /// @notice A registry record that maps the market to a token outside the VaultTokenFactory, to another market's
    /// token, to another Spoke or to another Hub is refused before any proxy or custody call.
    function test_TEST_030_registryRemapRefused() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        // A token the factory never deployed.
        registry.setMarketVaultToken(MARKET_ID, address(usdc));
        _expectUnknown(key);
        // Another market's token.
        registry.setMarketVaultToken(MARKET_ID, vtB);
        _expectUnknown(key);
        registry.setMarketVaultToken(MARKET_ID, vt);
        // Another Spoke.
        registry.setMarketSpoke(MARKET_ID, aave.lendSpoke);
        _expectUnknown(key);
        registry.setMarketSpoke(MARKET_ID, aave.cdpSpoke);
        // Another Hub.
        registry.setMarketHub(MARKET_ID, makeAddr("otherHub"));
        _expectUnknown(key);
        registry.setMarketHub(MARKET_ID, aave.hub);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), _deadline());
        assertEq(token.totalSupply(), UNITS, "restored record pledges");
    }

    function _expectUnknown(
        bytes32 key
    ) internal {
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownMarket.selector, MARKET_ID));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // TEST-012 verifies: REQ-ADAPTER-073, REQ-ADAPTER-083, REQ-ADAPTER-046
    /// @notice `Paused(MintPathSuspect)` refuses a pledge of a new account and a top-up alike.
    function test_TEST_012_mintPathSuspectRefusesEveryPledge() public {
        (, address proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
        bytes32 key2 = _newKey();
        lpVault.mintPosition(key2, bob, MARKET_ID, UNITS);
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(key2), d);
        assertEq(_sharesOf(proxy, vtReserveId), UNITS, "nothing added");
    }

    // TEST-012 verifies: REQ-ADAPTER-077, REQ-ADAPTER-065
    function test_TEST_012_unapprovedSpoke() public {
        registry.setSpoke(
            aave.cdpSpoke, SpokeDef(false, aave.hub, INTEGRATION, RiskTier.Stable, address(0), address(0))
        );
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownSpoke.selector, aave.cdpSpoke));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // TEST-012 verifies: REQ-ADAPTER-065, REQ-PROXY-062
    /// @notice A position named for another AMM integration is refused, so a wallet signing for one AMM protocol never
    /// pledges into a market of another.
    function test_TEST_012_integrationMismatch() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.IntegrationMismatch.selector, MARKET_ID, 9));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, PositionRef(9, key), d);
    }

    // TEST-012 verifies: REQ-ADAPTER-065
    /// @notice When several checks fail the first in the order of REQ-ADAPTER-065 wins: deadline, market, pause
    /// reason, Spoke, integration.
    function test_TEST_012_checkOrder() public {
        bytes32 key = _newKey();
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        registry.setSpoke(
            aave.cdpSpoke, SpokeDef(false, aave.hub, INTEGRATION, RiskTier.Stable, address(0), address(0))
        );
        uint256 past = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, past));
        vm.prank(alice);
        adapterC.pledge(77, PositionRef(9, key), past);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownMarket.selector, 77));
        vm.prank(alice);
        adapterC.pledge(77, PositionRef(9, key), d);
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, PositionRef(9, key), d);
        _pause(PauseState.None, PauseReason.None);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownSpoke.selector, aave.cdpSpoke));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, PositionRef(9, key), d);
    }

    // ─── Pause state and freeze ───

    // TEST-012 verifies: REQ-ADAPTER-045, REQ-ADAPTER-072, REQ-ADAPTER-065, INV-026
    /// @notice Under Frozen a new account's pledge reverts `ApplicationFrozen` (the proxy it deployed is undone with
    /// it) while an indebted account's top-up passes.
    function test_TEST_012_frozenRefusesNewAccountOnly() public {
        (, address proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        (, address carolProxy) = _pledgeAs(carol, MARKET_B, UNITS);
        _pause(PauseState.Frozen, PauseReason.None);
        bytes32 key = _newKey();
        lpVault.mintPosition(key, bob, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.ApplicationFrozen.selector);
        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(key), d);
        assertEq(adapterC.proxyOf(bob, MARKET_ID), address(0), "no binding left");
        // A debt-free existing account is a new account for this rule.
        bytes32 keyC = _newKey();
        lpVault.mintPosition(keyC, carol, MARKET_B, UNITS);
        vm.expectRevert(IAaveAdapterErrors.ApplicationFrozen.selector);
        vm.prank(carol);
        adapterC.pledge(MARKET_B, _ref(keyC), d);
        assertTrue(carolProxy != address(0), "carol proxy");
        // The indebted account tops up.
        bytes32 key2 = _newKey();
        lpVault.mintPosition(key2, alice, MARKET_ID, UNITS);
        vm.expectCall(address(coll), abi.encodeCall(ICollateralizationAdapter.pledge, (alice, proxy, vt, key2, false)));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key2), d);
        assertEq(_sharesOf(proxy, vtReserveId), 2 * UNITS, "top-up supplied");
    }

    // TEST-235 verifies: REQ-ADAPTER-083, REQ-ADAPTER-088, REQ-ADAPTER-046, REQ-RISK-066, REQ-RISK-047
    /// @notice Under `Paused(General)` every pledge asks Collateralization (and so the RiskModule) for a rescue top-up.
    function test_TEST_235_pausedGeneralRequiresRescue() public {
        (, address proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        _pause(PauseState.Paused, PauseReason.General);
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        vm.expectCall(address(coll), abi.encodeCall(ICollateralizationAdapter.pledge, (alice, proxy, vt, key, true)));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), _deadline());
        // The RiskModule refusing the rescue reverts the whole pledge, custody included.
        riskModule.setRefuse(true);
        bytes32 key2 = _newKey();
        lpVault.mintPosition(key2, alice, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert();
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key2), d);
        assertEq(lpVault.ownerOf(key2), alice, "custody undone");
    }

    // TEST-229 verifies: REQ-ADAPTER-082, REQ-ADAPTER-083, REQ-PROXY-099, INV-024
    /// @notice A frozen wallet with an account can only add a rescue top-up; a frozen wallet without one cannot open
    /// an account (the ProxyManager refuses its proxy).
    function test_TEST_229_frozenWalletRescueOnly() public {
        (, address proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        registry.setFrozen(alice, true);
        registry.setFrozen(bob, true);
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        vm.expectCall(address(coll), abi.encodeCall(ICollateralizationAdapter.pledge, (alice, proxy, vt, key, true)));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), _deadline());
        bytes32 keyB = _newKey();
        lpVault.mintPosition(keyB, bob, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IProxyManager.AddressIsFrozen.selector, bob));
        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(keyB), d);
    }

    // TEST-012 verifies: REQ-ADAPTER-044, REQ-ADAPTER-083
    /// @notice With no pause and no freeze the rescue flag is false.
    function test_TEST_012_noneAsksNoRescue() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        address predicted = adapterC.predictProxy(alice, MARKET_ID);
        vm.expectCall(
            address(coll), abi.encodeCall(ICollateralizationAdapter.pledge, (alice, predicted, vt, key, false))
        );
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), _deadline());
    }

    // TEST-012 verifies: REQ-ADAPTER-044, REQ-ADAPTER-098
    /// @notice A pause of another Hub leaves this market's pledges open.
    function test_TEST_012_otherHubPauseIgnored() public {
        registry.setPause(makeAddr("otherHub"), PauseState.Paused, PauseReason.MintPathSuspect);
        _pledgeAs(alice, MARKET_ID, UNITS);
        assertEq(token.totalSupply(), UNITS, "pledged");
    }

    // ─── Empty account at creation (REQ-ADAPTER-103) ───

    // TEST-190 verifies: REQ-ADAPTER-103, REQ-PROXY-055, INV-008, ATTACK-029
    // Sources: decided item 2026-11-11 (first pledge requires an empty account)
    /// @notice A predicted address that already has a reserve enabled as collateral on its Spoke account makes the
    /// creating pledge revert `AccountNotEmpty`, leaving no binding.
    function test_TEST_190_inheritedCollateralRefused() public {
        address predicted = adapterC.predictProxy(alice, MARKET_ID);
        IAaveV4Spoke.UserAccountData memory data;
        data.activeCollateralCount = 1;
        data.healthFactor = type(uint256).max;
        vm.mockCall(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getUserAccountData, (predicted)), abi.encode(data));
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.AccountNotEmpty.selector, predicted));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
        assertEq(adapterC.proxyOf(alice, MARKET_ID), address(0), "no binding");
        assertEq(lpVault.ownerOf(key), alice, "no custody");
    }

    // TEST-190 verifies: REQ-ADAPTER-103, REQ-PROXY-055
    /// @notice Inherited debt (a borrow count above 0, as the Spoke would report it) is refused the same way.
    function test_TEST_190_inheritedDebtRefused() public {
        address predicted = adapterC.predictProxy(alice, MARKET_ID);
        IAaveV4Spoke.UserAccountData memory data;
        data.borrowCount = 1;
        data.healthFactor = type(uint256).max;
        vm.mockCall(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getUserAccountData, (predicted)), abi.encode(data));
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.AccountNotEmpty.selector, predicted));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // TEST-190 verifies: REQ-ADAPTER-103, REQ-PROXY-055, INV-008
    /// @notice Inherited supplied shares of the market's own reserve are refused even with collateral disabled.
    function test_TEST_190_inheritedSharesRefused() public {
        address predicted = adapterC.predictProxy(alice, MARKET_ID);
        vm.mockCall(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.getUserSuppliedShares, (vtReserveId, predicted)),
            abi.encode(uint256(1))
        );
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.AccountNotEmpty.selector, predicted));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // TEST-190 verifies: REQ-ADAPTER-103
    /// @notice The check runs only at creation: an account that later borrows still takes top-ups.
    function test_TEST_190_checkOnlyAtCreation() public {
        (, address proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        (, address again) = _pledgeAs(alice, MARKET_ID, UNITS);
        assertEq(again, proxy, "same proxy");
        assertEq(_sharesOf(proxy, vtReserveId), 2 * UNITS, "topped up");
    }

    // ─── Backing gap and zero credit ───

    // TEST-241 verifies: REQ-ADAPTER-069, REQ-ADAPTER-075, SPEC-PROXY-008, INV-080, REQ-VAULT-111
    /// @notice A Collateralization answer that credits nothing it recorded (a faulty or hostile credit) makes the
    /// mint unbacked, and the pledge reverts `BackingMismatch`.
    function test_TEST_241_unbackedMintReverts() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        vm.mockCall(
            address(coll),
            abi.encodeWithSelector(ICollateralizationAdapter.pledge.selector),
            abi.encode(uint256(1), uint128(UNITS))
        );
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.BackingMismatch.selector, UNITS, 0, 0));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // TEST-186 verifies: REQ-ADAPTER-005, REQ-PROXY-041, REQ-PROXY-084, REQ-PROXY-093
    /// @notice A credit of 0 never reaches a mint or a supply: the pledge reverts `ZeroAmount`.
    function test_TEST_186_zeroCreditRefused() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        vm.mockCall(
            address(coll),
            abi.encodeWithSelector(ICollateralizationAdapter.pledge.selector),
            abi.encode(uint256(1), uint128(0))
        );
        vm.expectCall(vt, abi.encodeWithSelector(IVaultToken.mint.selector), 0);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.ZeroAmount.selector);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // TEST-010 verifies: REQ-ADAPTER-065, ATTACK-001, ATTACK-003
    /// @notice Pledging another wallet's position, or the same position twice, fails in Collateralization and the
    /// LPVault; nothing is minted.
    function test_TEST_010_ownershipAndDuplicates() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, bob, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert();
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
        assertEq(token.totalSupply(), 0, "nothing minted");
        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(key), d);
        vm.expectRevert();
        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(key), d);
        assertEq(token.totalSupply(), UNITS, "one credit");
    }

    // TEST-269 verifies: REQ-ADAPTER-051, INV-096
    /// @notice A 17th open record of one account-market is refused by Collateralization.
    function test_TEST_269_seventeenthRecordRefused() public {
        for (uint256 i = 0; i < 16; ++i) {
            _pledgeAs(alice, MARKET_ID, 1_000_000_000);
        }
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, 1_000_000_000);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.TooManyRecords.selector, 16));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // TEST-060 verifies: REQ-PROXY-048, REQ-PROXY-076, REQ-LOCK-007
    /// @notice A pledge started while the Lock is held reverts with the Lock's `LockHeld`.
    function test_TEST_060_pledgeUnderHeldLock() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        bytes memory data = abi.encodeCall(adapterC.pledge, (MARKET_ID, _ref(key), _deadline()));
        bytes memory err = swap.callUnderLock(adapter, data);
        assertEq(err, abi.encodeWithSelector(ILock.LockHeld.selector, address(swap)), "LockHeld");
        assertFalse(lock.isLocked(), "lock released");
    }

    // TEST-010 verifies: REQ-ADAPTER-065, REQ-PROXY-048, REQ-LOCK-007
    /// @notice A pledge leaves the Lock free.
    function test_TEST_010_lockFreeAfterPledge() public {
        _pledgeAs(alice, MARKET_ID, UNITS);
        assertFalse(lock.isLocked(), "lock free");
        assertEq(lock.holder(), address(0), "no holder");
    }
}
