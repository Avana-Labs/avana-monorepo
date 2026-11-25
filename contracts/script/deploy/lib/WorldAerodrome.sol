// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeployBase} from "./DeployBase.sol";

interface IFactoryRegistryAdmin {
    function approve(
        address poolFactory,
        address votingRewardsFactory,
        address gaugeFactory
    ) external;
}

interface IVoterAdmin {
    function initialize(
        address[] calldata tokens,
        address minter
    ) external;
    function createGauge(
        address poolFactory,
        address pool
    ) external returns (address);
}

interface ICLGaugeFactoryAdmin {
    function setNonfungiblePositionManager(
        address nft
    ) external;
}

/// @title WorldAerodrome
/// @notice Aerodrome on a test network, from the vendored sources: the ve(3,3) core of Aerodrome contracts v1.0
/// (1e08fb9: AERO, the v2 pool factory the FactoryRegistry falls back to, the gauge, voting-rewards and managed-rewards
/// factories, the FactoryRegistry, VotingEscrow, Voter, RewardsDistributor and Minter) and four Slipstream generations
/// (v1.0.0 37eead2 for generations 0–2, main f8717fa for generation 3), each with its pool implementation, CLFactory,
/// NonfungiblePositionManager, CLGauge implementation and CLGaugeFactory, its path approved in the FactoryRegistry.
/// @dev Every Slipstream pool gets its gauge from `Voter.createGauge`, as on Base: the gauge factory calls the pool's
/// `setGaugeAndPositionManager`, which gives the pool its `nft()` (Avana's LPVault requires it, 2.21) and a real gauge
/// that owns a position only while it is staked. The deployer is the Voter's governor, so pools of tokens not
/// whitelisted get gauges too. No ERC-2771 forwarder is used (address 0), so `_msgSender()` is always `msg.sender`.
abstract contract WorldAerodrome is DeployBase {
    string internal constant AERO_OUT = "out-aerodrome";
    string internal constant SLIP_V1 = "out-slipstream-v1";
    string internal constant SLIP_MAIN = "out-slipstream-main";

    address internal aero;
    address internal voter;
    address internal factoryRegistry;
    address internal votingRewardsFactory;
    address internal minter;
    address[4] internal slipFactories;
    address[4] internal slipNpms;
    address[4] internal slipGaugeFactories;

    function _aerodromeCore() internal {
        aero = _deploy("AERO", _artifactIn(AERO_OUT, "Aero.sol", "Aero"));
        address poolImpl = _deploy("AerodromePool", _artifactIn(AERO_OUT, "Pool.sol", "Pool"));
        address poolFactory = _deploy(
            "AerodromePoolFactory",
            bytes.concat(_artifactIn(AERO_OUT, "PoolFactory.sol", "PoolFactory"), abi.encode(poolImpl))
        );
        votingRewardsFactory =
            _deploy("VotingRewardsFactory", _artifactIn(AERO_OUT, "VotingRewardsFactory.sol", "VotingRewardsFactory"));
        address gaugeFactory = _deploy("GaugeFactory", _artifactIn(AERO_OUT, "GaugeFactory.sol", "GaugeFactory"));
        address managed = _deploy(
            "ManagedRewardsFactory", _artifactIn(AERO_OUT, "ManagedRewardsFactory.sol", "ManagedRewardsFactory")
        );
        factoryRegistry = _deploy(
            "FactoryRegistry",
            bytes.concat(
                _artifactIn(AERO_OUT, "FactoryRegistry.sol", "FactoryRegistry"),
                abi.encode(poolFactory, votingRewardsFactory, gaugeFactory, managed)
            )
        );
        // VotingEscrow links two external libraries; deploy them and link as Foundry does at build time.
        string[] memory fqns = new string[](2);
        address[] memory libs = new address[](2);
        fqns[0] = "dependencies/aerodrome-contracts-1.0/contracts/libraries/BalanceLogicLibrary.sol:BalanceLogicLibrary";
        fqns[1] =
            "dependencies/aerodrome-contracts-1.0/contracts/libraries/DelegationLogicLibrary.sol:DelegationLogicLibrary";
        libs[0] =
            _deploy("BalanceLogicLibrary", _artifactIn(AERO_OUT, "BalanceLogicLibrary.sol", "BalanceLogicLibrary"));
        libs[1] = _deploy(
            "DelegationLogicLibrary", _artifactIn(AERO_OUT, "DelegationLogicLibrary.sol", "DelegationLogicLibrary")
        );
        address ve = _deploy(
            "VotingEscrow",
            bytes.concat(
                _artifactLinked(AERO_OUT, "VotingEscrow.sol", "VotingEscrow", fqns, libs),
                abi.encode(address(0), aero, factoryRegistry)
            )
        );
        voter = _deploy(
            "Voter",
            bytes.concat(_artifactIn(AERO_OUT, "Voter.sol", "Voter"), abi.encode(address(0), ve, factoryRegistry))
        );
        address distributor = _deploy(
            "RewardsDistributor",
            bytes.concat(_artifactIn(AERO_OUT, "RewardsDistributor.sol", "RewardsDistributor"), abi.encode(ve))
        );
        minter = _deploy(
            "Minter", bytes.concat(_artifactIn(AERO_OUT, "Minter.sol", "Minter"), abi.encode(voter, ve, distributor))
        );
        IVoterAdmin(voter).initialize(new address[](0), minter);
    }

    /// @notice Generation `g` of Slipstream: pool implementation, CLFactory, position manager, gauge factory.
    function _slipstreamGeneration(
        uint256 g,
        address weth
    ) internal {
        bool main =
            g == 3 && vm.exists(string.concat(vm.projectRoot(), "/", SLIP_MAIN, "/CLFactory.sol/CLFactory.json"));
        string memory out = main ? SLIP_MAIN : SLIP_V1;
        string memory n = vm.toString(g);
        address poolImpl = _deploy(string.concat("CLPool.", n), _artifactIn(out, "CLPool.sol", "CLPool"));
        // main (f8717fa) adds the legacy factory: the previous generation's, which createPool checks first.
        slipFactories[g] = _deploy(
            string.concat("SlipstreamFactory.", n),
            bytes.concat(
                _artifactIn(out, "CLFactory.sol", "CLFactory"),
                main ? abi.encode(voter, slipFactories[g - 1], poolImpl) : abi.encode(voter, poolImpl)
            )
        );
        slipNpms[g] = _deploy(
            string.concat("SlipstreamPositionManager.", n),
            bytes.concat(
                _artifactIn(out, "NonfungiblePositionManager.sol", "NonfungiblePositionManager"),
                abi.encode(slipFactories[g], weth, address(0), "Slipstream Position NFT v1", "AERO-CL-POS")
            )
        );
        address gaugeImpl = _deploy(string.concat("CLGauge.", n), _artifactIn(out, "CLGauge.sol", "CLGauge"));
        // main's gauge factory reads the Voter's minter, takes an emission admin, a default emission cap (bps) and the
        // previous generation's gauge factory.
        slipGaugeFactories[g] = _deploy(
            string.concat("CLGaugeFactory.", n),
            bytes.concat(
                _artifactIn(out, "CLGaugeFactory.sol", "CLGaugeFactory"),
                main
                    ? abi.encode(voter, gaugeImpl, deployer, uint256(100), slipGaugeFactories[g - 1])
                    : abi.encode(voter, gaugeImpl)
            )
        );
        ICLGaugeFactoryAdmin(slipGaugeFactories[g]).setNonfungiblePositionManager(slipNpms[g]);
        IFactoryRegistryAdmin(factoryRegistry).approve(slipFactories[g], votingRewardsFactory, slipGaugeFactories[g]);
    }

    /// @notice The pool's gauge, created through the Voter as on Base.
    function _gauge(
        uint256 g,
        address pool
    ) internal returns (address) {
        return IVoterAdmin(voter).createGauge(slipFactories[g], pool);
    }
}
