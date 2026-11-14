// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracle} from "../../../src/oracle/debt-oracle/IDebtOracle.sol";
import {DebtOracleInitParams} from "../../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {DebtRegistryMock, DebtStoreMock} from "../mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {TimelockFixture} from "./TimelockFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DebtOracleFixture
/// @notice One USDC DebtOracle behind its UUPS proxy, owned by a real AvanaTimelock, reading mocked MarketRegistry and
/// ParameterStore views and mocked Chainlink proxies: primary USDC/USD (8 decimals, 86,400 s heartbeat, 1,800 s
/// margin, `feedMaxAge = 88,200`), alternate USDC/ETH (18 decimals, same heartbeat) × ETH/USD (8 decimals, 3,600 s,
/// `feedMaxAge = 5,400`), standby USDC/USD, and an oracle-network second source with `maxAge = 88,200` and
/// `S = 100`. `T = 225`, `debtStressRiseBps = 500`, `cachedWindow = disagreementPauseMax = 3,600`,
/// `graceDuration = 1,800`; Ethereum (no sequencer feed). Every route reads $0.9999 at the start.
abstract contract DebtOracleFixture is TimelockFixture {
    uint256 internal constant T0 = 1_762_650_000;
    int256 internal constant USDC_USD = 99_990_000;
    int256 internal constant USDC_ETH = 333_300_000_000_000;
    int256 internal constant ETH_USD = 300_000_000_000;
    uint32 internal constant MIN_GAS = 600_000;
    uint16 internal constant TOLERANCE = 225;
    uint16 internal constant STRESS = 500;

    address internal usdc = makeAddr("USDC");
    MockAggregator internal pUsd;
    MockAggregator internal aEth;
    MockAggregator internal ethUsd;
    MockAggregator internal standby;
    MockAggregator internal second;
    DebtRegistryMock internal reg;
    DebtStoreMock internal store;
    IDebtOracle internal impl;
    IDebtOracle internal oracle;

    function _deployDebtOracle() internal {
        vm.warp(T0);
        _deployTimelock();
        pUsd = new MockAggregator(8, USDC_USD, T0 - 100);
        aEth = new MockAggregator(18, USDC_ETH, T0 - 100);
        ethUsd = new MockAggregator(8, ETH_USD, T0 - 100);
        standby = new MockAggregator(8, 99_995_000, T0 - 100);
        second = new MockAggregator(8, 99_980_000, T0 - 100);
        vm.label(address(pUsd), "USDC/USD");
        vm.label(address(aEth), "USDC/ETH");
        vm.label(address(ethUsd), "ETH/USD");
        vm.label(address(standby), "USDC/USD standby");
        vm.label(address(second), "USDC second source");
        reg = new DebtRegistryMock();
        store = new DebtStoreMock();
        reg.list(usdc, _route1(address(pUsd)), _route2(address(aEth), address(ethUsd)), _route1(address(standby)));
        store.setFeed(address(pUsd), 8, 0, 1e12, 86_400, 1800);
        store.setFeed(address(aEth), 18, 0, 1e18, 86_400, 1800);
        store.setFeed(address(ethUsd), 8, 0, 1e12, 3600, 1800);
        store.setFeed(address(standby), 8, 0, 1e12, 86_400, 1800);
        store.setFeed(address(second), 8, 0, 1e12, 86_400, 1800);
        store.setTolerance(usdc, TOLERANCE);
        store.setStressRise(usdc, STRESS);
        store.setSecondSource(usdc, _oracleNetwork(address(second)));
        impl = _newImplementation(address(timelock));
        oracle =
            IDebtOracle(address(new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (_params())))));
        vm.label(address(oracle), "USDC DebtOracle");
    }

    /// @dev The implementation from its build artifact, so test files never import the IR-compiled DebtOracle source
    /// (a via-IR test caches `block.timestamp` across `vm.warp`).
    function _newImplementation(
        address timelock_
    ) internal returns (IDebtOracle) {
        return IDebtOracle(deployCode("DebtOracle.sol:DebtOracle", abi.encode(timelock_)));
    }

    function _params() internal view returns (DebtOracleInitParams memory p) {
        p = DebtOracleInitParams({
            timelock: address(timelock),
            asset: usdc,
            marketRegistry: address(reg),
            parameterStore: address(store),
            description: "USDC / USD",
            pokeMinGas: MIN_GAS
        });
    }

    function _oracleNetwork(
        address feed
    ) internal pure returns (SecondSource memory s) {
        s = SecondSource({
            kind: SecondSourceKind.OracleNetwork,
            source: feed,
            poolRef: bytes32(0),
            maxAge: 88_200,
            twapWindow: 0,
            toleranceBps: 100
        });
    }

    function _route1(
        address a
    ) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _route2(
        address a,
        address b
    ) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    /// @dev A new round on every feed at the current time with its current answer.
    function _refreshAll() internal {
        _refresh(pUsd);
        _refresh(aEth);
        _refresh(ethUsd);
        _refresh(standby);
        _refresh(second);
    }

    function _refresh(
        MockAggregator f
    ) internal {
        f.republish(block.timestamp);
    }

    function _poke() internal returns (PriceState) {
        return oracle.poke{gas: 5_000_000}();
    }

    function _served() internal view returns (uint256) {
        return uint256(oracle.latestAnswer());
    }

    function _accepted() internal view returns (uint256 price8) {
        (price8,) = oracle.lastAcceptedPrice();
    }

    function _state() internal view returns (PriceState) {
        return oracle.getPriceState().state;
    }

    /// @dev Whether the second source (`maxAge = 88,200`, tolerance 100 bps) is valid and within its tolerance of
    /// `value` (`SPEC-ORC-020`).
    function _secondConfirms(
        uint256 value
    ) internal view returns (bool) {
        (, int256 s,, uint256 at,) = second.latestRoundData();
        if (s <= 0 || s > 1e12 || at > block.timestamp || block.timestamp - at > 88_200) return false;
        uint256 su = uint256(s);
        uint256 diff = value > su ? value - su : su - value;
        return diff * 1e4 <= 100 * (value < su ? value : su);
    }

    /// @dev The route value a Drifting asset counts (`SPEC-ORC-018`): the higher route when the second source confirms
    /// it, else the lower one.
    function _countedRoute(
        uint256 p,
        uint256 b
    ) internal view returns (uint256) {
        uint256 hi = p > b ? p : b;
        return _secondConfirms(hi) ? hi : (p < b ? p : b);
    }

    /// @dev The Drifting served price: `max(counted, A)`.
    function _driftingServed(
        uint256 p,
        uint256 b,
        uint256 a
    ) internal view returns (uint256) {
        uint256 c = _countedRoute(p, b);
        return c > a ? c : a;
    }
}
