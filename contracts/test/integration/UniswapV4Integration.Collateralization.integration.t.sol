// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {ClTestToken} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackUniswapV4Journeys} from "../utils/fixtures/RealStackUniswapV4Journeys.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title UniswapV4IntegrationCollateralizationIntegrationTest
/// @notice The real Uniswap v4 LPVault behind the real Collateralization, AaveAdapter, Lock and vault tokens: a pledge
/// and a withdrawal move the NFT, the record and the supply together (`TEST-010`); one Collateralization keys records,
/// totals and pending units by vault token across a Uniswap v3 and two v4 markets (`TEST-010`); tokens sent to the
/// LPVault, a pool donation and an NFT pushed to it change no record, credit or mint, and the donation is paid to the
/// depositor as fees (`TEST-016`); a position on another pool or another range is refused by the LPVault's error,
/// unchanged, with nothing recorded (`TEST-011`); a pushed NFT cannot be pledged (`TEST-252`); and the LPVault's
/// `unwind` is refused to any caller but Collateralization under the Lock (`TEST-058`).
/// forge-config: default.isolate = false
contract UniswapV4IntegrationCollateralizationIntegrationTest is RealStackUniswapV4Journeys {
    struct Snapshot {
        uint256 credited;
        uint256 totalCredited;
        uint256 supply;
        uint256 units;
        uint256 pending;
    }

    IAmmIntegration internal vault;

    function setUp() public {
        _setUpV4Journeys();
        vault = IAmmIntegration(v4Vault);
    }

    function _snapshot(
        bytes32 key
    ) internal view returns (Snapshot memory s) {
        s = Snapshot(
            _credited4(key),
            coll.getTotalCredited(vtS),
            IERC20(vtS).totalSupply(),
            vault.unitsOf(key),
            coll.getPending(vtS).units
        );
    }

    function _assertSame(
        Snapshot memory a,
        Snapshot memory b
    ) internal pure {
        assertEq(a.credited, b.credited, "credited");
        assertEq(a.totalCredited, b.totalCredited, "total credited");
        assertEq(a.supply, b.supply, "vault-token supply");
        assertEq(a.units, b.units, "LPVault units");
        assertEq(a.pending, b.pending, "pending");
    }

    // TEST-010 verifies: REQ-VAULT-167, REQ-VAULT-003, REQ-COLL-024, REQ-AMM-CORE-006, INV-005, INV-006
    function test_TEST_010_v4PledgeAndWithdrawThroughCollateralization() public {
        (bytes32 key, address proxy) = _v4PledgeUsd(alice, mS, 5000);
        assertEq(v4posm.ownerOf(uint256(key)), v4Vault, "custody");
        assertEq(vault.depositorOf(key), alice, "depositor of record");
        uint256 units = _credited4(key);
        assertEq(units, vault.unitsOf(key), "credited = the LPVault's units");
        assertEq(IERC20(vtS).totalSupply(), units, "minted = credited");
        assertEq(coll.getAccountCredited(proxy, vtS), units, "account credited");
        vm.prank(alice);
        adapterC.withdraw(mS, _ref4(key), units, _deadline(), 0);
        assertEq(v4posm.ownerOf(uint256(key)), alice, "returned");
        assertEq(vault.depositorOf(key), address(0), "no depositor");
        assertEq(coll.recordIdOf(V4, key), 0, "no record");
        assertEq(IERC20(vtS).totalSupply(), 0, "burned");
    }

    // TEST-010 verifies: REQ-COLL-030, REQ-COLL-026
    function test_TEST_010_oneCollateralizationKeysV3AndV4MarketsByVaultToken() public {
        (, address pA) = _pledgeAs(alice, mA, 3000e6);
        (bytes32 kS, address pS) = _v4PledgeUsd(alice, mS, 5000);
        (bytes32 kE, address pE) = _v4PledgeUsd(alice, mE, 5000);
        address vtA = mkt[mA].vaultToken;
        assertTrue(pA != pS && pS != pE && pA != pE, "one proxy per market");
        assertEq(coll.getTotalCredited(vtS), _credited4(kS), "v4 stable total");
        assertEq(coll.getTotalCredited(vtE), _credited4(kE), "v4 ETH total");
        assertEq(coll.getAccountCredited(pS, vtE) + coll.getAccountCredited(pE, vtS), 0, "no cross-market credit");
        assertEq(coll.getAccountCredited(pS, vtA) + coll.getAccountCredited(pA, vtS), 0, "no v3/v4 cross credit");
        assertEq(coll.getPending(vtA).units + coll.getPending(vtS).units + coll.getPending(vtE).units, 0);
        _assertBacked(vtA);
        _assertBacked(vtS);
        _assertBacked(vtE);
    }

    // TEST-016 verifies: REQ-VAULT-077, REQ-VAULT-085, REQ-VAULT-093, REQ-VAULT-152, INV-002, INV-006, ATTACK-006, REQ-AMM-V4-010
    function test_TEST_016_v4DonationsChangeNoRecordCreditOrMint() public {
        (bytes32 key,) = _v4PledgeUsd(alice, mS, 5000);
        Snapshot memory before = _snapshot(key);
        usdc.mint(v4Vault, 1e12);
        usdt.mint(v4Vault, 1e12);
        gho.mint(v4Vault, 1e24);
        // A pool donation is fees to in-range positions, never units.
        v4actor.donate(v4KeyOf[mS], 1e9, 1e9);
        // An NFT pushed with safeTransferFrom is a stray.
        address attacker_ = makeAddr("pusher");
        (int24 lower, int24 upper) = _v4FullRange(1);
        uint256 pushed = _v4Mint(attacker_, v4KeyOf[mS], lower, upper, 1e12);
        vm.prank(attacker_);
        IERC721(address(v4posm)).safeTransferFrom(attacker_, v4Vault, pushed);
        _assertSame(before, _snapshot(key));
        assertEq(coll.recordIdOf(V4, bytes32(pushed)), 0, "the pushed NFT has no record");
        assertEq(vault.depositorOf(bytes32(pushed)), address(0), "and no depositor");
        // Fees, the donation among them, go to the depositor alone; units, credit and supply stay.
        (uint256 f0, uint256 f1) = _feesOwed4(mS, key);
        assertGt(f0 + f1, 0, "the donation accrued as fees");
        (uint256 a0, uint256 a1) = _pair4(mS, alice);
        vm.prank(alice);
        adapterC.collectFees(mS, _ref4(key), _deadline());
        (uint256 b0, uint256 b1) = _pair4(mS, alice);
        assertEq(b0 - a0, f0, "token0 fees to the depositor");
        assertEq(b1 - a1, f1, "token1 fees to the depositor");
        _assertSame(before, _snapshot(key));
        assertEq(usdc.balanceOf(v4Vault), 1e12, "donated tokens stay in the LPVault");
    }

    // TEST-252 verifies: REQ-COLL-003, REQ-VAULT-103
    function test_TEST_252_v4PushedNftCannotBePledged() public {
        address pusher = makeAddr("pusher");
        (int24 lower, int24 upper) = _v4FullRange(1);
        uint256 pushed = _v4Mint(pusher, v4KeyOf[mS], lower, upper, 1e12);
        vm.prank(pusher);
        IERC721(address(v4posm)).safeTransferFrom(pusher, v4Vault, pushed);
        vm.prank(pusher);
        vm.expectRevert(ILPVaultErrors.NotTokenOwner.selector);
        adapterC.pledge(mS, _ref4(bytes32(pushed)), _deadline());
        assertEq(coll.recordIdOf(V4, bytes32(pushed)), 0, "nothing recorded");
    }

    // TEST-011 verifies: REQ-VAULT-103, REQ-VAULT-092, REQ-AMM-V4-003
    function test_TEST_011_v4PositionOnAnotherPoolOrRangeIsRefused() public {
        PoolKey memory other = v4KeyOf[mS];
        (other.fee, other.tickSpacing, other.hooks) = (500, 10, IHooks(address(0)));
        v4pm.initialize(other, 1 << 96);
        (int24 lower, int24 upper) = _v4FullRange(10);
        uint256 id = _v4Mint(alice, other, lower, upper, 1e12);
        vm.startPrank(alice);
        v4posm.approve(v4Vault, id);
        vm.expectRevert(ILPVaultErrors.PoolMismatch.selector);
        adapterC.pledge(mS, _ref4(bytes32(id)), _deadline());
        vm.stopPrank();
        assertEq(v4posm.ownerOf(id), alice, "the position stays with its owner");
        assertEq(coll.recordIdOf(V4, bytes32(id)), 0, "no record");
        uint256 narrow = _v4Mint(alice, v4KeyOf[mS], -100, 100, 1e12);
        vm.startPrank(alice);
        v4posm.approve(v4Vault, narrow);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultErrors.RangeMismatch.selector, int24(-100), int24(100)));
        adapterC.pledge(mS, _ref4(bytes32(narrow)), _deadline());
        vm.stopPrank();
        assertEq(coll.getTotalCredited(vtS), 0, "no credit");
    }

    // TEST-058 verifies: REQ-VAULT-149, REQ-VAULT-057
    function test_TEST_058_v4UnwindOnlyByCollateralizationUnderTheLock() public {
        (bytes32 key,) = _v4PledgeUsd(alice, mS, 5000);
        uint128 one = 1;
        vm.prank(makeAddr("anyone"));
        vm.expectRevert();
        vault.unwind(key, one, new uint256[](2), lpVaultSwap);
        vm.prank(address(coll));
        vm.expectRevert();
        vault.unwind(key, one, new uint256[](2), lpVaultSwap);
        assertEq(vault.unitsOf(key), _credited4(key), "nothing removed");
        ClTestToken[2] memory ts = [usdc, usdt];
        for (uint256 k = 0; k < 2; ++k) {
            assertEq(ts[k].balanceOf(lpVaultSwap), 0, "nothing paid out");
        }
    }
}
