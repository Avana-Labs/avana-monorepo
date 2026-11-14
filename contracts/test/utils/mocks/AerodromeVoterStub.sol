// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The gauge factory function of Slipstream's `CLGaugeFactory` the Voter calls.
interface ISlipGaugeFactory {
    function createGauge(
        address forwarder,
        address pool,
        address feesVotingReward,
        address rewardToken,
        bool isPool
    ) external returns (address gauge);
}

/// @title AerodromeVoterStub
/// @notice Aerodrome's Voter and Minter as the real Slipstream contracts read them: a `CLFactory` reads
/// `factoryRegistry()` at construction, the main generation's `CLGaugeFactory` reads `minter()` and the minter's
/// `aero()`, a gauge factory creates a pool's gauge only when the Voter calls it, and a `CLFactory` reads `gauges(pool)`
/// and `isAlive(gauge)` on every swap for the unstaked fee. `createGauge` makes that call as `Voter.createGauge` does
/// for a pool of an approved factory and records the gauge as alive, so the gauge factory gives the pool its real gauge
/// and position manager (`setGaugeAndPositionManager`, which Avana's Slipstream LPVault requires).
/// @dev Voting, emissions and fee rewards are out of scope: the fees voting reward named to a gauge is this address.
contract AerodromeVoterStub {
    address public immutable factoryRegistry;
    address public immutable aero;
    /// @notice Per pool, its gauge.
    mapping(address pool => address gauge) public gauges;
    /// @notice Whether a gauge is alive (every gauge created here; none is killed).
    mapping(address gauge => bool alive) public isAlive;

    constructor(
        address factoryRegistry_,
        address aero_
    ) {
        factoryRegistry = factoryRegistry_;
        aero = aero_;
    }

    /// @notice The Minter (this contract).
    function minter() external view returns (address) {
        return address(this);
    }

    /// @notice Creates `pool`'s gauge through `gaugeFactory`, as the Voter.
    function createGauge(
        address gaugeFactory,
        address pool
    ) external returns (address gauge) {
        gauge = ISlipGaugeFactory(gaugeFactory).createGauge(address(0), pool, address(this), aero, true);
        gauges[pool] = gauge;
        isAlive[gauge] = true;
    }
}
