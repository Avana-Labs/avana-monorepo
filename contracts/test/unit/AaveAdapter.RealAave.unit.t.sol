// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveV4SpokePositionManagers} from "../../src/interfaces/external/aave/IAaveV4SpokePositionManagers.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    CollPriceSource,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @dev SpokeConfigurator calls of aave-v4 a3ef63e that the tests use.
interface IRealAaveConfigurator {
    function addCollateralFactor(
        address spoke,
        uint256 reserveId,
        uint16 collateralFactor
    ) external returns (uint32);
    function updatePaused(
        address spoke,
        uint256 reserveId,
        bool paused
    ) external;
    function updateReservePriceSource(
        address spoke,
        uint256 reserveId,
        address priceSource
    ) external;
}

/// @dev Spoke views of aave-v4 a3ef63e that the in-house interfaces do not carry.
interface IRealAaveSpokeViews {
    function isPositionManager(
        address user,
        address positionManager
    ) external view returns (bool);
}

/// @notice An ERC-2612 token, as a debt asset with `permit` (GHO, USDC) is.
contract RealAavePermitToken is ERC20Permit {
    constructor() ERC20("Permit", "PRM") ERC20Permit("Permit") {}
}

/// @title AaveAdapterRealAaveUnitTest
/// @notice Adapter behaviour that depends on the pinned Aave V4 Spoke itself: two accounts of one wallet with
/// independent health factors, Aave's `borrowCount` as the only debt-free test, dynamic configuration keys refreshed
/// by Aave inside the Adapter's own Spoke calls, the Spoke's per-account reserve limit, signature and permit routes that
/// never name a proxy, exits of a two-reserve account with a reverting MarketRegistry and RiskModule, and Aave's own
/// reserve pause blocking exits from Aave's side only.
/// forge-config: default.isolate = false
contract AaveAdapterRealAaveUnitTest is AaveAdapterFixture {
    IRealAaveConfigurator internal cfg;
    CollPriceSource internal priceB;

    function setUp() public override {
        super.setUp();
        cfg = IRealAaveConfigurator(aave.spokeConfigurator);
        // Market B gets its own price source, so a price move of one market leaves the other alone.
        priceB = new CollPriceSource(2e8);
        vm.prank(aaveDao);
        cfg.updateReservePriceSource(aave.cdpSpoke, vtReserveIdB, address(priceB));
    }

    // ─── Two proxies per wallet ───

    // TEST-271 verifies: REQ-ADAPTER-066, REQ-PROXY-018, SPEC-PROXY-006, INV-064, Q-307
    // Sources: real-Aave list (two proxies per wallet)
    /// @notice One wallet holds an account in each market of one Spoke; a price fall of market B lowers only account
    /// B's health factor, and account A keeps borrowing while B is below 1.
    function test_TEST_271_independentHealthUnderPriceMove() public {
        (, address pA) = _pledgeAs(alice, MARKET_ID, UNITS);
        (, address pB) = _pledgeAs(alice, MARKET_B, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 8000e18);
        _borrowAs(alice, MARKET_B, debtReserveId, 15_000e18);
        uint256 hfA = _hf(pA);
        priceB.set(1.5e8);
        assertEq(_hf(pA), hfA, "A unchanged by B's price");
        assertLt(_hf(pB), 1e18, "B below 1");
        _borrowAs(alice, MARKET_ID, usdcReserveId, 1000e6);
        assertEq(adapterC.borrowNonce(pA), 2, "A borrows on");
        // B's account is liquidatable on its own; A's records are not touched.
        uint256 sharesA = _sharesOf(pA, vtReserveId);
        swap.liquidate(aave.cdpSpoke, MARKET_B, vtB, vtReserveIdB, debtReserveId, pB, 2000e18, 2);
        assertEq(_sharesOf(pA, vtReserveId), sharesA, "A's collateral untouched");
    }

    // ─── borrowCount as the debt-free test ───

    // TEST-203 verifies: REQ-PROXY-034, REQ-ADAPTER-051, SPEC-PROXY-006
    // Sources: real-Aave list (`borrowCount` debt-free)
    /// @notice The debt-free test is Aave's `borrowCount`: one wei of GHO debt makes a withdrawal a with-debt one (the
    /// RiskModule is called, Paused refuses), and only a repay that clears every reserve brings it to 0.
    function test_TEST_203_borrowCountDecidesDebtFree() public {
        (bytes32 k1, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (bytes32 k2,) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 1);
        assertEq(_borrowCountOf(p), 2, "two borrowed reserves");
        _pause(PauseState.Paused, PauseReason.General);
        uint256 d = _deadline();
        vm.expectRevert(bytes4(keccak256("ApplicationPaused()")));
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, d, 0);
        _fund(alice, debtReserveId, 1);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 1, true, d);
        assertEq(_borrowCountOf(p), 1, "USDC still borrowed");
        vm.expectRevert(bytes4(keccak256("ApplicationPaused()")));
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, d, 0);
        _fund(alice, usdcReserveId, 1);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, 1, true, d);
        assertEq(_borrowCountOf(p), 0, "debt-free");
        vm.expectCall(address(risk), abi.encodeWithSelector(IRiskModuleChecks.preWithdrawCheck.selector), 0);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, d, 0);
        assertEq(lpVault.ownerOf(k1), alice, "debt-free exit under Paused");
        assertEq(lpVault.depositorOf(k2), alice, "k2 still pledged");
    }

    // TEST-075 verifies: REQ-PROXY-031, SPEC-PROXY-003, MATH-AR-18
    // Sources: real-Aave list (premium after a partial repay)
    /// @notice After interest accrues and a partial repay, the reserve still counts as borrowed until its last unit is
    /// repaid: a repay of all but one base unit leaves `borrowCount` at 1.
    function test_TEST_075_lastUnitKeepsReserveBorrowed() public {
        (, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 3000e6);
        vm.warp(block.timestamp + 45 days);
        uint256 live = _debtOf(p, usdcReserveId);
        _fund(alice, usdcReserveId, live - 1);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, live - 1, false, _deadline());
        assertGt(_debtOf(p, usdcReserveId), 0, "a remainder is owed");
        assertEq(_borrowCountOf(p), 1, "still borrowed");
        uint256 rest = _debtOf(p, usdcReserveId);
        _fund(alice, usdcReserveId, rest);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, rest, true, _deadline());
        assertEq(_borrowCountOf(p), 0, "cleared");
    }

    // ─── Dynamic configuration keys ───

    // TEST-027 verifies: REQ-PROXY-022, REQ-ADAPTER-068, REQ-PROXY-043, SPEC-PROXY-006
    // Sources: real-Aave list (dynamic keys)
    /// @notice The DAO adds a dynamic key with a lower collateral factor. An existing account keeps its key (its health
    /// factor is unchanged and a top-up pledge, which re-enables nothing, keeps it); a borrow refreshes every key of
    /// the account inside the Spoke call, so the health factor the RiskModule reads after the call already uses the new
    /// factor; a new account's first pledge takes the new key at once.
    function test_TEST_027_dynamicKeyRefreshedBySpokeCall() public {
        (, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 4000e18);
        uint32 oldKey = IAaveV4Spoke(aave.cdpSpoke).getUserPosition(vtReserveId, p).dynamicConfigKey;
        uint256 hfOld = _hf(p);
        assertEq(hfOld, uint256(16_000e18) * 1e18 / 4000e18, "CF 80%");
        vm.prank(aaveDao);
        uint32 newKey = cfg.addCollateralFactor(aave.cdpSpoke, vtReserveId, 5000);
        assertTrue(newKey != oldKey, "new key");
        assertEq(_hf(p), hfOld, "existing account keeps its key");
        _pledgeAs(alice, MARKET_ID, UNITS);
        assertEq(
            IAaveV4Spoke(aave.cdpSpoke).getUserPosition(vtReserveId, p).dynamicConfigKey, oldKey, "top-up keeps the key"
        );
        // The borrow refreshes the account: $40,000 at 50% against 4,001 GHO.
        uint256 expected = uint256(20_000e18) * 1e18 / 4001e18;
        address proxy = p;
        uint256 nonce = adapterC.borrowNonce(proxy);
        uint256 d = _deadline();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, expected, nonce);
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserPosition(vtReserveId, p).dynamicConfigKey, newKey, "refreshed");
        assertEq(_hf(p), expected, "health factor at the new factor");
        (, address pBob) = _pledgeAs(bob, MARKET_ID, UNITS);
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserPosition(vtReserveId, pBob).dynamicConfigKey, newKey, "new account");
    }

    // TEST-027 verifies: REQ-PROXY-022, REQ-PROXY-067
    /// @notice A caller minimum that held under the old key fails once the borrow refreshes the account to the new
    /// one: the gate reads Aave's health factor after the Spoke call.
    function test_TEST_027_minimumCheckedAfterRefresh() public {
        (, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 4000e18);
        vm.prank(aaveDao);
        cfg.addCollateralFactor(aave.cdpSpoke, vtReserveId, 5000);
        // Under the old key 1 more GHO leaves hf ≈ 3.999; under the new one ≈ 2.4994.
        uint256 d = _deadline();
        vm.expectRevert();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 3e18, 1);
        assertEq(adapterC.borrowNonce(p), 1, "nonce unchanged");
    }

    // ─── Per-account reserve limit ───

    // TEST-203 verifies: REQ-PROXY-044, REQ-PROXY-073, REQ-PROXY-096
    // Sources: real-Aave list (Spoke reserve limit); 2.5 REQ-PROXY-044 example
    /// @notice The CDP Spoke's `MAX_USER_RESERVES_LIMIT` is 4: a proxy borrows four distinct debt reserves through the
    /// Adapter and the first borrow of a fifth reverts in the Spoke with `MaximumUserReservesExceeded`, undoing the
    /// nonce; repaying one frees a slot.
    function test_TEST_203_reserveLimit() public {
        assertEq(IAaveV4Spoke(aave.cdpSpoke).MAX_USER_RESERVES_LIMIT(), 4, "limit");
        uint256[] memory extra = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) {
            extra[i] = _addDebtReserve(string(abi.encodePacked("D", bytes1(uint8(65 + i)))));
        }
        (, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 100e6);
        _borrowAs(alice, MARKET_ID, extra[0], 100e18);
        _borrowAs(alice, MARKET_ID, extra[1], 100e18);
        assertEq(_borrowCountOf(p), 4, "four reserves");
        uint256 d = _deadline();
        vm.expectRevert(bytes4(keccak256("MaximumUserReservesExceeded()")));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, extra[2], 100e18, alice, d, 0, 4);
        assertEq(adapterC.borrowNonce(p), 4, "nonce unchanged");
        // The same reserve again is no new reserve.
        _borrowAs(alice, MARKET_ID, extra[1], 1e18);
        uint256 owed = _debtOf(p, extra[0]);
        address asset0 = IAaveV4Spoke(aave.cdpSpoke).getReserve(extra[0]).underlying;
        CollPoolToken(asset0).mint(alice, owed);
        vm.prank(alice);
        ERC20(asset0).approve(adapter, owed);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, extra[0], owed, true, d);
        _borrowAs(alice, MARKET_ID, extra[2], 100e18);
        assertEq(_borrowCountOf(p), 4, "slot reused");
    }

    /// @dev Lists an 18-decimal $1.00 debt asset on the Hub, the Lend Spoke and the CDP Spoke, funds the Lend Spoke and
    /// enables the reserve in the registry stand-in.
    function _addDebtReserve(
        string memory name
    ) internal returns (uint256 reserveId) {
        CollPoolToken asset = new CollPoolToken(name, 18);
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        bytes memory irData = abi.encode(CollInterestRateData(9000, 0, 400, 6000));
        vm.startPrank(aaveDao);
        uint256 assetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, address(asset), 18, aave.treasurySpoke, 0, aave.irStrategy, irData);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.lendSpoke, assetId, CollHubSpokeConfig(maxCap, 0, maxRp, true, false));
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.cdpSpoke, assetId, CollHubSpokeConfig(0, 1_000_000, maxRp, true, false));
        uint256 lendReserve = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.lendSpoke,
                aave.hub,
                assetId,
                address(debtPrice),
                CollSpokeReserveConfig(0, false, false, true, false),
                CollSpokeDynamicReserveConfig(0, 10_000, 0)
            );
        reserveId = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                assetId,
                address(debtPrice),
                CollSpokeReserveConfig(0, false, false, true, false),
                CollSpokeDynamicReserveConfig(0, 10_000, 0)
            );
        vm.stopPrank();
        asset.mint(daoTreasury, 1_000_000e18);
        vm.startPrank(daoTreasury);
        ERC20(address(asset)).approve(aave.lendSpoke, 1_000_000e18);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserve, 1_000_000e18, daoTreasury);
        vm.stopPrank();
        registry.setDebtReserve(aave.cdpSpoke, reserveId, _debtDef(reserveId, address(asset), 18, assetId));
    }

    // ─── Signature and permit routes ───

    // TEST-187 verifies: REQ-PROXY-008, REQ-PROXY-011, REQ-PROXY-055, REQ-RISK-088, INV-063, ATTACK-022
    // Sources: real-Aave list (signature cases); Wave 2 review decision (PositionManagerApproved)
    /// @notice After a pledge, a `setUserPositionManagersWithSig` naming the proxy fails for any signature (the proxy
    /// has no key and no ERC-1271), an ERC-2612 `permit` naming the proxy as owner fails, and across a full account
    /// lifecycle through the Adapter no address becomes a position manager of the proxy.
    function test_TEST_187_noSignatureOrPermitNamesTheProxy() public {
        (bytes32 k, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        IAaveV4SpokePositionManagers.PositionManagerUpdate[] memory updates =
            new IAaveV4SpokePositionManagers.PositionManagerUpdate[](1);
        updates[0] = IAaveV4SpokePositionManagers.PositionManagerUpdate(attacker, true);
        IAaveV4SpokePositionManagers.SetUserPositionManagers memory params =
            IAaveV4SpokePositionManagers.SetUserPositionManagers(p, updates, 0, block.timestamp + 1);
        uint256[3] memory keys = [uint256(0xA11CE), uint256(uint160(alice)), uint256(0xB0B)];
        for (uint256 i = 0; i < keys.length; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], keccak256(abi.encode(params.onBehalfOf, i)));
            vm.expectRevert(bytes4(keccak256("InvalidSignature()")));
            vm.prank(attacker);
            IAaveV4SpokePositionManagers(aave.cdpSpoke)
                .setUserPositionManagersWithSig(params, abi.encodePacked(r, s, v));
        }
        RealAavePermitToken permitToken = new RealAavePermitToken();
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(0xA11CE, keccak256("permit"));
        vm.expectRevert();
        permitToken.permit(p, aave.cdpSpoke, type(uint256).max, block.timestamp + 1, v2, r2, s2);
        assertEq(permitToken.allowance(p, aave.cdpSpoke), 0, "no allowance");
        // A full lifecycle through the Adapter approves no manager for the proxy.
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        uint256 g = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, g);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, _deadline());
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k), UNITS, _deadline(), 0);
        address[5] memory candidates = [adapter, address(swap), address(coll), attacker, alice];
        for (uint256 i = 0; i < candidates.length; ++i) {
            assertFalse(IRealAaveSpokeViews(aave.cdpSpoke).isPositionManager(p, candidates[i]), "manager approved");
        }
    }

    // ─── Exits with a reverting registry and RiskModule ───

    // TEST-099 verifies: REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-PROXY-035, REQ-ADAPTER-042, INV-043, INV-045, ATTACK-035
    // Sources: real-Aave list (exits with a reverting registry or RiskModule)
    /// @notice A two-reserve account with two records exits completely (two repays by the wallet and a third party,
    /// two debt-free withdrawals, fee collection on the way) while the MarketRegistry and the RiskModule revert on
    /// every call, the Hub is `Paused(MintPathSuspect)` and the wallet is frozen.
    function test_TEST_099_fullExitWithBrokenRegistryAndRiskModule() public {
        (bytes32 k1, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (bytes32 k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 6000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 2000e6);
        vm.warp(block.timestamp + 20 days);
        registry.setFrozen(alice, true);
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        registry.setBroken(true);
        risk.setBroken(true);
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(carol, debtReserveId, g);
        _fund(alice, usdcReserveId, u);
        uint256 d = _deadline();
        vm.prank(carol);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, d);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, u, true, d);
        lpVault.accrueFees(k1, 10);
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(k1), d);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, d, 0);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, d, 0);
        assertEq(lpVault.ownerOf(k1), alice, "k1 home");
        assertEq(lpVault.ownerOf(k2), alice, "k2 home");
        assertEq(_borrowCountOf(p), 0, "no debt");
        assertEq(_sharesOf(p, vtReserveId), 0, "no collateral");
        (bool enabled,) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(vtReserveId, p);
        assertFalse(enabled, "cleanup ran");
    }

    // ─── Aave's own reserve pause ───

    // TEST-158 verifies: REQ-PROXY-077, REQ-PROXY-096, REQ-PROXY-032, REQ-PROXY-035
    // Sources: real-Aave list (reserve paused on Aave)
    /// @notice A debt reserve paused on Aave blocks its repay (the Spoke's `ReservePaused`) and a paused vault-token
    /// reserve blocks the withdrawal; both pass again once Aave unpauses, with no Avana state involved.
    function test_TEST_158_aavePauseBlocksFromAaveSideOnly() public {
        (bytes32 k, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        uint256 g = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, g);
        uint256 d = _deadline();
        vm.prank(aaveDao);
        cfg.updatePaused(aave.cdpSpoke, debtReserveId, true);
        vm.expectRevert(bytes4(keccak256("ReservePaused()")));
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, d);
        vm.prank(aaveDao);
        cfg.updatePaused(aave.cdpSpoke, debtReserveId, false);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, d);
        vm.prank(aaveDao);
        cfg.updatePaused(aave.cdpSpoke, vtReserveId, true);
        vm.expectRevert(bytes4(keccak256("ReservePaused()")));
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k), UNITS, d, 0);
        vm.prank(aaveDao);
        cfg.updatePaused(aave.cdpSpoke, vtReserveId, false);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k), UNITS, d, 0);
        assertEq(lpVault.ownerOf(k), alice, "exit after unpause");
    }
}
