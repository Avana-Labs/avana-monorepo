// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../src/vault/interfaces/ILPVault.sol";
import {FloorCreditMath} from "../../src/vault/libraries/FloorCreditMath.sol";
import {LPVaultTestBase} from "../unit/LPVault.unit.t.sol";
import {LPVaultTestToken, MockLPVault, MockPositionManager} from "../utils/mocks/LPVaultMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Drives pledges, top-ups, partial removals, unwinds, releases and fee collection over two markets and three
/// accounts, and tracks every key it pledged.
contract LPVaultCreditHandler is Test {
    MockLPVault internal immutable VAULT;
    MockPositionManager internal immutable PM;
    LPVaultTestToken internal immutable TOKEN0;
    LPVaultTestToken internal immutable TOKEN1;
    address internal immutable ADAPTER;
    address internal immutable LIQUIDATOR;
    address internal immutable USER;
    bytes32[2] internal pools;

    address[3] public accounts = [address(0xA1), address(0xA2), address(0xA3)];
    bytes32[] public keys;
    uint256 public calls;

    constructor(
        MockLPVault vault,
        address adapter,
        address liquidator,
        address user,
        bytes32 poolA,
        bytes32 poolB
    ) {
        VAULT = vault;
        PM = vault.PM();
        TOKEN0 = LPVaultTestToken(address(PM.TOKEN0()));
        TOKEN1 = LPVaultTestToken(address(PM.TOKEN1()));
        (ADAPTER, LIQUIDATOR, USER) = (adapter, liquidator, user);
        pools = [poolA, poolB];
        vm.startPrank(user);
        TOKEN0.approve(address(vault), type(uint256).max);
        TOKEN1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    function pledge(
        uint256 accountSeed,
        uint256 marketSeed,
        int24 lowerSeed,
        int24 width,
        uint128 liquidity
    ) external {
        address account = accounts[accountSeed % 3];
        if (VAULT.positionsOf(account).length >= 16) return;
        uint256 marketId = 1 + (marketSeed % 2);
        int24 lower = int24(bound(lowerSeed, -1000, 990));
        int24 upper = int24(bound(width, int256(lower) + 1, 1000));
        liquidity = uint128(bound(liquidity, 1e6, 1e30));
        uint256 tokenId = PM.mint(USER, pools[marketId - 1], lower, upper, liquidity);
        vm.prank(ADAPTER);
        try VAULT.pledge(USER, account, marketId, bytes32(tokenId)) {
            keys.push(bytes32(tokenId));
        } catch {}
        ++calls;
    }

    function addLiquidity(
        uint256 keySeed,
        uint256 amount
    ) external {
        bytes32 key = _open(keySeed);
        if (key == bytes32(0)) return;
        amount = bound(amount, 1, 1e30);
        TOKEN0.mint(USER, amount);
        TOKEN1.mint(USER, amount);
        vm.prank(ADAPTER);
        VAULT.addLiquidity(key, USER, amount, amount, 0, 0);
        ++calls;
    }

    function removeLiquidity(
        uint256 keySeed,
        uint256 fraction
    ) external {
        bytes32 key = _open(keySeed);
        if (key == bytes32(0)) return;
        uint128 l = VAULT.getPosition(key).liquidity;
        if (l == 0) return;
        uint128 amount = uint128(bound(fraction, 1, l));
        vm.prank(ADAPTER);
        VAULT.removeLiquidity(key, amount, 0, 0, address(0xBEEF));
        ++calls;
    }

    function unwind(
        uint256 keySeed,
        uint256 credit
    ) external {
        bytes32 key = _open(keySeed);
        if (key == bytes32(0)) return;
        uint128 c = VAULT.getPosition(key).credit;
        if (c == 0) return;
        vm.prank(LIQUIDATOR);
        VAULT.unwind(key, uint128(bound(credit, 1, uint256(c) * 2)), 0, 0, address(0xD00D));
        ++calls;
    }

    function release(
        uint256 keySeed
    ) external {
        bytes32 key = _open(keySeed);
        if (key == bytes32(0)) return;
        vm.prank(ADAPTER);
        VAULT.release(key, USER);
        ++calls;
    }

    function accrueAndCollect(
        uint256 keySeed,
        uint64 fee0,
        uint64 fee1
    ) external {
        bytes32 key = _open(keySeed);
        if (key == bytes32(0)) return;
        PM.accrue(uint256(key), fee0, fee1);
        bytes32[] memory one = new bytes32[](1);
        one[0] = key;
        vm.prank(ADAPTER);
        VAULT.collectFees(VAULT.getPosition(key).account, one, address(0xFEE));
        ++calls;
    }

    function _open(
        uint256 seed
    ) internal view returns (bytes32) {
        uint256 n = keys.length;
        if (n == 0) return bytes32(0);
        for (uint256 i = 0; i < n; ++i) {
            bytes32 key = keys[(seed + i) % n];
            if (VAULT.getPosition(key).account != address(0)) return key;
        }
        return bytes32(0);
    }
}

/// @notice The sum of the records' credit is the markets' total credit, every record's credit stays within the floor
/// credit of its liquidity, and the account lists hold exactly the open records.
contract LPVaultCreditInvariantTest is LPVaultTestBase {
    LPVaultCreditHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LPVaultCreditHandler(vault, adapter, liquidator, user, POOL, POOL_B);
        vm.prank(user);
        pm.setApprovalForAll(address(vault), true);
        targetContract(address(handler));
    }

    function invariant_sumOfRecordCreditIsMarketCredit() public view {
        uint256[3] memory sums;
        uint256 n = handler.keyCount();
        for (uint256 i = 0; i < n; ++i) {
            ILPVault.Position memory p = vault.getPosition(handler.keys(i));
            if (p.account == address(0)) continue;
            sums[p.marketId] += p.credit;
        }
        assertEq(vault.getMarket(MARKET).totalCredit, sums[1], "market 1");
        assertEq(vault.getMarket(MARKET_B).totalCredit, sums[2], "market 2");
    }

    function invariant_accountCreditAddsUpToMarketCredit() public view {
        for (uint256 m = 1; m <= 2; ++m) {
            uint256 total;
            for (uint256 a = 0; a < 3; ++a) {
                total += vault.accountCredit(handler.accounts(a), m);
            }
            assertEq(total, vault.getMarket(m).totalCredit);
        }
    }

    function invariant_recordCreditWithinFloor() public view {
        uint256 n = handler.keyCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 key = handler.keys(i);
            ILPVault.Position memory p = vault.getPosition(key);
            if (p.account == address(0)) continue;
            (, int24 lower, int24 upper,,,) = pm.pos(uint256(key));
            uint128 floor = lower == BAND_LOWER && upper == BAND_UPPER
                ? p.liquidity
                : FloorCreditMath.credit(lower, upper, BAND_LOWER, BAND_UPPER, p.liquidity);
            assertLe(p.credit, floor);
            (,,, uint128 live,,) = pm.pos(uint256(key));
            assertGe(live, p.liquidity);
        }
    }

    function invariant_accountListsHoldTheOpenRecords() public view {
        uint256 listed;
        for (uint256 a = 0; a < 3; ++a) {
            bytes32[] memory list = vault.positionsOf(handler.accounts(a));
            assertLe(list.length, 16);
            for (uint256 i = 0; i < list.length; ++i) {
                assertEq(vault.getPosition(list[i]).account, handler.accounts(a));
            }
            listed += list.length;
        }
        uint256 open;
        uint256 n = handler.keyCount();
        for (uint256 i = 0; i < n; ++i) {
            if (vault.getPosition(handler.keys(i)).account != address(0)) ++open;
        }
        assertEq(listed, open);
    }

    function invariant_holdsNoTokens() public view {
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
    }
}
