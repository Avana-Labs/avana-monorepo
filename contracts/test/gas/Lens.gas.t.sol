// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RecordBackingView} from "../../src/lens/lens/types/RecordBackingView.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensGasTest
/// @notice REQ-LENS-020 bounds: each view at its worst case stays far inside a 30M-gas block (Ethereum's smaller
/// limit; Base's is larger): a full page of `LENS_MAX_PAGE` records, the 16-record reconciliation walk, an account with
/// every debt reserve, and the liquidation preview.
/// forge-config: default.isolate = false
contract LensGasTest is LensFixture {
    uint256 internal constant BLOCK_GAS = 30_000_000;

    function setUp() public {
        _deployLens();
    }

    // TEST-247 verifies: REQ-LENS-020, REQ-LENS-014, REQ-LENS-023
    function test_TEST_247_fullRecordPageFitsTheBlock() public {
        for (uint256 i = 0; i < 200; ++i) {
            address proxy = makeAddr(string(abi.encode("gasProxy", i / 16)));
            _open(makeAddr(string(abi.encode("gasWallet", i / 16))), proxy, 1000 + i, 10e6);
        }
        uint256 g = gasleft();
        RecordBackingView[] memory r = lens.checkRecordBacking(vt, 0, 200);
        uint256 used = g - gasleft();
        assertEq(r.length, 200, "LENS_MAX_PAGE records");
        assertLt(used, BLOCK_GAS / 3, "a full page uses under a third of a block");
    }

    // TEST-247 verifies: REQ-LENS-020, REQ-LENS-011
    function test_TEST_247_sixteenRecordReconcileWalkFitsTheBlock() public {
        for (uint256 i = 1; i <= 16; ++i) {
            _open(alice, aliceProxy, i, uint128(1000e6 * i));
        }
        _borrow(aliceProxy, 100_000e18);
        _setVtPrice(0.7e8);
        _seizeAndKeep(aliceProxy, 60_000e18);
        uint256 g = gasleft();
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        uint256 used = g - gasleft();
        assertEq(r.length, 16, "every record");
        assertLt(used, 3_000_000, "the reconciliation walk is bounded by 16 records");
    }

    // TEST-247 verifies: REQ-LENS-020, REQ-LENS-010
    function test_TEST_247_accountAndPreviewsFitTheBlock() public {
        _open(alice, aliceProxy, 1, 50_000e6);
        _borrow(aliceProxy, 30_000e18);
        _borrowUsdc(aliceProxy, 9000e6);
        _setVtPrice(1.4e8);
        uint256 g = gasleft();
        lens.getAccount(alice, MARKET_ID);
        uint256 account = g - gasleft();
        g = gasleft();
        lens.previewLiquidation(aliceProxy, debtReserveId, block.timestamp);
        uint256 preview = g - gasleft();
        g = gasleft();
        lens.getTailCoverage(aave.hub, address(debt));
        uint256 tail = g - gasleft();
        assertLt(account, 2_000_000, "account with every debt reserve");
        assertLt(preview, 3_000_000, "liquidation preview");
        assertLt(tail, 2_000_000, "tail coverage over the listings");
    }
}
