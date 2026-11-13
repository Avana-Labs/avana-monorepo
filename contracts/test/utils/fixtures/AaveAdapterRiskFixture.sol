// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {AaveAdapter} from "../../../src/policy/aave-adapter/AaveAdapter.sol";
import {AaveAdapterCollateralLogic} from "../../../src/policy/aave-adapter/AaveAdapterCollateralLogic.sol";
import {AaveAdapterExitLogic} from "../../../src/policy/aave-adapter/AaveAdapterExitLogic.sol";
import {AaveAdapterSettlementLogic} from "../../../src/policy/aave-adapter/AaveAdapterSettlementLogic.sol";
import {AaveAdapterUserLogic} from "../../../src/policy/aave-adapter/AaveAdapterUserLogic.sol";
import {AaveAdapterLogics} from "../../../src/policy/aave-adapter/types/AaveAdapterLogics.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {RiskModule} from "../../../src/policy/risk-module/RiskModule.sol";
import {RiskModuleBorrowLogic} from "../../../src/policy/risk-module/RiskModuleBorrowLogic.sol";
import {RiskModuleBreakerLogic} from "../../../src/policy/risk-module/RiskModuleBreakerLogic.sol";
import {RiskModuleDriftLogic} from "../../../src/policy/risk-module/RiskModuleDriftLogic.sol";
import {RiskModulePledgeLogic} from "../../../src/policy/risk-module/RiskModulePledgeLogic.sol";
import {RiskModuleSpeedLogic} from "../../../src/policy/risk-module/RiskModuleSpeedLogic.sol";
import {RiskModuleStatusLogic} from "../../../src/policy/risk-module/RiskModuleStatusLogic.sol";
import {RiskModuleImmutables} from "../../../src/policy/risk-module/types/RiskModuleImmutables.sol";
import {RiskModuleLogics} from "../../../src/policy/risk-module/types/RiskModuleLogics.sol";
import {RiskDebtOracleMock, RiskLPOracleMock, RiskLPVaultMock, RiskStoreMock} from "../mocks/RiskModuleMocks.sol";
import {AaveAdapterFixture} from "./AaveAdapterFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IRiskHubConfigurator {
    function updateSpokeAddCap(
        address hub,
        uint256 assetId,
        address spoke,
        uint256 addCap
    ) external;
}

interface IRiskSpokeConfigurator {
    function updateReservePriceSource(
        address spoke,
        uint256 reserveId,
        address priceSource
    ) external;
}

/// @title AaveAdapterRiskFixture
/// @notice The AaveAdapterFixture with the reviewed RiskModule (router and its five logic contracts behind ERC-1967)
/// as the Adapter's `RISK_MODULE`, reading the real Aave V4 Spoke, Hub and AaveOracle, the real Collateralization and
/// the real Lock. The Adapter is upgraded in place to an implementation built with that RiskModule and with the
/// ParameterStore stand-in below.
/// @dev Stand-ins, each named: the MarketRegistry (`AdapterRegistryMock`, which carries the views the RiskModule reads:
/// market and debt-reserve records consistent with the Spoke, approved implementation, routes, breaker latches), the
/// ParameterStore (`RiskStoreMock`: token collateral factors 8,000, pool risk factor 10,000, so the expected collateral
/// factor equals the Spoke's 8,000; liquidation expectations equal to the Spoke's), each market's LPOracle
/// (`RiskLPOracleMock`, made the AaveOracle source of its vault-token reserve so the drift check's price-source rule
/// holds), the USDC DebtOracle (`RiskDebtOracleMock`, the AaveOracle source of the USDC reserve), the LPVault's
/// `riskStatus` (`RiskLPVaultMock`) and LPVaultSwap's keeper count (`LPVaultSwapMock`). Collateralization keeps
/// `CollRiskModuleMock` for `checkPledge` (it is immutable and built before this RiskModule), so pledge-side gates are
/// not this fixture's subject.
abstract contract AaveAdapterRiskFixture is AaveAdapterFixture {
    uint256 internal constant T0 = 1_762_650_000;
    uint32 internal constant FEED_AGE = 88_200;

    RiskModule internal rm;
    RiskStoreMock internal rstore;
    RiskLPOracleMock internal lpOracleA;
    RiskLPOracleMock internal lpOracleB;
    RiskDebtOracleMock internal usdcOracle;
    RiskLPVaultMock internal riskVault;
    address internal feedUsdc = makeAddr("feed USDC/USD");
    address internal feedUsdt = makeAddr("feed USDT/USD");

    function setUp() public virtual override {
        vm.warp(T0);
        super.setUp();
        rstore = new RiskStoreMock();
        rstore.setLiquidationExpectations(aave.cdpSpoke, 1.1e18, 200);
        rstore.setTokenCf(address(usdc), 8000);
        rstore.setTokenCf(address(usdt), 8000);
        rstore.setMarket(MARKET_ID, 10_000, 0, 1e30, 0, 0);
        rstore.setMarket(MARKET_B, 10_000, 0, 1e30, 0, 0);
        rstore.setTwap(MARKET_ID, 1800);
        rstore.setTwap(MARKET_B, 1800);
        rstore.setBorrowAge(feedUsdc, FEED_AGE);
        rstore.setBorrowAge(feedUsdt, FEED_AGE);

        riskVault = new RiskLPVaultMock(INTEGRATION, address(coll), address(lock));
        lpOracleA = new RiskLPOracleMock(MARKET_ID, address(riskVault));
        lpOracleB = new RiskLPOracleMock(MARKET_B, address(riskVault));
        usdcOracle = new RiskDebtOracleMock(address(usdcDebt), address(registry), address(rstore));
        vm.startPrank(aaveDao);
        IRiskSpokeConfigurator(aave.spokeConfigurator)
            .updateReservePriceSource(aave.cdpSpoke, vtReserveId, address(lpOracleA));
        IRiskSpokeConfigurator(aave.spokeConfigurator)
            .updateReservePriceSource(aave.cdpSpoke, vtReserveIdB, address(lpOracleB));
        IRiskSpokeConfigurator(aave.spokeConfigurator)
            .updateReservePriceSource(aave.cdpSpoke, usdcReserveId, address(usdcOracle));
        // The listing payload gives each vault-token asset's fee receiver no add cap (REQ-HUB, drift FeeReceiverAddCap).
        IRiskHubConfigurator(aave.hubConfigurator).updateSpokeAddCap(aave.hub, vtAssetId, aave.treasurySpoke, 0);
        IRiskHubConfigurator(aave.hubConfigurator)
            .updateSpokeAddCap(aave.hub, IAaveV4Hub(aave.hub).getAssetId(vtB), aave.treasurySpoke, 0);
        vm.stopPrank();
        registry.setMarketOracle(MARKET_ID, address(lpOracleA), address(riskVault));
        registry.setMarketOracle(MARKET_B, address(lpOracleB), address(riskVault));
        DebtReserveDef memory u = _debtDef(usdcReserveId, address(usdcDebt), 6, usdcAssetId);
        u.priceSource = address(usdcOracle);
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, u);
        _report(lpOracleA, uint64(block.timestamp));
        _report(lpOracleB, uint64(block.timestamp));

        RiskModuleImmutables memory rmIm = RiskModuleImmutables({
            marketRegistry: address(registry),
            parameterStore: address(rstore),
            collateralization: address(coll),
            adapter: adapter,
            lpVaultSwap: address(swap),
            timelock: timelock
        });
        RiskModuleLogics memory l;
        l.drift = address(new RiskModuleDriftLogic(rmIm));
        l.breaker = address(new RiskModuleBreakerLogic(rmIm, l.drift));
        l.pledge = address(new RiskModulePledgeLogic(rmIm, l.drift, l.breaker));
        l.borrow = address(new RiskModuleBorrowLogic(rmIm, l.drift, l.breaker));
        l.status = address(new RiskModuleStatusLogic(rmIm, l.drift, l.breaker, l.borrow));
        l.speed = address(new RiskModuleSpeedLogic(rmIm));
        RiskModule rmImpl = new RiskModule(rmIm, l);
        rm = RiskModule(address(new ERC1967Proxy(address(rmImpl), abi.encodeCall(RiskModule.initialize, (timelock)))));
        vm.label(address(rm), "RiskModule");

        // The Adapter, upgraded in place: same proxy, same storage, the reviewed RiskModule and this ParameterStore.
        im.riskModule = address(rm);
        im.parameterStore = address(rstore);
        logics = AaveAdapterLogics({
            user: address(new AaveAdapterUserLogic(im)),
            exit: address(new AaveAdapterExitLogic(im)),
            collateral: address(new AaveAdapterCollateralLogic(im)),
            settlement: address(new AaveAdapterSettlementLogic(im))
        });
        implementation = new AaveAdapter(im, logics);
        vm.prank(timelock);
        AaveAdapter(adapter).upgradeToAndCall(address(implementation), "");
    }

    /// @dev A Live report of both pool tokens, each with one leg updated at `at`.
    function _report(
        RiskLPOracleMock o,
        uint64 at
    ) internal {
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        address[] memory feeds = new address[](2);
        (feeds[0], feeds[1]) = (feedUsdc, feedUsdt);
        uint64[] memory ats = new uint64[](2);
        (ats[0], ats[1]) = (at, at);
        uint256[] memory quotes = new uint256[](2);
        (quotes[0], quotes[1]) = (1e8, 1e8);
        o.setTokens(toks, feeds, ats, quotes, new uint32[](2));
    }
}
