// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {AaveAdapterHandler, AdapterWorld} from "./handlers/AaveAdapterHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title AaveAdapterInvariantTest
/// @notice AaveAdapter invariants on the real local Aave V4, Collateralization, vault tokens, ProxyManager and
/// PositionProxies under random sequences of pledges, borrows, repays (own and third-party), withdrawals, partial
/// removals, re-credits, repays with collateral, fee collection, price moves, pause-state and freeze changes, honest
/// liquidations and time. After every call: vault-token supply equals the units the Adapter minted minus those burned
/// and equals Collateralization's credited plus pending units, each call moving both by the same amount; each proxy's
/// stored nonce equals its completed borrows; repay, debt-free withdrawal and fee collection never failed; every
/// completed borrow forwarded exactly its amount to an allowed receiver within the Spoke's draw cap; each wallet has at
/// most one proxy per market, at the ProxyManager's prediction, with its binding and code unchanged.
/// @dev Each handler call is one transaction.
/// forge-config: default.isolate = false
contract AaveAdapterInvariantTest is AaveAdapterFixture, HandlerReach {
    AaveAdapterHandler internal handler;

    function setUp() public override {
        super.setUp();
        AdapterWorld memory world = AdapterWorld({
            adapter: adapterC,
            coll: coll,
            proxyManager: proxyManager,
            registry: registry,
            swap: swap,
            lpVault: lpVault,
            spoke: IAaveV4Spoke(aave.cdpSpoke),
            hub: aave.hub,
            tokenA: token,
            tokenB: tokenB,
            marketA: MARKET_ID,
            marketB: MARKET_B,
            reserveA: vtReserveId,
            reserveB: vtReserveIdB,
            gho: debt,
            usdc: usdcDebt,
            ghoReserve: debtReserveId,
            usdcReserve: usdcReserveId,
            ghoAssetId: ghoAssetId,
            usdcAssetId: usdcAssetId,
            vtPrice: vtPrice,
            integrationId: INTEGRATION
        });
        handler = new AaveAdapterHandler(world, [alice, bob, carol], makeAddr("thirdPartyPayer"));
        handler.seedAccounts();
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
    }

    /// @dev The fuzzed actions (`pledge` twice, so positions accumulate; `seedAccounts` is set-up only).
    function _actions() internal pure returns (bytes4[] memory actions) {
        actions = new bytes4[](13);
        actions[0] = AaveAdapterHandler.pledge.selector;
        actions[1] = AaveAdapterHandler.borrow.selector;
        actions[2] = AaveAdapterHandler.repay.selector;
        actions[3] = AaveAdapterHandler.withdraw.selector;
        actions[4] = AaveAdapterHandler.removeLiquidity.selector;
        actions[5] = AaveAdapterHandler.recredit.selector;
        actions[6] = AaveAdapterHandler.repayWithCollateral.selector;
        actions[7] = AaveAdapterHandler.collectFees.selector;
        actions[8] = AaveAdapterHandler.setPrice.selector;
        actions[9] = AaveAdapterHandler.setPause.selector;
        actions[10] = AaveAdapterHandler.liquidate.selector;
        actions[11] = AaveAdapterHandler.warp.selector;
        actions[12] = AaveAdapterHandler.pledge.selector;
    }

    // TEST-082 verifies: TEST-007
    /// @notice The handler does real work: over 32 fixed-seed runs of 50 calls from this suite's set-up state, each
    /// action succeeds in at least its floor share of calls (borrow 15 %: half its modes are refused by design and the
    /// Hub is stopped half the time; the others 25 %), and a liquidation, a repay with collateral and a debt-free
    /// withdrawal are each reached in at least 75 % of the runs.
    function test_TEST_082_handlerReach() public {
        string[] memory names = new string[](13);
        (names[0], names[1], names[2], names[3], names[4]) =
        ("pledge", "borrow", "repay", "withdraw", "removeLiquidity");
        (names[5], names[6], names[7], names[8], names[9]) =
        ("recredit", "repayWithCollateral", "collectFees", "setPrice", "setPause");
        (names[10], names[11], names[12]) = ("liquidate", "warp", "pledge (2)");
        string[] memory targets = new string[](3);
        (targets[0], targets[1], targets[2]) = ("liquidation", "repay with collateral", "withdrawal");
        uint256[] memory minOk = _floors(13, 25);
        minOk[1] = 15;
        Reach memory r = _replay(address(handler), _actions(), AaveAdapterHandler.Skipped.selector, 32, 50, 3);
        _check(r, names, targets, minOk, _floors(3, 75));
    }

    function _reached() internal view override returns (bool[] memory hit) {
        hit = new bool[](3);
        hit[0] = handler.liquidations() != 0;
        hit[1] = handler.deleverages() != 0;
        hit[2] = handler.withdrawals() != 0;
    }

    // TEST-088 verifies: REQ-ADAPTER-005, REQ-ADAPTER-068, REQ-ADAPTER-069, REQ-ADAPTER-070, INV-009, INV-010, INV-066
    // Sources: 5.1 TEST-088, QNT-03, QNT-13, HYP-24
    /// @notice Supply is exactly what the Adapter minted (credited and added units) minus what it burned (withdrawn,
    /// removed, released to LPVaultSwap and seized), and every call moved supply and Collateralization's backing by
    /// the same amount.
    function invariant_TEST_088_mintBurnAuthority() public view {
        assertEq(
            token.totalSupply() + tokenB.totalSupply(), handler.minted() - handler.burned(), "supply = mints - burns"
        );
        assertEq(handler.backingViolations(), 0, "a call moved supply and backing apart");
    }

    // TEST-083 verifies: INV-001, INV-080, SPEC-PROXY-008
    /// @notice With no orphan burn in the model the backing gap stays 0 in both markets.
    function invariant_TEST_083_backingGapZero() public view {
        assertEq(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "market A backed");
        assertEq(tokenB.totalSupply(), coll.getTotalCredited(vtB) + coll.getPending(vtB).units, "market B backed");
    }

    // TEST-096 verifies: REQ-PROXY-015, REQ-PROXY-059, INV-019, ATTACK-036
    // Sources: QNT-21, HYP-15
    /// @notice Each proxy's stored nonce equals its completed borrows: no nonce value admitted two borrows and none
    /// moved without one.
    function invariant_TEST_096_nonceSingleUse() public view {
        uint256 n = handler.proxyCount();
        for (uint256 i = 0; i < n; ++i) {
            address p = handler.proxies(i);
            assertEq(adapterC.borrowNonce(p), handler.borrowsCompleted(p), "nonce = completed borrows");
        }
    }

    // TEST-099 verifies: REQ-PROXY-032, REQ-PROXY-035, REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-ADAPTER-096, INV-043, INV-044, INV-045, INV-067
    // Sources: QNT-14, QNT-15, QNT-16, QNT-17, HYP-16, HYP-18
    /// @notice Repay (by the borrower or a third party, partial or all), debt-free withdrawal and fee collection never
    /// failed in any pause state or freeze, and a repay-all always left the reserve at zero.
    function invariant_TEST_099_exitLiveness() public view {
        assertEq(handler.livenessViolations(), 0, "an exit failed");
        assertEq(handler.exitsAttempted(), handler.exitsSucceeded(), "attempted = succeeded");
    }

    // TEST-106 verifies: REQ-PROXY-017, REQ-PROXY-021, REQ-PROXY-023, SPEC-PROXY-004, INV-020
    /// @notice Every completed borrow forwarded exactly its amount from the proxy to the receiver, left the proxy's
    /// balance where it was, used the current nonce, and no borrow to a refused receiver (a registered proxy) completed.
    function invariant_TEST_106_borrowPath() public view {
        assertEq(handler.borrowViolations(), 0, "borrow forwarding");
        assertEq(handler.refusedReceiverAccepted(), 0, "refused receiver accepted");
    }

    // TEST-211 verifies: REQ-ADAPTER-066, REQ-PROXY-049, REQ-PROXY-053, INV-063, INV-064
    // Sources: QNT-08
    /// @notice Each wallet has at most one proxy per market, at the ProxyManager's prediction, bound to that wallet and
    /// market's vault token, with the binding and the code unchanged since creation.
    function invariant_TEST_211_bindingsFixed() public view {
        uint256[2] memory markets = [MARKET_ID, MARKET_B];
        address[2] memory tokens = [vt, vtB];
        for (uint256 i = 0; i < 3; ++i) {
            address wallet = handler.walletAt(i);
            for (uint256 m = 0; m < 2; ++m) {
                address p = adapterC.proxyOf(wallet, markets[m]);
                assertEq(p, handler.firstProxy(wallet, markets[m]), "binding unchanged");
                if (p == address(0)) continue;
                assertEq(p, proxyManager.predictProxy(wallet, aave.cdpSpoke, markets[m]), "at the prediction");
                assertEq(adapterC.walletOf(p), wallet, "wallet");
                (address spoke, uint256 marketId, address vaultToken,) = adapterC.accountOf(p);
                assertEq(spoke, aave.cdpSpoke, "spoke");
                assertEq(marketId, markets[m], "market");
                assertEq(vaultToken, tokens[m], "vault token");
                assertEq(p.codehash, handler.proxyCodeHash(p), "code unchanged");
            }
        }
    }

    // TEST-089 verifies: REQ-PROXY-051, REQ-PROXY-053, REQ-PROXY-099, REQ-VTOKEN-007, REQ-VTOKEN-039, INV-012, INV-064
    // Sources: QNT-08, HYP-02
    /// @notice Proxy binding and registry under the random campaign: a vault token lists exactly the proxies the
    /// Adapter created for its own market (each at the ProxyManager's prediction, with `WALLET()`, `SPOKE()`,
    /// `MARKET_ID()` and code fixed), never a proxy of the other market, a wallet, the Adapter or LPVaultSwap; a
    /// registration never turns false; a proxy holds Spoke supply only once registered; and every open record's proxy
    /// is `proxyOf(depositor, marketId)` of the record's own market.
    function invariant_TEST_089_proxyBindingAndRegistry() public view {
        uint256[2] memory markets = [MARKET_ID, MARKET_B];
        VaultToken[2] memory tokens = [token, tokenB];
        uint256[2] memory reserves = [vtReserveId, vtReserveIdB];
        for (uint256 i = 0; i < 3; ++i) {
            address wallet = handler.walletAt(i);
            for (uint256 m = 0; m < 2; ++m) {
                VaultToken own = tokens[m];
                VaultToken other = tokens[1 - m];
                address predicted = proxyManager.predictProxy(wallet, aave.cdpSpoke, markets[m]);
                address p = adapterC.proxyOf(wallet, markets[m]);
                assertFalse(own.isValidProxy(wallet), "wallet never registered");
                if (p == address(0)) {
                    assertFalse(own.isValidProxy(predicted), "no registration without a proxy");
                    assertEq(handler.openKeysOf(wallet, markets[m]).length, 0, "no record without a proxy");
                    continue;
                }
                assertEq(p, predicted, "at the prediction");
                assertTrue(own.isValidProxy(p), "registered in its market's token, never removed");
                assertFalse(other.isValidProxy(p), "never in the other market's token");
                assertEq(IPositionProxy(p).WALLET(), wallet, "proxy wallet");
                assertEq(IPositionProxy(p).SPOKE(), aave.cdpSpoke, "proxy spoke");
                assertEq(IPositionProxy(p).MARKET_ID(), markets[m], "proxy market");
                assertEq(p.codehash, handler.proxyCodeHash(p), "code unchanged");
                if (IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(reserves[m], p) > 0) {
                    assertTrue(own.isValidProxy(p), "supply only after registration");
                }
                bytes32[] memory keys = handler.openKeysOf(wallet, markets[m]);
                for (uint256 k = 0; k < keys.length; ++k) {
                    uint256 id = coll.recordIdOf(INTEGRATION, keys[k]);
                    if (id == 0) continue; // closed by a full seizure
                    BackingRecord memory r = coll.getRecord(id);
                    assertEq(r.depositor, wallet, "record depositor");
                    assertEq(uint256(r.marketId), markets[m], "record market");
                    assertEq(r.proxy, adapterC.proxyOf(r.depositor, r.marketId), "record proxy is proxyOf");
                }
            }
        }
        for (uint256 m = 0; m < 2; ++m) {
            assertFalse(tokens[m].isValidProxy(adapter), "adapter never registered");
            assertFalse(tokens[m].isValidProxy(lpVaultSwap), "LPVaultSwap never registered");
        }
    }

    // TEST-274 verifies: INV-057
    // Sources: TOPO-04
    /// @notice No borrow completed that left the CDP Spoke's owed amount of the borrowed asset above its draw cap.
    function invariant_TEST_274_drawCapRespected() public view {
        assertEq(handler.drawCapViolations(), 0, "draw cap exceeded by a borrow");
    }

    /// @notice Nothing stays in the Adapter.
    // TEST-099 verifies: REQ-ADAPTER-007
    function invariant_TEST_099_adapterHoldsNothing() public view {
        assertEq(token.balanceOf(adapter) + tokenB.balanceOf(adapter), 0, "vault tokens");
        assertEq(debt.balanceOf(adapter) + usdcDebt.balanceOf(adapter), 0, "debt assets");
        assertFalse(lock.isLocked(), "lock free between transactions");
    }

    // TEST-099 verifies: REQ-PROXY-032, REQ-PROXY-035, REQ-ADAPTER-080, REQ-ADAPTER-070
    /// @notice Every handler action reaches its Adapter entry point and completes in a plain sequence (so the random
    /// campaign exercises real calls, not only early returns): pledge, borrow, third-party repay, partial removal,
    /// re-credit, repay with collateral, fee collection, a liquidation after a price fall, and a debt-free withdrawal.
    function test_TEST_099_handlerActionsComplete() public {
        // Counts from here on; the set-up seeded 6 pledges and 3 borrows.
        uint256[7] memory base = [
            handler.pledges(),
            handler.borrows(),
            handler.removals(),
            handler.recredits(),
            handler.deleverages(),
            handler.liquidations(),
            handler.withdrawals()
        ];
        handler.pledge(0, 0, 4_000_000_000);
        handler.pledge(0, 0, 3_000_000_000);
        handler.borrow(0, 0, 0, 2500, 0);
        handler.borrow(0, 0, 1, 500, 1);
        handler.repay(0, 0, 0, 100e18, 2);
        handler.removeLiquidity(0, 0, 0, 10_000_000);
        handler.recredit(0, 0, 0, 5_000_000);
        handler.repayWithCollateral(0, 0, 1, 100_000_000);
        handler.collectFees(0, 0, 0, 1000);
        handler.borrow(0, 0, 0, 3000, 0);
        handler.borrow(0, 0, 0, 3000, 0);
        handler.setPrice(0);
        handler.liquidate(0, 0, 2000e18);
        handler.pledge(1, 1, 1_000_000_000);
        handler.withdraw(1, 1, 0);
        assertEq(handler.pledges() - base[0], 3, "pledges");
        assertEq(handler.borrows() - base[1], 4, "borrows");
        assertEq(handler.removals() - base[2], 1, "removal");
        assertEq(handler.recredits() - base[3], 1, "recredit");
        assertEq(handler.deleverages() - base[4], 1, "repay with collateral");
        assertEq(handler.liquidations() - base[5], 1, "liquidation");
        assertEq(handler.withdrawals() - base[6], 1, "debt-free withdrawal");
        assertEq(handler.exitsAttempted(), handler.exitsSucceeded(), "exits");
        invariant_TEST_088_mintBurnAuthority();
        invariant_TEST_083_backingGapZero();
        invariant_TEST_096_nonceSingleUse();
        invariant_TEST_106_borrowPath();
        invariant_TEST_211_bindingsFixed();
        invariant_TEST_089_proxyBindingAndRegistry();
    }
}
