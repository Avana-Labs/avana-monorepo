// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

// Copyright (c) 2026 Avana Labs

// Build entry of the vendored Aerodrome contracts v1.0 (1e08fb9) for local and test-network deployments only: the
// aerodrome profile compiles what Slipstream's gauges and the Voter need (AERO, VotingEscrow and its art proxy, the
// FactoryRegistry, the v2 PoolFactory and Pool the registry's fallback names, the gauge, voting-rewards and
// managed-rewards factories, the Voter, the Minter and the RewardsDistributor) with Aerodrome's settings (Solidity
// 0.8.19, 200 runs). The ERC-2771 ProtocolForwarder (opengsn) and the governors are not needed and not built.
import {Aero} from "dependencies/aerodrome-contracts-1.0/contracts/Aero.sol";
import {Minter} from "dependencies/aerodrome-contracts-1.0/contracts/Minter.sol";
import {Pool} from "dependencies/aerodrome-contracts-1.0/contracts/Pool.sol";
import {RewardsDistributor} from "dependencies/aerodrome-contracts-1.0/contracts/RewardsDistributor.sol";
import {VeArtProxy} from "dependencies/aerodrome-contracts-1.0/contracts/VeArtProxy.sol";
import {Voter} from "dependencies/aerodrome-contracts-1.0/contracts/Voter.sol";
import {VotingEscrow} from "dependencies/aerodrome-contracts-1.0/contracts/VotingEscrow.sol";
import {FactoryRegistry} from "dependencies/aerodrome-contracts-1.0/contracts/factories/FactoryRegistry.sol";
import {GaugeFactory} from "dependencies/aerodrome-contracts-1.0/contracts/factories/GaugeFactory.sol";
import {
    ManagedRewardsFactory
} from "dependencies/aerodrome-contracts-1.0/contracts/factories/ManagedRewardsFactory.sol";
import {PoolFactory} from "dependencies/aerodrome-contracts-1.0/contracts/factories/PoolFactory.sol";
import {VotingRewardsFactory} from "dependencies/aerodrome-contracts-1.0/contracts/factories/VotingRewardsFactory.sol";
