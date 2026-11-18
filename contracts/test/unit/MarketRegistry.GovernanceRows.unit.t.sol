// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";

/// @notice Governance-page rows of the MarketRegistry that the other unit tests do not check: the per-market switch,
/// pool flag and halting lift that do not exist.
contract MarketRegistryGovernanceRowsUnitTest is MarketRegistryFixture {
    function setUp() public {
        _setUpWorld();
    }

    /// @dev A call to `signature` on the registry finds no function: it reverts with empty return data.
    function _assertAbsent(
        string memory signature
    ) internal {
        (bool ok, bytes memory ret) =
            address(registry).call(abi.encodeWithSignature(signature, uint256(1), address(0), uint8(0)));
        assertFalse(ok, signature);
        assertEq(ret.length, 0, signature);
    }

    // TEST-035 verifies: REQ-ACCESS-035, REQ-ACCESS-081, REQ-ACCESS-136, REQ-ACCESS-087
    // Sources: 2.15 REQ-ACCESS-035, REQ-ACCESS-081, REQ-ACCESS-136, REQ-ACCESS-087
    // No per-market freeze switch, no pool-broken flag and no halting lift exist on the registry; per-market
    // containment is the live market gates, the Aave reserve freeze and the Offboarding status.
    function test_TEST_035_noMarketSwitchPoolFlagOrHaltingLift() public {
        string[8] memory absent = [
            "freezeMarket(uint256)",
            "setPoolBroken(uint256,bool)",
            "poolBroken(uint256)",
            "isPoolBroken(uint256)",
            "liftHalting()",
            "liftHalting(uint256)",
            "liftHalting(address)",
            "isHalting(uint256)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            _assertAbsent(absent[i]);
        }
    }
}
