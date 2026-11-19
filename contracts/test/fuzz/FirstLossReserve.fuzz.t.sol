// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FirstLossReserveFixture} from "../utils/fixtures/FirstLossReserveFixture.sol";

/// @notice The loss order and the "pays only real deficits" rule over random losses, balances and caps.
contract FirstLossReserveFuzzTest is FirstLossReserveFixture {
    function setUp() public {
        _deployLayers();
    }

    /// @notice Avana pays first, the offset only the rest, and neither pays past the recorded deficit.
    function testFuzz_lossOrder(
        uint256 loss,
        uint256 extraAvana,
        uint256 extraOffset
    ) public {
        loss = bound(loss, 1e18, CREDIT_LINE_GHO / 2);
        extraAvana = bound(extraAvana, 0, 200_000e18);
        extraOffset = bound(extraOffset, 0, 200_000e18);
        if (extraAvana != 0) _fundLayer(avanaLayer, avanaLabs, extraAvana);
        if (extraOffset != 0) _fundLayer(daoOffset, daoTreasury, extraOffset);
        address cdp = aave.cdpSpoke;
        _reportDeficit(ghoAssetId, cdp, loss);

        uint256 avanaBalance = avanaLayer.fundedBalance();
        uint256 offsetBalance = daoOffset.fundedBalance();
        uint256 byAvana = _cover(avanaLayer, cdp, type(uint256).max);
        assertEq(byAvana, loss < avanaBalance ? loss : avanaBalance, "Avana pays min(loss, balance)");

        uint256 rest = loss - byAvana;
        if (rest == 0) {
            assertEq(_deficit(cdp), 0);
            return;
        }
        uint256 byOffset = _cover(daoOffset, cdp, type(uint256).max);
        assertEq(byOffset, rest < offsetBalance ? rest : offsetBalance, "offset pays the rest");
        assertEq(_deficit(cdp), rest - byOffset, "residual stays recorded");
        assertLe(byAvana + byOffset, loss, "never past the deficit");
    }

    /// @notice A capped cover pays exactly the cap, and the balance falls by what was covered.
    function testFuzz_coverCapped(
        uint256 loss,
        uint256 cap
    ) public {
        loss = bound(loss, 1e18, 90_000e18);
        cap = bound(cap, 1, loss);
        address cdp = aave.cdpSpoke;
        _reportDeficit(ghoAssetId, cdp, loss);
        uint256 before = avanaLayer.fundedBalance();
        uint256 covered = _cover(avanaLayer, cdp, cap);
        assertEq(covered, cap);
        assertEq(_deficit(cdp), loss - cap);
        assertApproxEqAbs(before - avanaLayer.fundedBalance(), cap, 1, "balance falls by the cover");
    }
}
