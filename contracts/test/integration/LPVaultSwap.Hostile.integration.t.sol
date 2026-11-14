// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationSeizure} from "../../src/custody/collateralization/ICollateralizationSeizure.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {IAaveAdapterSettlement} from "../../src/policy/aave-adapter/IAaveAdapterSettlement.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackVolatile} from "../utils/fixtures/RealStackVolatile.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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
/// @notice A hostile LPVaultSwap installed through the real AvanaTimelock (scheduled by the governance multisig,
/// executed after the normal delay) on the real stack (`RealStackFlows`: the real AaveAdapter, Collateralization,
/// RiskModule, Lock, vault tokens, PositionProxies, ProxyManager, PayoutEscrow, First-Loss Reserves, Uniswap v3 LPVault
/// on the NonfungiblePositionManager, `DexPathRoute`s and Aave V4): what it cannot do (TEST-131), the C-QNT-1
/// regression through the borrower's exits and the honest pending settlement, after the honest implementation is
/// restored through the timelock, into the First-Loss Reserve (TEST-154), the Adapter's seized-unit burn (TEST-208)
/// and each record's proxy across two markets (TEST-089); and each First-Loss Reserve covering only its own asset's
/// deficit (TEST-211), on a WETH/USDC market of `RealStackVolatile`'s Volatile Hub.
/// @dev Accounts are made liquidatable by USDT falling to $0.93 (`_depegUsdt`): the vault token goes from $2.00 to
/// $1.9287 (CF 30 %). Seizures are sized within Aave's close amount (the debt that restores HF 1.10). Pending units
/// settle into the market's settlement asset, GHO (`registry.settlementReserve`), and its First-Loss Reserve. TEST-211
/// needs collateral worth less than the debt, out of reach for USD-stable collateral inside the USD band: its account
/// holds a full-range WETH/USDC NFT on the Volatile Spoke, and WETH falls 99 %.
/// forge-config: default.isolate = false
contract LPVaultSwapHostileIntegrationTest is RealStackVolatile {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal mA;
    address internal vt;
    address internal honestImpl;
    HostileLiquidatorImpl internal hostile;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vt = mkt[mA].vaultToken;
        honestImpl = address(uint160(uint256(vm.load(lpVaultSwap, IMPL_SLOT))));
        hostile = new HostileLiquidatorImpl(address(timelock));
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(lpVaultSwap, IMPL_SLOT))));
    }

    /// @dev The hostile implementation installed through the real timelock at its required delay.
    function _installHostile() internal {
        _govern(lpVaultSwap, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(hostile), "")));
        assertEq(_implementation(), address(hostile), "hostile implementation");
    }

    /// @dev The honest implementation restored through the real timelock (the hostile one authorizes it alone).
    function _restoreHonest() internal {
        _govern(lpVaultSwap, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (honestImpl, "")));
        assertEq(_implementation(), honestImpl, "honest implementation");
    }

    function _run(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        return HostileLiquidatorImpl(lpVaultSwap).run(target, data);
    }

    function _account(
        address wallet,
        uint128 units,
        uint256 usdcDebt
    ) internal returns (address proxy, bytes32 key) {
        (key, proxy) = _pledgeAs(wallet, mA, units);
        if (usdcDebt != 0) _borrowAs(wallet, mA, usdcReserveId, usdcDebt);
    }

    function _credited(
        bytes32 key
    ) internal view returns (uint256) {
        return coll.getRecord(coll.recordIdOf(V3, key)).credited;
    }

    function _ownerOf(
        bytes32 key
    ) internal view returns (address) {
        return IERC721(address(nfpm)).ownerOf(uint256(key));
    }

    /// @dev The hostile implementation repays `amount` of `proxy`'s USDC debt through `liquidationCall` and keeps the
    /// seized vault tokens. Returns the units it received.
    function _hostileSeizeAndKeep(
        address proxy,
        uint256 amount
    ) internal returns (uint256 c) {
        uint256 before = IERC20(vt).balanceOf(lpVaultSwap);
        usdc.mint(lpVaultSwap, amount);
        _run(address(usdc), abi.encodeCall(IERC20.approve, (aave.cdpSpoke, amount)));
        _run(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.liquidationCall, (mkt[mA].reserveId, usdcReserveId, proxy, amount, false))
        );
        c = IERC20(vt).balanceOf(lpVaultSwap) - before;
    }

    /// @notice A hostile LPVaultSwap cannot seize a healthy account (Aave refuses it), mint vault tokens, burn more than
    /// it holds through the Adapter, or debit another account's records: settling bob's seizure under alice's snapshot
    /// reverts `SeizureMismatch` and settling alice for bob's units reverts `DebitMismatch`.
    // TEST-131 verifies: REQ-VAULT-049, REQ-VAULT-050, REQ-VAULT-051, REQ-ADAPTER-070, ATTACK-025, ATTACK-079
    function test_TEST_131_hostileLPVaultSwapBoundedByAaveAndTheLedger() public {
        (address healthy,) = _account(alice, UNITS, 2000e6);
        (address bobProxy,) = _account(bob, UNITS, 5880e6);
        _depegUsdt(93_000_000);
        uint256 aliceCredited = coll.getAccountCredited(healthy, vt);
        _installHostile();
        usdc.mint(lpVaultSwap, 1000e6);
        _run(address(usdc), abi.encodeCall(IERC20.approve, (aave.cdpSpoke, 1000e6)));
        vm.expectRevert();
        _run(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.liquidationCall, (mkt[mA].reserveId, usdcReserveId, healthy, 1000e6, false))
        );
        vm.expectRevert(IVaultToken.OnlyAdapter.selector);
        _run(vt, abi.encodeWithSignature("mint(address,uint256)", lpVaultSwap, 1));

        _run(address(lock), abi.encodeCall(ILock.acquire, ()));
        _run(address(coll), abi.encodeCall(ICollateralizationSeizure.beginSeizure, (healthy, vt)));
        uint256 c = _hostileSeizeAndKeep(bobProxy, 500e6);
        assertGt(c, 0, "bob seized");
        vm.expectRevert();
        _run(adapter, abi.encodeCall(IAaveAdapterSettlement.burnSeized, (mA, vt, c + 1)));
        _run(adapter, abi.encodeCall(IAaveAdapterSettlement.burnSeized, (mA, vt, c)));
        vm.expectRevert(ICollateralizationErrors.SeizureMismatch.selector);
        _run(
            address(coll), abi.encodeCall(ICollateralizationSeizure.settleSeizure, (bobProxy, vt, c, new uint256[](0)))
        );
        vm.expectRevert(ICollateralizationErrors.DebitMismatch.selector);
        _run(address(coll), abi.encodeCall(ICollateralizationSeizure.settleSeizure, (healthy, vt, c, new uint256[](0))));
        _run(address(lock), abi.encodeCall(ILock.release, ()));
        assertEq(coll.getAccountCredited(healthy, vt), aliceCredited, "alice's records untouched");
    }

    /// @notice C-QNT-1: records of 10,000 and 8,000 units; a hostile LPVaultSwap installed through the timelock seizes
    /// units and keeps them. The borrower repays and withdraws NFT "42" (the shortfall reconciled into pending, the NFT
    /// back with its remaining liquidity), then NFT "7" (all its units); the honest LPVaultSwap restored through the
    /// timelock settles the pending units, after which the market's vault-token supply is 0 and what the real unwind and
    /// routes recovered has gone to the settlement asset's First-Loss Reserve. No position stays in custody.
    // TEST-154 verifies: REQ-SWAP-066, REQ-VAULT-129, REQ-VAULT-131, INV-001, INV-042, Q-201
    function test_TEST_154_cQnt1ThroughTheExitsAndTheAvanaFirstLossReserve() public {
        (bytes32 k42, address proxy) = _pledgeAs(alice, mA, 10_000e6);
        (bytes32 k7,) = _pledgeAs(alice, mA, 8000e6);
        // 18,000 vault tokens ($36,000, $10,800 of borrowing power) against 10,500 USDC: HF 0.99 after the depeg. The
        // kept seizure repays 300 USDC, within Aave's close amount and leaving the debt above its dust threshold.
        _borrowAs(alice, mA, usdcReserveId, 10_500e6);
        _depegUsdt(93_000_000);
        assertLt(_hf(proxy), 1e18, "liquidatable");
        uint256 credited42 = _credited(k42);
        uint256 credited7 = _credited(k7);
        _installHostile();
        uint256 c = _hostileSeizeAndKeep(proxy, 300e6);
        assertGt(c, 0, "units seized and kept");
        assertEq(IERC20(vt).balanceOf(lpVaultSwap), c, "held by LPVaultSwap");

        _repayVia(alice, alice, mA, usdcReserveId, _debtOf(proxy, usdcReserveId) + 1e6, true);
        uint256 units42 = coll.previewRelease(V3, k42);
        assertEq(units42, credited42 - c, "NFT 42 previews its remaining units");
        _withdrawVia(alice, mA, k42, units42);
        assertEq(_ownerOf(k42), alice, "NFT 42 returned");
        assertEq(coll.getPending(vt).units, c, "the kept units are pending");
        _withdrawVia(alice, mA, k7, credited7);
        assertEq(_ownerOf(k7), alice, "NFT 7 returned");

        _restoreHonest();
        uint256 settleReserve = registry.settlementReserve(mA);
        IAvanaFirstLossReserve reserve = IAvanaFirstLossReserve(firstLossReserveOf[address(_assetOf(settleReserve))]);
        uint256 funded = reserve.fundedBalance();
        (uint256 units,, uint256 added) = lvs.settlePending(mA, settleReserve);
        assertEq(units, c, "the pending units settled");
        assertEq(IERC20(vt).totalSupply(), 0, "market supply 0");
        assertEq(coll.getPending(vt).units, 0, "nothing pending");
        assertGt(added, 0, "proceeds recovered");
        assertApproxEqAbs(reserve.fundedBalance(), funded + added, 1, "the proceeds fund the First-Loss Reserve");
    }

    /// @notice The Adapter's seized-unit burn: any caller other than LPVaultSwap, and LPVaultSwap without the Lock,
    /// reverts `NotLPVaultSwap`; in a liquidation it burns exactly `c` from LPVaultSwap, emits `SeizedUnitsBurned`, and
    /// the proxy's share drop, `c` and the supply drop are equal, in the None, Frozen and Paused states alike. Each
    /// liquidation repays 50 USDC, so bob's account stays below HF 1 for the next.
    // TEST-208 verifies: REQ-ADAPTER-070, REQ-SWAP-020, REQ-SWAP-092
    function test_TEST_208_burnSeizedOnlyLPVaultSwapUnderTheLock() public {
        vm.prank(attacker);
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        IAaveAdapterSettlement(adapter).burnSeized(mA, vt, 1);
        vm.prank(lpVaultSwap);
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        IAaveAdapterSettlement(adapter).burnSeized(mA, vt, 1);
        PauseState[3] memory states = [PauseState.None, PauseState.Frozen, PauseState.Paused];
        (address proxy,) = _account(bob, UNITS, 5880e6);
        _depegUsdt(93_000_000);
        for (uint256 i = 0; i < 3; ++i) {
            _setPause(states[i], i == 0 ? PauseReason.None : PauseReason.General);
            uint256 shares = _sharesOf(proxy, mkt[mA].reserveId);
            uint256 supply = IERC20(vt).totalSupply();
            vm.recordLogs();
            LiquidationResult memory r = _liquidateAs(keeper, _liqParams(proxy, mA, usdcReserveId, 50e6));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 burns;
            for (uint256 k = 0; k < logs.length; ++k) {
                if (logs[k].emitter != adapter || logs[k].topics[0] != IAaveAdapterEvents.SeizedUnitsBurned.selector) {
                    continue;
                }
                ++burns;
                assertEq(uint256(logs[k].topics[1]), mA, "event market");
                assertEq(address(uint160(uint256(logs[k].topics[2]))), vt, "event vault token");
                assertEq(abi.decode(logs[k].data, (uint256)), r.unitsSeized, "event units = c");
            }
            assertEq(burns, 1, "one SeizedUnitsBurned");
            assertEq(shares - _sharesOf(proxy, mkt[mA].reserveId), r.unitsSeized, "share drop = c");
            assertEq(supply - IERC20(vt).totalSupply(), r.unitsSeized, "supply drop = c");
            assertEq(IERC20(vt).balanceOf(lpVaultSwap), 0, "burned only from LPVaultSwap");
        }
    }

    /// @notice Every record's proxy is `proxyOf(depositor, marketId)` for its market, the proxy the ProxyManager
    /// deployed on the Adapter's call and the vault token registered: pledges into two markets (the full ranges of the
    /// 0.01 % and 0.05 % USDC/USDT pools) from one wallet land on two proxies, each valid only in its own market's vault
    /// token.
    // TEST-089 verifies: REQ-PROXY-032, REQ-COLL-005, INV-043
    function test_TEST_089_recordProxyIsTheMarketsProxy() public {
        uint256 mB = _addMarket(poolB);
        (bytes32 k1, address p1) = _pledgeAs(alice, mA, 1000e6);
        (bytes32 k2, address p2) = _pledgeAs(alice, mB, 1000e6);
        assertEq(p1, adapterC.proxyOf(alice, mA), "market A proxy");
        assertEq(p2, adapterC.proxyOf(alice, mB), "market B proxy");
        assertTrue(p1 != p2, "one proxy per market");
        assertEq(coll.getRecord(coll.recordIdOf(V3, k1)).proxy, p1, "record A names proxy A");
        assertEq(coll.getRecord(coll.recordIdOf(V3, k2)).proxy, p2, "record B names proxy B");
        assertEq(proxyManager.predictProxy(alice, aave.cdpSpoke, mA), p1, "at the predicted address");
        assertTrue(IVaultToken(vt).isValidProxy(p1), "valid in its market");
        assertFalse(IVaultToken(vt).isValidProxy(p2), "not valid in another market");
        assertTrue(IVaultToken(mkt[mB].vaultToken).isValidProxy(p2), "valid in market B");
    }

    /// @notice Each First-Loss Reserve covers only deficits of its own `(Hub, asset)`: an account owing USDC and GHO on
    /// the Volatile Spoke ($60,000 of WETH/USDC liquidity against 8,000 USDC and 8,000 GHO, HF 1.125) sees WETH fall 99 %
    /// on every feed and in the pool (the liquidity is then worth about $6,000), is liquidated in USDC with the Lens's
    /// parameters until its collateral is gone, and the Spoke records a deficit in both assets; the real USDC First-Loss
    /// Reserve's `coverDeficit` clears the USDC deficit and leaves the GHO deficit exactly unchanged.
    // TEST-211 verifies: SPEC-FLR-001, INV-079, ATTACK-173
    function test_TEST_211_coverageReducesOnlyItsOwnAssetsDeficit() public {
        _setUpVolatile();
        IClPool[] memory pools = new IClPool[](1);
        pools[0] = _newVolatilePool(weth, usdc, 500, 1e18);
        _ageNewPools(pools);
        uint256 m = _addVolatileMarket(pools[0], 3000);
        (, address p) = _pledgeUsd(carol, m, 60_000);
        _borrowAs(carol, m, usdcReserveIdV, 8000e6);
        _borrowAs(carol, m, ghoReserveIdV, 8000e18);
        _publish(address(weth), WETH_PRICE / 100);
        _repriceMarkets();
        LiquidationPreview memory pv = lens.previewLiquidation(p, usdcReserveIdV, block.timestamp + 120);
        assertTrue(pv.aaveLiquidatable && pv.pricesUsable, "liquidatable with usable prices");
        pv.params.maxShortfall = pv.params.debtToCover / 20;
        _liquidateOn(spokeV, keeper, pv.params);
        assertEq(_sharesOn(spokeV, p, mkt[m].reserveId), 0, "the collateral is gone");
        IHubDeficitView h = IHubDeficitView(hubV);
        uint256 ghoDeficit = h.getSpokeDeficitRay(ghoAssetIdV, spokeV);
        assertGt(h.getSpokeDeficitRay(usdcAssetIdV, spokeV), 0, "USDC deficit recorded");
        assertGt(ghoDeficit, 0, "GHO deficit recorded");
        AvanaFirstLossReserve usdcReserve = AvanaFirstLossReserve(firstLossReserveOfV[address(usdc)]);
        _enableCover(address(usdcReserve), spokeV);
        vm.prank(coverageCaller);
        (, uint256 covered) = usdcReserve.coverDeficit(spokeV, type(uint256).max);
        assertGt(covered, 0, "USDC deficit covered");
        assertEq(h.getSpokeDeficitRay(usdcAssetIdV, spokeV), 0, "USDC deficit cleared");
        assertEq(h.getSpokeDeficitRay(ghoAssetIdV, spokeV), ghoDeficit, "GHO deficit unchanged");
    }

    /// @dev The Aave DAO's roles for a First-Loss Reserve's cover: `coverDeficit` for `coverageCaller`, the borrow-Spoke
    /// allowlist for the Aave governance executor, which allows `spoke`.
    function _enableCover(
        address cs,
        address spoke
    ) internal {
        bytes4[] memory cover = new bytes4[](1);
        cover[0] = AvanaFirstLossReserve.coverDeficit.selector;
        bytes4[] memory admin = new bytes4[](1);
        admin[0] = AvanaFirstLossReserve.setAllowedBorrowSpoke.selector;
        IAccessManager am = IAccessManager(aave.accessManager);
        vm.startPrank(aaveDao);
        am.setTargetFunctionRole(cs, cover, 500);
        am.setTargetFunctionRole(cs, admin, 501);
        am.grantRole(500, coverageCaller, 0);
        am.grantRole(501, aaveGovernanceExecutor, 0);
        vm.stopPrank();
        vm.prank(aaveGovernanceExecutor);
        AvanaFirstLossReserve(cs).setAllowedBorrowSpoke(spoke, true);
    }
}

interface IHubDeficitView {
    function getSpokeDeficitRay(
        uint256 assetId,
        address spoke
    ) external view returns (uint256);
}
