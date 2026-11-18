// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../src/oracle/ILPOracle.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IRiskModule} from "../../src/policy/risk-module/IRiskModule.sol";
import {Market} from "../../src/types/MarketTypes.sol";
import {FullStackMarkets} from "../utils/fixtures/FullStackMarkets.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FullStackMarketRegistryIntegrationTest
/// @notice The MarketRegistry's reads in the borrower flows, on the full real stack (`FullStackMarkets`): the real
/// MarketRegistry, ParameterStore, RiskModule, AaveAdapter, Collateralization, AvanaTimelock, the markets' real
/// LPOracles and the USDC DebtOracle on the real local Aave V4. A faulty registry is the real one with one view
/// answered by `vm.mockCall`.
/// @dev Markets A (pool 0.01 %) and B (pool 0.05 %), both USDC/USDT at $2.00 per vault token. Alice holds GHO and USDC
/// debt in market A; Bob is debt-free in market A.
/// forge-config: default.isolate = false
contract FullStackMarketRegistryIntegrationTest is FullStackMarkets {
    uint256 internal mA;
    uint256 internal mB;
    address internal pA;
    address internal pB;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        mB = _addMarket(poolB);
        (, pA) = _pledgeAs(alice, mA, UNITS);
        _borrowAs(alice, mA, ghoReserveId, 2000e18);
        _borrowAs(alice, mA, usdcReserveId, 500e6);
        _pledgeAs(alice, mA, UNITS / 4);
        (, pB) = _pledgeAs(bob, mA, UNITS);
    }

    // ─── Market identity (TEST-171, TEST-030) ───

    /// @dev Bob tops up market A with the MarketRegistry answering `marketOfVaultToken(vtA)` with `answer`.
    function _pledgeUnderAWrongMarketId(
        uint256 answer
    ) internal {
        address vtA = mkt[mA].vaultToken;
        vm.mockCall(address(registry), abi.encodeCall(IMarketRegistry.marketOfVaultToken, (vtA)), abi.encode(answer));
        bytes32 key = _newKey();
        lpVault.mintPosition(key, bob, mA, UNITS / 4);
        uint256 supplyBefore = ERC20(vtA).totalSupply();
        vm.expectCall(
            address(riskModule),
            bytes.concat(IRiskModule.checkPledge.selector, abi.encode(bob, pB, mA, V3, key, UNITS / 4))
        );
        vm.prank(bob);
        (address proxy, uint256 recordId, uint128 credited) = adapterC.pledge(mA, _ref(key), _deadline());
        assertEq(proxy, pB, "the market A proxy");
        assertEq(coll.getRecord(recordId).marketId, mA, "record in the vault token's market");
        assertEq(ERC20(vtA).totalSupply(), supplyBefore + credited, "market A units minted");
        assertEq(ERC20(mkt[mB].vaultToken).totalSupply(), 0, "nothing in market B");
    }

    /// @notice With the MarketRegistry answering `marketOfVaultToken` with another market's ID, a pledge still pokes
    /// the vault token's own LPOracle and never the other market's, passes the vault token's own market ID to
    /// `RiskModule.checkPledge`, and books and mints in market A; a position bound to market A pledged under market B
    /// is refused.
    // TEST-171 verifies: REQ-COLL-002, REQ-COLL-003, REQ-VAULT-014, INV-017, ATTACK-005, ATTACK-033, Q-126, Q-224, Q-240
    function test_TEST_171_pledgeIgnoresAnotherMarketsId() public {
        _pledgeUnderAWrongMarketId(mB);
        bytes32 wrong = _newKey();
        lpVault.mintPosition(wrong, bob, mA, UNITS / 4);
        vm.prank(bob);
        vm.expectRevert();
        adapterC.pledge(mB, _ref(wrong), _deadline());
    }

    /// @notice The same with the MarketRegistry answering that the vault token has no market.
    // TEST-171 verifies: REQ-COLL-002, REQ-VAULT-014, Q-126, Q-240
    function test_TEST_171_pledgeIgnoresAMissingMarketId() public {
        _pledgeUnderAWrongMarketId(0);
    }

    /// @notice The Adapter's mint and supply targets do not follow the MarketRegistry: the vault-token reserve is the
    /// one the Spoke derives from the Hub asset; with `getMarket` reporting a stale reserve ID, or naming an attacker
    /// Spoke, a pledge reverts and nothing is minted, supplied or taken into custody; a reserve the registry calls a
    /// debt reserve but the Spoke does not lend is never borrowed.
    // TEST-030 verifies: REQ-ADAPTER-065, REQ-ADAPTER-067, REQ-PROXY-062, INV-017, INV-073, Q-281
    function test_TEST_030_targetsDerivedAtCallTime() public {
        Market memory m = registry.getMarket(mA);
        uint256 assetId = IAaveV4Hub(aave.hub).getAssetId(m.vaultToken);
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getReserveId(aave.hub, assetId), mkt[mA].reserveId, "derived reserve");
        Market memory stale = m;
        stale.reserveId = mkt[mB].reserveId;
        Market memory hostile = m;
        hostile.spoke = makeAddr("attackerSpoke");
        Market[2] memory lies = [stale, hostile];
        for (uint256 i = 0; i < 2; ++i) {
            vm.mockCall(address(registry), abi.encodeCall(IMarketRegistry.getMarket, (mA)), abi.encode(lies[i]));
            bytes32 key = _newKey();
            lpVault.mintPosition(key, bob, mA, UNITS / 4);
            uint256 supply = ERC20(m.vaultToken).totalSupply();
            uint256 sharesA = _sharesOf(pB, mkt[mA].reserveId);
            vm.prank(bob);
            vm.expectRevert();
            adapterC.pledge(mA, _ref(key), _deadline());
            assertEq(ERC20(m.vaultToken).totalSupply(), supply, "no mint");
            assertEq(_sharesOf(pB, mkt[mA].reserveId), sharesA, "no supply");
            assertEq(_sharesOf(pB, mkt[mB].reserveId), 0, "nothing on the stale reserve");
            assertEq(lpVault.ownerOf(key), bob, "position not taken");
            vm.clearMockedCalls();
        }
        (bytes32 k2,) = _pledgeAs(bob, mA, UNITS / 4);
        assertEq(lpVault.depositorOf(k2), bob, "with the true record the pledge goes through");
        // The vault-token reserve of market B listed as a debt reserve by the registry: the Spoke does not lend it.
        DebtReserveDef memory lie = registry.getDebtReserve(aave.cdpSpoke, ghoReserveId);
        lie.reserveId = mkt[mB].reserveId;
        vm.mockCall(
            address(registry),
            abi.encodeCall(IMarketRegistry.getDebtReserve, (aave.cdpSpoke, mkt[mB].reserveId)),
            abi.encode(lie)
        );
        uint256 n = adapterC.borrowNonce(pA);
        vm.prank(alice);
        vm.expectRevert();
        adapterC.borrow(mA, mkt[mB].reserveId, 1, alice, _deadline(), 0, n);
        assertEq(_debtOf(pA, mkt[mB].reserveId), 0, "no borrow of a reserve outside the Spoke's set");
    }
}
