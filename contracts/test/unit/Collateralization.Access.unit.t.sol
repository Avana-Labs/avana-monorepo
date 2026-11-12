// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";

/// @title CollateralizationAccessUnitTest
/// @notice The caller and Lock matrix of every Collateralization entry point and view on the real Lock: three Lock
/// states (free, held by the AaveAdapter, held by LPVaultSwap) by five callers (a stranger, the AaveAdapter,
/// LPVaultSwap, the market's LPVault and the vault token, the two contracts Collateralization calls mid-operation), with
/// the exact revert data of every refused cell and of the first check past the gate in every admitted cell.
/// forge-config: default.isolate = false
contract CollateralizationAccessUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));

    uint8 internal constant FREE = 0;
    uint8 internal constant ADAPTER_HOLDS = 1;
    uint8 internal constant SWAP_HOLDS = 2;

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deployCollateralization();
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
    }

    // TEST-060 verifies: REQ-VAULT-091, REQ-VAULT-125, REQ-VAULT-128, REQ-VAULT-145, REQ-COLL-018, REQ-LOCK-016, ATTACK-093
    // Sources: 2.3 REQ-VAULT-091 (holder-only reads under the Lock), 2.16 REQ-LOCK-016
    /// @notice The fourteen ledger views answer every caller while the Lock is free and only the holder while it is
    /// held: the LPVault and the vault token, which run inside a held Lock, read `Locked` like a stranger.
    function test_TEST_060_ledgerViewMatrix() public {
        bytes[] memory views = _ledgerViews();
        address[5] memory callers = [stranger, adapter, lpVaultSwap, address(lpVault), vt];
        for (uint8 state = FREE; state <= SWAP_HOLDS; ++state) {
            _enter(state);
            address holder = lock.holder();
            for (uint256 v = 0; v < views.length; ++v) {
                for (uint256 c = 0; c < callers.length; ++c) {
                    bool admitted = holder == address(0) || callers[c] == holder;
                    vm.prank(callers[c]);
                    (bool ok, bytes memory ret) = address(coll).staticcall(views[v]);
                    assertEq(ok, admitted, "view admission");
                    if (!admitted) assertEq(ret, abi.encodeWithSelector(ICollateralizationErrors.Locked.selector));
                }
            }
            _exit(state);
        }
    }

    // TEST-236 verifies: REQ-COLL-018, REQ-VAULT-091, REQ-LOCK-016, Q-253, Q-383
    // Sources: 2.3 REQ-COLL-018 (the RiskModule reads both inside the Adapter's borrow)
    /// @notice `getAccountRescueUnits` and `poolUnits` answer every caller while the Lock is free or held by the
    /// AaveAdapter, and refuse every caller, LPVaultSwap included, while LPVaultSwap holds it.
    function test_TEST_236_adapterReadableViewMatrix() public {
        bytes32 poolKey = keccak256(abi.encode(INTEGRATION, pool, bytes32(0)));
        bytes[2] memory views =
            [abi.encodeCall(coll.getAccountRescueUnits, (aliceProxy, vt)), abi.encodeCall(coll.poolUnits, (poolKey))];
        address[5] memory callers = [stranger, adapter, lpVaultSwap, address(lpVault), vt];
        for (uint8 state = FREE; state <= SWAP_HOLDS; ++state) {
            _enter(state);
            for (uint256 v = 0; v < views.length; ++v) {
                for (uint256 c = 0; c < callers.length; ++c) {
                    vm.prank(callers[c]);
                    (bool ok, bytes memory ret) = address(coll).staticcall(views[v]);
                    assertEq(ok, state != SWAP_HOLDS, "rescue-view admission");
                    if (ok) {
                        assertEq(abi.decode(ret, (uint256)), v == 0 ? 0 : 5_000_000_000, "value");
                    } else {
                        assertEq(ret, abi.encodeWithSelector(ICollateralizationErrors.Locked.selector));
                    }
                }
            }
            _exit(state);
        }
    }

    // TEST-108 verifies: REQ-COLL-001, REQ-COLL-002, REQ-VAULT-086
    // Sources: 2.3 REQ-COLL-002 (immutable wiring readable by anyone)
    /// @notice The immutable getters answer every caller in every Lock state with the constructor's addresses.
    function test_TEST_108_immutableGettersAlwaysAnswer() public {
        address[5] memory callers = [stranger, adapter, lpVaultSwap, address(lpVault), vt];
        for (uint8 state = FREE; state <= SWAP_HOLDS; ++state) {
            _enter(state);
            for (uint256 c = 0; c < callers.length; ++c) {
                vm.startPrank(callers[c]);
                assertEq(coll.ADAPTER(), adapter);
                assertEq(coll.LP_VAULT_SWAP(), lpVaultSwap);
                assertEq(coll.RISK_MODULE(), address(riskModule));
                assertEq(coll.LOCK(), address(lock));
                assertEq(coll.VAULT_TOKEN_FACTORY(), address(factory));
                vm.stopPrank();
            }
            _exit(state);
        }
    }

    // TEST-060 verifies: REQ-VAULT-006, REQ-VAULT-068, REQ-VAULT-112, REQ-VAULT-113, REQ-COLL-039, REQ-LOCK-010, REQ-LOCK-023, INV-054, ATTACK-169
    // Sources: 5.1 TEST-060 (Collateralization side), 2.16 REQ-LOCK-010
    /// @notice The eight AaveAdapter entry points in every Lock state for every caller: `NotAdapter` for any caller
    /// but the AaveAdapter whatever the Lock, `LockNotHeld` for the AaveAdapter unless it holds the Lock, and, in the one
    /// admitted cell, the first check past the gate (no record for the position, an unregistered proxy).
    function test_TEST_060_adapterEntryPointMatrix() public {
        bytes32 none = bytes32(uint256(777));
        bytes[8] memory calls = [
            abi.encodeCall(coll.pledge, (bob, bobProxy, vt, none, false)),
            abi.encodeCall(coll.release, (aliceProxy, vt, none, 1)),
            abi.encodeCall(coll.releasePartial, (aliceProxy, vt, none, 1, new uint256[](2))),
            abi.encodeCall(coll.recredit, (alice, aliceProxy, vt, none, "", false)),
            abi.encodeCall(coll.releaseForDeleverage, (aliceProxy, vt, none, 1, new uint256[](2))),
            abi.encodeCall(coll.releaseZeroCredit, (alice, vt, none)),
            abi.encodeCall(coll.collectFees, (alice, vt, none)),
            abi.encodeCall(coll.markIndebted, (bobProxy))
        ];
        bytes[8] memory admitted = [
            abi.encodeWithSelector(ICollateralizationErrors.UnknownProxy.selector, bobProxy),
            abi.encodeWithSelector(ICollateralizationErrors.RecordNotFound.selector),
            abi.encodeWithSelector(ICollateralizationErrors.RecordNotFound.selector),
            abi.encodeWithSelector(ICollateralizationErrors.RecordNotFound.selector),
            abi.encodeWithSelector(ICollateralizationErrors.RecordNotFound.selector),
            abi.encodeWithSelector(ICollateralizationErrors.RecordNotFound.selector),
            abi.encodeWithSelector(ICollateralizationErrors.RecordNotFound.selector),
            abi.encodeWithSelector(ICollateralizationErrors.UnknownProxy.selector, bobProxy)
        ];
        address[4] memory callers = [stranger, adapter, lpVaultSwap, address(lpVault)];
        for (uint8 state = FREE; state <= SWAP_HOLDS; ++state) {
            _enter(state);
            for (uint256 i = 0; i < calls.length; ++i) {
                for (uint256 c = 0; c < callers.length; ++c) {
                    bytes memory expected;
                    if (callers[c] != adapter) {
                        expected = abi.encodeWithSelector(ICollateralizationErrors.NotAdapter.selector);
                    } else if (state != ADAPTER_HOLDS) {
                        expected = abi.encodeWithSelector(ICollateralizationErrors.LockNotHeld.selector);
                    } else {
                        expected = admitted[i];
                    }
                    _expectFail(callers[c], calls[i], expected);
                }
            }
            _exit(state);
        }
    }

    // TEST-152 verifies: REQ-VAULT-046, REQ-VAULT-050, REQ-VAULT-113, REQ-VAULT-115, REQ-VAULT-138, REQ-LOCK-010, REQ-LOCK-023
    // Sources: 5.1 TEST-152 (caller and Lock), 2.3 REQ-VAULT-138
    /// @notice The three LPVaultSwap entry points in every Lock state for every caller: `NotLPVaultSwap` for any
    /// caller but LPVaultSwap whatever the Lock, `LockNotHeld` for LPVaultSwap unless it holds the Lock, and, admitted,
    /// the first check past the gate (an unregistered proxy, no snapshot, no pending units).
    function test_TEST_152_lpVaultSwapEntryPointMatrix() public {
        bytes[3] memory calls = [
            abi.encodeCall(coll.beginSeizure, (bobProxy, vt)),
            abi.encodeCall(coll.settleSeizure, (aliceProxy, vt, 0, new uint256[](2))),
            abi.encodeCall(coll.settlePending, (vt, 1))
        ];
        bytes[3] memory admitted = [
            abi.encodeWithSelector(ICollateralizationErrors.UnknownProxy.selector, bobProxy),
            abi.encodeWithSelector(ICollateralizationErrors.SeizureMismatch.selector),
            abi.encodeWithSelector(ICollateralizationErrors.PendingExceeded.selector)
        ];
        address[4] memory callers = [stranger, adapter, lpVaultSwap, address(lpVault)];
        for (uint8 state = FREE; state <= SWAP_HOLDS; ++state) {
            _enter(state);
            for (uint256 i = 0; i < calls.length; ++i) {
                for (uint256 c = 0; c < callers.length; ++c) {
                    bytes memory expected;
                    if (callers[c] != lpVaultSwap) {
                        expected = abi.encodeWithSelector(ICollateralizationErrors.NotLPVaultSwap.selector);
                    } else if (state != SWAP_HOLDS) {
                        expected = abi.encodeWithSelector(ICollateralizationErrors.LockNotHeld.selector);
                    } else {
                        expected = admitted[i];
                    }
                    _expectFail(callers[c], calls[i], expected);
                }
            }
            _exit(state);
        }
    }

    // TEST-272 verifies: REQ-COLL-040, REQ-LOCK-010
    // Sources: 2.3 REQ-COLL-040 (Adapter or LPVaultSwap holding the Lock)
    /// @notice `markDebtFree` in every Lock state for every caller: `NotAdapter` for anyone but the two members,
    /// `LockNotHeld` for a member that does not hold the Lock, and for the holding member a call that returns.
    function test_TEST_272_markDebtFreeMatrix() public {
        bytes memory call = abi.encodeCall(coll.markDebtFree, (aliceProxy));
        address[4] memory callers = [stranger, adapter, lpVaultSwap, address(lpVault)];
        for (uint8 state = FREE; state <= SWAP_HOLDS; ++state) {
            _enter(state);
            address holder = lock.holder();
            for (uint256 c = 0; c < callers.length; ++c) {
                address caller = callers[c];
                if (caller != adapter && caller != lpVaultSwap) {
                    _expectFail(caller, call, abi.encodeWithSelector(ICollateralizationErrors.NotAdapter.selector));
                } else if (caller != holder) {
                    _expectFail(caller, call, abi.encodeWithSelector(ICollateralizationErrors.LockNotHeld.selector));
                } else {
                    vm.prank(caller);
                    (bool ok,) = address(coll).call(call);
                    assertTrue(ok, "the holding member is admitted");
                }
            }
            _exit(state);
        }
    }

    // TEST-108 verifies: REQ-COLL-001, REQ-COLL-002
    // Sources: 2.3 REQ-COLL-002 (five distinct, non-zero immutables)
    /// @notice The constructor refuses each of the five addresses at zero and each of the ten pairs set equal, with
    /// `InvalidImmutable()`, and deploys with five distinct addresses.
    function test_TEST_108_constructorRefusesEveryZeroAndEveryEqualPair() public {
        address[5] memory good =
            [makeAddr("c-adapter"), makeAddr("c-swap"), makeAddr("c-risk"), makeAddr("c-lock"), makeAddr("c-factory")];
        bytes memory refusal = abi.encodeWithSignature("InvalidImmutable()");
        for (uint256 z = 0; z < 5; ++z) {
            address[5] memory args = _copy(good);
            args[z] = address(0);
            (address deployed, bytes memory ret) = _create(args);
            assertEq(deployed, address(0), "zero address accepted");
            assertEq(ret, refusal, "zero address refusal");
        }
        uint256 pairs = 0;
        for (uint256 a = 0; a < 5; ++a) {
            for (uint256 b = a + 1; b < 5; ++b) {
                address[5] memory args = _copy(good);
                args[b] = args[a];
                (address deployed, bytes memory ret) = _create(args);
                assertEq(deployed, address(0), "equal pair accepted");
                assertEq(ret, refusal, "equal pair refusal");
                ++pairs;
            }
        }
        assertEq(pairs, 10);
        (address ok,) = _create(good);
        assertTrue(ok != address(0), "five distinct addresses deploy");
        ICollateralizationViewsLite d = ICollateralizationViewsLite(ok);
        assertEq(d.ADAPTER(), good[0]);
        assertEq(d.LP_VAULT_SWAP(), good[1]);
        assertEq(d.RISK_MODULE(), good[2]);
        assertEq(d.LOCK(), good[3]);
        assertEq(d.VAULT_TOKEN_FACTORY(), good[4]);
    }

    // ─── Helpers ───

    function _ledgerViews() internal view returns (bytes[] memory views) {
        views = new bytes[](14);
        views[0] = abi.encodeCall(coll.getRecord, (1));
        views[1] = abi.encodeCall(coll.recordIdOf, (INTEGRATION, KEY42));
        views[2] = abi.encodeCall(coll.nextRecordId, ());
        views[3] = abi.encodeCall(coll.getAccountRecords, (aliceProxy, vt, 0, 16));
        views[4] = abi.encodeCall(coll.getOpenRecordCount, (aliceProxy, vt));
        views[5] = abi.encodeCall(coll.getAccountCredited, (aliceProxy, vt));
        views[6] = abi.encodeCall(coll.getTotalCredited, (vt));
        views[7] = abi.encodeCall(coll.getPending, (vt));
        views[8] = abi.encodeCall(coll.getMarketRecords, (vt, 0, 10));
        views[9] = abi.encodeCall(coll.getMarketRecordCount, (vt));
        views[10] = abi.encodeCall(coll.getMarketDebtFree, (vt));
        views[11] = abi.encodeCall(coll.getCounters, (vt, alice));
        views[12] = abi.encodeCall(coll.previewRelease, (INTEGRATION, KEY42));
        views[13] = abi.encodeCall(coll.previewRecredit, (INTEGRATION, KEY42));
    }

    function _enter(
        uint8 state
    ) internal {
        if (state == ADAPTER_HOLDS) {
            vm.prank(adapter);
            lock.acquire();
        } else if (state == SWAP_HOLDS) {
            vm.prank(lpVaultSwap);
            lock.acquire();
        }
    }

    function _exit(
        uint8 state
    ) internal {
        if (state == ADAPTER_HOLDS) {
            vm.prank(adapter);
            lock.release();
        } else if (state == SWAP_HOLDS) {
            vm.prank(lpVaultSwap);
            lock.release();
        }
    }

    function _expectFail(
        address caller,
        bytes memory data,
        bytes memory err
    ) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(coll).call(data);
        assertFalse(ok, "call succeeded");
        assertEq(ret, err, "revert data");
    }

    /// @dev A fresh copy: assigning a memory array aliases it.
    function _copy(
        address[5] memory a
    ) internal pure returns (address[5] memory b) {
        for (uint256 i = 0; i < 5; ++i) {
            b[i] = a[i];
        }
    }

    function _create(
        address[5] memory args
    ) internal returns (address deployed, bytes memory ret) {
        bytes memory init = bytes.concat(
            vm.getCode("Collateralization.sol:Collateralization"),
            abi.encode(args[0], args[1], args[2], args[3], args[4])
        );
        assembly ("memory-safe") {
            deployed := create(0, add(init, 0x20), mload(init))
        }
        if (deployed == address(0)) {
            assembly ("memory-safe") {
                ret := mload(0x40)
                mstore(ret, returndatasize())
                returndatacopy(add(ret, 0x20), 0, returndatasize())
                mstore(0x40, add(add(ret, 0x20), returndatasize()))
            }
        }
    }
}

interface ICollateralizationViewsLite {
    function ADAPTER() external view returns (address);
    function LP_VAULT_SWAP() external view returns (address);
    function RISK_MODULE() external view returns (address);
    function LOCK() external view returns (address);
    function VAULT_TOKEN_FACTORY() external view returns (address);
}
