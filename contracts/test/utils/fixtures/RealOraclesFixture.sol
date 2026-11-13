// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracle} from "../../../src/oracle/debt-oracle/IDebtOracle.sol";
import {DebtOracleInitParams} from "../../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {DebtPriceView} from "../../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {LPOracleCL} from "../../../src/oracle/lp-oracle/LPOracleCL.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {PriceStateView} from "../../../src/types/PriceStateView.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {TokenPriceView} from "../../../src/types/TokenPriceView.sol";
import {DebtRegistryMock, DebtStoreMock} from "../mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {LPOracleCLFixture} from "./LPOracleCLFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title RealOraclesFixture
/// @notice The real concentrated-liquidity LPOracle of `LPOracleCLFixture` (one market per `_deployClMarket`, on a
/// real Uniswap v3 pool) beside a real USDC DebtOracle behind its UUPS proxy, the implementation deployed from its
/// build artifact: primary USDC/USD (8 decimals, 86,400 s heartbeat, 1,800 s margin), alternate USDC/ETH (18 decimals,
/// same heartbeat) times ETH/USD (8 decimals, 3,600 s, margin 1,800 s), a standby USDC/USD and an oracle-network second
/// source; `T = 225`, `debtStressRiseBps = 500`, launch timers, no sequencer. Its MarketRegistry and ParameterStore
/// views are mocks (their own suites test the real ones).
/// @dev `_seizable` and `_repayable` are LPVaultSwap's two oracle rules (`_checkCollateralPrice`, `_checkDebtPrice`)
/// read after a poke: a test of the oracles' side of a liquidation asks exactly what LPVaultSwap asks.
abstract contract RealOraclesFixture is LPOracleCLFixture {
    int256 internal constant USDC_USD = 99_990_000;
    int256 internal constant USDC_ETH = 333_300_000_000_000;
    int256 internal constant ETH_USD = 300_000_000_000;
    uint32 internal constant LP_LEG_AGE = MAX_AGE;
    uint32 internal constant USDC_AGE = 88_200;
    uint32 internal constant ETH_USD_AGE = 5400;

    address internal usdcDebt = makeAddr("USDC debt asset");
    MockAggregator internal dPrimary;
    MockAggregator internal dAltUsdcEth;
    MockAggregator internal dAltEthUsd;
    MockAggregator internal dStandby;
    MockAggregator internal dSecond;
    DebtRegistryMock internal dRegistry;
    DebtStoreMock internal dStore;
    IDebtOracle internal debtOracle;

    function _deployUsdcDebtOracle() internal {
        uint256 at = block.timestamp;
        dPrimary = new MockAggregator(8, USDC_USD, at);
        dAltUsdcEth = new MockAggregator(18, USDC_ETH, at);
        dAltEthUsd = new MockAggregator(8, ETH_USD, at);
        dStandby = new MockAggregator(8, 99_995_000, at);
        dSecond = new MockAggregator(8, 99_980_000, at);
        dRegistry = new DebtRegistryMock();
        dStore = new DebtStoreMock();
        dRegistry.list(
            usdcDebt, _one(address(dPrimary)), _two(address(dAltUsdcEth), address(dAltEthUsd)), _one(address(dStandby))
        );
        dStore.setFeed(address(dPrimary), 8, 0, 1e12, 86_400, 1800);
        dStore.setFeed(address(dAltUsdcEth), 18, 0, 1e18, 86_400, 1800);
        dStore.setFeed(address(dAltEthUsd), 8, 0, 1e12, 3600, 1800);
        dStore.setFeed(address(dStandby), 8, 0, 1e12, 86_400, 1800);
        dStore.setFeed(address(dSecond), 8, 0, 1e12, 86_400, 1800);
        dStore.setTolerance(usdcDebt, 225);
        dStore.setStressRise(usdcDebt, 500);
        dStore.setSecondSource(
            usdcDebt, SecondSource(SecondSourceKind.OracleNetwork, address(dSecond), bytes32(0), 88_200, 0, 100)
        );
        IDebtOracle impl = IDebtOracle(deployCode("DebtOracle.sol:DebtOracle", abi.encode(tl)));
        DebtOracleInitParams memory p = DebtOracleInitParams({
            timelock: tl,
            asset: usdcDebt,
            marketRegistry: address(dRegistry),
            parameterStore: address(dStore),
            description: "USDC / USD",
            pokeMinGas: 600_000
        });
        debtOracle = IDebtOracle(address(new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)))));
        vm.label(address(debtOracle), "USDC DebtOracle");
    }

    function _two(
        address a,
        address b
    ) internal pure returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (a, b);
    }

    /// @dev A new round on every USDC feed at the current time with its current answer.
    function _refreshDebt() internal {
        dPrimary.republish(block.timestamp);
        dAltUsdcEth.republish(block.timestamp);
        dAltEthUsd.republish(block.timestamp);
        dStandby.republish(block.timestamp);
        dSecond.republish(block.timestamp);
    }

    /// @dev LPVaultSwap's collateral rule after a poke: not liquidation-paused, Cached, Expired, inside or past the
    /// disagreement pause, and every leg in use within its `liquidationPriceMaxAge` (88,200 s for every feed here).
    function _seizable(
        LPOracleCL o
    ) internal returns (bool) {
        o.poke{gas: 5_000_000}();
        PriceStateView memory ps = o.getPriceState();
        if (
            ps.liquidationPaused || ps.state == PriceState.Cached || ps.state == PriceState.Expired
                || ps.disagreementPauseActive || ps.disagreementExpired
        ) return false;
        for (uint256 i = 0; i < ps.tokens.length; ++i) {
            TokenPriceView memory t = ps.tokens[i];
            for (uint256 k = 0; k < 2; ++k) {
                if (t.legFeeds[k] != address(0) && block.timestamp - t.legUpdatedAt[k] > LP_LEG_AGE) return false;
            }
        }
        return true;
    }

    /// @dev LPVaultSwap's debt rule for the USDC reserve after a poke: Live, not liquidation-paused, every leg in use
    /// within its `liquidationPriceMaxAge`.
    function _repayable() internal returns (bool) {
        debtOracle.poke{gas: 5_000_000}();
        DebtPriceView memory v = debtOracle.getPriceState();
        if (v.state != PriceState.Live || v.liquidationPaused) return false;
        for (uint256 k = 0; k < 2; ++k) {
            address f = v.legFeeds[k];
            if (f == address(0)) continue;
            uint256 limit = f == address(dAltEthUsd) ? ETH_USD_AGE : USDC_AGE;
            if (block.timestamp - v.legUpdatedAt[k] > limit) return false;
        }
        return true;
    }
}
