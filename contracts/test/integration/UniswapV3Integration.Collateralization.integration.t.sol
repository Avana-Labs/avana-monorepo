// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    CollPriceSource,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    CollateralizationFixture,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "../utils/fixtures/CollateralizationFixture.sol";
import {UniswapV3IntegrationHarness} from "../utils/harness/UniswapV3IntegrationHarness.sol";
import {MintableToken, MockNFPM, MockV3Factory, MockV3Pool} from "../utils/mocks/UniswapV3Mocks.sol";

/// @notice The Uniswap v3 LPVault behind the real Collateralization, the real Lock, the real VaultTokenFactory and its
/// vault token on the real local Aave V4: integration 2, market 5 on the full range of a USDC/USDT 0.3% pool (6
/// decimals). Donations to the LPVault (ERC-20s, ETH, liquidity added to a custodied NFT, a pushed NFT) change no
/// Collateralization record, cap counter, credited total or vault-token supply.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationCollateralizationIntegrationTest is CollateralizationFixture {
    uint32 internal constant V3_INTEGRATION = 2;
    uint256 internal constant V3_MARKET = 5;
    int24 internal constant FULL = 887_220;

    address internal registry = makeAddr("marketRegistry");
    MockV3Factory internal v3Factory;
    MockNFPM internal nfpm;
    MintableToken internal tUsdc;
    MintableToken internal tUsdt;
    MockV3Pool internal v3Pool;
    UniswapV3IntegrationHarness internal v3Vault;
    address internal vt2;
    VaultToken internal token2;
    uint256 internal reserve2;

    function setUp() public {
        _deployCollateralization();
        v3Factory = new MockV3Factory();
        nfpm = new MockNFPM(address(v3Factory));
        tUsdc = new MintableToken("USDC", 6);
        tUsdt = new MintableToken("USDT", 6);
        v3Pool = MockV3Pool(v3Factory.createPool(address(tUsdc), address(tUsdt), 3000, 60));
        v3Vault = new UniswapV3IntegrationHarness(
            V3_INTEGRATION,
            address(coll),
            registry,
            address(lock),
            timelock,
            address(nfpm),
            address(v3Factory),
            v3Factory.poolInitCodeHash()
        );
        vm.prank(timelock);
        factory.registerIntegration(V3_INTEGRATION, address(v3Vault));
        PositionShape memory shape = PositionShape(ShapeKind.TickRange, -FULL, FULL);
        vm.prank(registry);
        (, uint8 d) = v3Vault.bindMarket(V3_MARKET, address(v3Pool), bytes32(0), shape, abi.encode(1e8, 1e8));
        assertEq(d, 6);
        vm.prank(timelock);
        vt2 = factory.deployVaultToken(
            V3_INTEGRATION,
            address(v3Pool),
            bytes32(0),
            shape,
            aave.hub,
            aave.cdpSpoke,
            V3_MARKET,
            address(oracle),
            d,
            "Avana USDC/USDT full",
            "avUSDC-USDT-F"
        );
        token2 = VaultToken(vt2);
        _listVaultToken2();
    }

    function _listVaultToken2() internal {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        bytes memory irData = abi.encode(CollInterestRateData(9000, 0, 400, 6000));
        CollPriceSource price = new CollPriceSource(2e8);
        vm.startPrank(aaveDao);
        uint256 assetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, vt2, 6, aave.treasurySpoke, 0, aave.irStrategy, irData);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(
                aave.hub,
                aave.cdpSpoke,
                assetId,
                CollHubSpokeConfig(5_500_000, 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false)
            );
        reserve2 = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                assetId,
                address(price),
                CollSpokeReserveConfig(0, false, false, false, false),
                CollSpokeDynamicReserveConfig(8000, 10_500, 0)
            );
        vm.stopPrank();
    }

    // ─── Flows ───

    function _pledgeV3(
        address owner,
        address proxy,
        uint128 liquidity
    ) internal returns (bytes32 key) {
        uint256 id = nfpm.mint(owner, v3Pool.token0(), v3Pool.token1(), 3000, -FULL, FULL, liquidity);
        key = bytes32(id);
        vm.prank(owner);
        nfpm.approve(address(v3Vault), id);
        vm.startPrank(adapter);
        lock.acquire();
        if (!token2.isValidProxy(proxy)) token2.addValidProxy(proxy);
        (, uint128 credited) = coll.pledge(owner, proxy, vt2, key, false);
        token2.mint(proxy, credited);
        vm.stopPrank();
        vm.startPrank(proxy);
        token2.approve(aave.cdpSpoke, credited);
        IAaveV4Spoke(aave.cdpSpoke).supply(reserve2, credited, proxy);
        IAaveV4Spoke(aave.cdpSpoke).setUsingAsCollateral(reserve2, true, proxy);
        vm.stopPrank();
        vm.prank(adapter);
        lock.release();
    }

    function _withdrawV3(
        address proxy,
        bytes32 key,
        uint256 units
    ) internal {
        vm.prank(adapter);
        lock.acquire();
        vm.prank(proxy);
        IAaveV4Spoke(aave.cdpSpoke).withdraw(reserve2, units, proxy);
        vm.startPrank(adapter);
        token2.burn(proxy, units);
        coll.release(proxy, vt2, key, units);
        lock.release();
        vm.stopPrank();
    }

    struct Snapshot {
        uint128 credited;
        uint128 originalUnits;
        uint64 usdCharge;
        uint256 totalCredited;
        uint256 supply;
        uint128 regularUsed;
        uint128 sliceUsed;
        uint256 depositorUsed;
        uint256 poolUnits;
        uint256 token0Used;
        uint256 token1Used;
    }

    function _snapshot(
        bytes32 key,
        address depositor
    ) internal view returns (Snapshot memory s) {
        BackingRecord memory r = coll.getRecord(coll.recordIdOf(V3_INTEGRATION, key));
        PledgeCounters memory c = coll.getCounters(vt2, depositor);
        s = Snapshot({
            credited: r.credited,
            originalUnits: r.originalUnits,
            usdCharge: r.currentUsdCharge,
            totalCredited: coll.getTotalCredited(vt2),
            supply: token2.totalSupply(),
            regularUsed: c.regularUsed,
            sliceUsed: c.sliceUsed,
            depositorUsed: c.depositorUsed,
            poolUnits: c.poolUnits,
            token0Used: c.tokenUsed[0],
            token1Used: c.tokenUsed[1]
        });
    }

    function _assertSame(
        Snapshot memory a,
        Snapshot memory b
    ) internal pure {
        assertEq(a.credited, b.credited, "credited");
        assertEq(a.originalUnits, b.originalUnits, "originalUnits");
        assertEq(a.usdCharge, b.usdCharge, "charge");
        assertEq(a.totalCredited, b.totalCredited, "total credited");
        assertEq(a.supply, b.supply, "vault-token supply (mint)");
        assertEq(a.regularUsed, b.regularUsed, "regular cap counter");
        assertEq(a.sliceUsed, b.sliceUsed, "slice counter");
        assertEq(a.depositorUsed, b.depositorUsed, "depositor cap counter");
        assertEq(a.poolUnits, b.poolUnits, "pool-share counter");
        assertEq(a.token0Used, b.token0Used, "token0 cap counter");
        assertEq(a.token1Used, b.token1Used, "token1 cap counter");
    }

    // ─── Tests ───

    // TEST-010 verifies: REQ-VAULT-167, REQ-VAULT-003, REQ-COLL-024, REQ-AMM-CORE-006, INV-005, INV-006, INV-017
    // Sources: 5.1 TEST-010 with the real LPVault, Collateralization, Lock and vault token
    function test_TEST_010_pledgeAndWithdrawThroughCollateralization() public {
        bytes32 key = _pledgeV3(alice, aliceProxy, 5e9);
        assertEq(nfpm.ownerOf(uint256(key)), address(v3Vault));
        assertEq(v3Vault.depositorOf(key), alice);
        BackingRecord memory r = coll.getRecord(coll.recordIdOf(V3_INTEGRATION, key));
        assertEq(r.credited, 5e9);
        assertEq(token2.totalSupply(), 5e9);
        _withdrawV3(aliceProxy, key, 5e9);
        assertEq(nfpm.ownerOf(uint256(key)), alice);
        assertEq(v3Vault.depositorOf(key), address(0));
        assertEq(coll.recordIdOf(V3_INTEGRATION, key), 0);
    }

    // TEST-016 verifies: REQ-VAULT-077, REQ-VAULT-085, REQ-VAULT-093, REQ-VAULT-152, INV-002, INV-006, ATTACK-006
    // Sources: 5.1 TEST-016, TEST-080; BRIEF 2026-11-10 (donations change no record, cap, credit or mint)
    function test_TEST_016_donationsChangeNoRecordCapCreditOrMint() public {
        bytes32 key = _pledgeV3(alice, aliceProxy, 5e9);
        Snapshot memory before = _snapshot(key, alice);
        // ERC-20s: both pool tokens, another market's token and an LP token; ETH.
        tUsdc.mint(address(v3Vault), 1e12);
        tUsdt.mint(address(v3Vault), 1e12);
        usdc.mint(address(v3Vault), 1e12);
        new MintableToken("LP", 18).mint(address(v3Vault), 1e30);
        vm.deal(address(v3Vault), 10 ether);
        // Liquidity a third party adds to the custodied NFT.
        vm.prank(attacker);
        nfpm.increaseLiquidity(uint256(key), 7e9);
        // An NFT pushed with safeTransferFrom.
        uint256 pushed = nfpm.mint(attacker, v3Pool.token0(), v3Pool.token1(), 3000, -FULL, FULL, 9e9);
        vm.prank(attacker);
        nfpm.safeTransferFrom(attacker, address(v3Vault), pushed);
        _assertSame(before, _snapshot(key, alice));
        assertEq(coll.recordIdOf(V3_INTEGRATION, bytes32(pushed)), 0, "the pushed NFT has no record");
        assertEq(v3Vault.depositorOf(bytes32(pushed)), address(0));
        // The pushed NFT cannot be pledged by anyone: its owner is the LPVault.
        vm.startPrank(adapter);
        lock.acquire();
        token2.addValidProxy(bobProxy);
        vm.expectRevert(ILPVaultErrors.NotTokenOwner.selector);
        coll.pledge(attacker, bobProxy, vt2, bytes32(pushed), false);
        // A third party cannot re-credit the donated liquidity.
        vm.expectRevert(ICollateralizationErrors.NotDepositor.selector);
        coll.recredit(attacker, aliceProxy, vt2, key, "", false);
        lock.release();
        vm.stopPrank();
        _assertSame(before, _snapshot(key, alice));
        // Fees and the withdrawal still pay only the depositor; the donated liquidity goes back with the NFT.
        nfpm.accrue(uint256(key), 1_000_000, 2_000_000);
        uint256 b0 = MintableToken(v3Pool.token0()).balanceOf(alice);
        vm.startPrank(adapter);
        lock.acquire();
        coll.collectFees(alice, vt2, key);
        lock.release();
        vm.stopPrank();
        assertEq(MintableToken(v3Pool.token0()).balanceOf(alice) - b0, 1_000_000);
        _assertSame(before, _snapshot(key, alice));
        _withdrawV3(aliceProxy, key, 5e9);
        (,,,,,,, uint128 l,,,,) = nfpm.positions(uint256(key));
        assertEq(l, 12e9, "pledged plus donated liquidity back to alice");
        assertEq(nfpm.ownerOf(uint256(key)), alice);
        assertEq(tUsdc.balanceOf(address(v3Vault)), 1e12, "donations stay in the LPVault");
        // The pushed NFT leaves only through the timelock's stray return.
        vm.prank(timelock);
        v3Vault.returnStray(bytes32(pushed), attacker);
        assertEq(nfpm.ownerOf(pushed), attacker);
    }

    // TEST-238 verifies: REQ-VAULT-077, REQ-COLL-015, REQ-AMM-CORE-011
    // Sources: 5.1 TEST-238 (only the depositor's re-credit credits added liquidity; an empty topUp for NFTs)
    function test_TEST_238_onlyTheDepositorRecreditsAddedLiquidity() public {
        bytes32 key = _pledgeV3(alice, aliceProxy, 5e9);
        nfpm.increaseLiquidity(uint256(key), 2e9);
        vm.startPrank(adapter);
        lock.acquire();
        vm.expectRevert(ILPVaultErrors.TopUpNotSupported.selector);
        coll.recredit(alice, aliceProxy, vt2, key, hex"01", false);
        (uint128 added,) = coll.recredit(alice, aliceProxy, vt2, key, "", false);
        lock.release();
        vm.stopPrank();
        assertEq(added, 2e9);
        assertEq(coll.getRecord(coll.recordIdOf(V3_INTEGRATION, key)).credited, 7e9);
    }
}
