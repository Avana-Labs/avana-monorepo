// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CloseAccountView} from "../../src/lens/lens/types/CloseAccountView.sol";
import {DeleverageSizing} from "../../src/lens/lens/types/DeleverageSizing.sol";
import {HubAssetView} from "../../src/lens/lens/types/HubAssetView.sol";
import {RemovalSizing} from "../../src/lens/lens/types/RemovalSizing.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensSizingGasTest
/// @notice REQ-LENS-020 bounds of the views added for the app: the removal sizing and the close-account preview over 16
/// records, the deleverage bisection over the largest record, the after-action previews and the Hub-asset view, each
/// far inside a 30M-gas block.
/// forge-config: default.isolate = false
contract LensSizingGasTest is LensFixture {
    uint256 internal constant BLOCK_GAS = 30_000_000;

    function setUp() public {
        _deployLens();
    }

    function _sixteenRecords() internal {
        for (uint256 i = 1; i <= 16; ++i) {
            _open(alice, aliceProxy, i, uint128(1000e6 * i));
        }
        _borrow(aliceProxy, 60_000e18);
        _borrowUsdc(aliceProxy, 20_000e6);
    }

    // TEST-247 verifies: REQ-LENS-020, REQ-LENS-054, REQ-LENS-056
    function test_TEST_247_sixteenRecordSizingFitsTheBlock() public {
        _sixteenRecords();
        uint256 g = gasleft();
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 1.2e18);
        uint256 removal = g - gasleft();
        g = gasleft();
        CloseAccountView memory c = lens.previewCloseAccount(alice, MARKET_ID, block.timestamp + 600);
        uint256 close = g - gasleft();
        assertEq(s.records.length, 16, "every record");
        assertEq(c.records.length, 16, "every record");
        assertEq(c.debts.length, 2, "both debts");
        assertLt(removal, 3_000_000, "removal sizing over 16 records");
        assertLt(close, 4_000_000, "close-account preview over 16 records");
    }

    // TEST-247 verifies: REQ-LENS-020, REQ-LENS-055
    function test_TEST_247_deleverageBisectionFitsTheBlock() public {
        _open(alice, aliceProxy, 1, 5_000_000e6);
        _borrow(aliceProxy, 900_000e18);
        uint256 g = gasleft();
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, 1e30);
        uint256 used = g - gasleft();
        assertTrue(s.reachable, "clearing the debt reaches it");
        assertLt(used, BLOCK_GAS / 10, "two bisections of at most 128 steps");
    }

    // TEST-247 verifies: REQ-LENS-020, REQ-LENS-052, REQ-LENS-058
    function test_TEST_247_actionPreviewsAndHubAssetFitTheBlock() public {
        _sixteenRecords();
        uint256 g = gasleft();
        lens.previewBorrowAfter(alice, MARKET_ID, debtReserveId, 1000e18);
        lens.previewRepayAfter(alice, MARKET_ID, usdcReserveId, 1000e6);
        lens.previewWithdrawAfter(alice, MARKET_ID, _key(3));
        uint256 actions = g - gasleft();
        g = gasleft();
        HubAssetView memory v = lens.getHubAsset(aave.hub, ghoAssetId);
        uint256 hubAsset = g - gasleft();
        assertEq(v.spokes.length, 3, "fee receiver, Lend, CDP");
        assertLt(actions, 3_000_000, "three after-action previews");
        assertLt(hubAsset, 1_000_000, "the Hub asset with its slices");
    }
}
