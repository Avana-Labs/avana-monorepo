// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SlipstreamIntegration} from "../../src/integrations/SlipstreamIntegration.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {ISlipstreamIntegration} from "../../src/interfaces/ISlipstreamIntegration.sol";
import {FloorCreditMath} from "../../src/libraries/FloorCreditMath.sol";
import {MockCLFactory, MockCLGauge, MockCLPool, MockSlipstreamNPM} from "../utils/mocks/SlipstreamMocks.sol";
import {MintableToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The Slipstream part on the Slipstream stand-ins: generations, the clone check on pools, pledge, partial
/// removal through `decreaseLiquidity` then a capped `collect`, fees and staked NFTs.
contract LPVaultSlipstreamUnitTest is Test {
    uint64 internal constant ADAPTER_ROLE = 11;
    int24 internal constant SPACING = 100;
    int24 internal constant BAND_LOWER = -5000;
    int24 internal constant BAND_UPPER = 5000;
    uint256 internal constant MARKET = 1;

    MockCLFactory[4] internal factories;
    MockSlipstreamNPM[4] internal npms;
    SlipstreamIntegration internal vault;
    AccessManager internal am;
    MintableToken internal t0;
    MintableToken internal t1;
    MockCLPool internal pool;

    address internal adapter = makeAddr("adapter");
    address internal user = makeAddr("user");
    address internal account = makeAddr("account");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        MintableToken a = new MintableToken("A", 18);
        MintableToken b = new MintableToken("B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        address[4] memory npmAddrs;
        address[4] memory factoryAddrs;
        for (uint256 g = 0; g < 4; ++g) {
            factories[g] = new MockCLFactory();
            npms[g] = new MockSlipstreamNPM(address(factories[g]));
            factories[g].setNft(address(npms[g]));
            (npmAddrs[g], factoryAddrs[g]) = (address(npms[g]), address(factories[g]));
        }
        pool = MockCLPool(factories[1].createPool(address(t0), address(t1), SPACING));
        am = new AccessManager(address(this));
        vault = new SlipstreamIntegration(address(am), npmAddrs, factoryAddrs);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ILPVault.pledge.selector;
        selectors[1] = ILPVault.removeLiquidity.selector;
        selectors[2] = ILPVault.release.selector;
        selectors[3] = ILPVault.collectFees.selector;
        am.setTargetFunctionRole(address(vault), selectors, ADAPTER_ROLE);
        am.grantRole(ADAPTER_ROLE, adapter, 0);
        vault.listMarket(MARKET, _word(address(pool)), BAND_LOWER, BAND_UPPER);
        vm.prank(user);
        npms[1].setApprovalForAll(address(vault), true);
    }

    function test_constructor_refusesRepeatedOrMismatchedAddresses() public {
        address[4] memory n = [address(npms[0]), address(npms[1]), address(npms[2]), address(npms[2])];
        address[4] memory f =
            [address(factories[0]), address(factories[1]), address(factories[2]), address(factories[3])];
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new SlipstreamIntegration(address(am), n, f);
        n[3] = address(npms[3]);
        (f[2], f[3]) = (f[3], f[2]);
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new SlipstreamIntegration(address(am), n, f);
    }

    /// @notice Bug hunted: a zero or code-less position manager or factory accepted at construction. The pool checks
    /// call the factory and the pledge reads the manager, so a missing contract would fail every call of its
    /// generation, or let whoever later deploys at that address answer for it.
    function test_constructor_refusesAZeroOrCodelessAddress() public {
        address[4] memory n = [address(npms[0]), address(npms[1]), address(npms[2]), address(npms[3])];
        address[4] memory f =
            [address(factories[0]), address(factories[1]), address(factories[2]), address(factories[3])];
        n[2] = address(0);
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new SlipstreamIntegration(address(am), n, f);
        n[2] = address(npms[2]);
        f[3] = makeAddr("codelessFactory");
        vm.expectRevert(ILPVault.InvalidDeployment.selector);
        new SlipstreamIntegration(address(am), n, f);
    }

    /// @notice Bug hunted: a pool word that is not a deployed contract (an EOA, or a pool address with high bits set)
    /// reaches the generation loop, where the codehash of an empty account would be compared and the dirty bits
    /// would give two market words for one pool.
    function test_listMarket_refusesAnEoaOrADirtyPoolWord() public {
        bytes32 eoa = _word(makeAddr("notAPool"));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, eoa));
        vault.listMarket(2, eoa, BAND_LOWER, BAND_UPPER);
        bytes32 dirty = bytes32(uint256(_word(address(pool))) | (uint256(1) << 200));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, dirty));
        vault.listMarket(2, dirty, BAND_LOWER, BAND_UPPER);
    }

    /// @notice Bug hunted: the codehash check taken as proof of a canonical pool. Anyone can clone the factory's pool
    /// implementation and initialize it with the real tokens; such a clone, which the factory never created or which
    /// names another manager, must not be listed, or its owner sets the price the vault reads.
    function test_listMarket_refusesACloneTheFactoryDidNotCreate() public {
        address impl = factories[1].poolImplementation();
        MockCLPool unregistered = MockCLPool(Clones.clone(impl));
        unregistered.initialize(address(factories[1]), address(t0), address(t1), SPACING, address(npms[1]), 500);
        bytes32 word = _word(address(unregistered));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, word));
        vault.listMarket(2, word, BAND_LOWER, BAND_UPPER);
        MockCLPool otherNft = MockCLPool(Clones.clone(impl));
        otherNft.initialize(address(factories[1]), address(t0), address(t1), 200, address(npms[2]), 3000);
        factories[1].register(address(t0), address(t1), 200, address(otherNft));
        word = _word(address(otherNft));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, word));
        vault.listMarket(2, word, BAND_LOWER, BAND_UPPER);
    }

    function test_generations_andKeys() public {
        assertEq(vault.generationCount(), 4);
        (address npm, address factory) = vault.generation(2);
        assertEq(npm, address(npms[2]));
        assertEq(factory, address(factories[2]));
        assertEq(vault.positionKeyOf(1, 7), bytes32((uint256(1) << 248) | 7));
        vm.expectRevert(ISlipstreamIntegration.UnsupportedNft.selector);
        vault.positionKeyOf(4, 7);
        vm.expectRevert(ISlipstreamIntegration.UnsupportedNft.selector);
        vault.generation(4);
    }

    function test_listMarket_refusesANonClonePool() public {
        MockCLPool fake = new MockCLPool();
        fake.initialize(address(factories[1]), address(t0), address(t1), SPACING, address(npms[1]), 500);
        bytes32 word = _word(address(fake));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InvalidPool.selector, word));
        vault.listMarket(2, word, BAND_LOWER, BAND_UPPER);
        assertEq(vault.getMarket(MARKET).token0, address(t0));
    }

    function test_pledge_removePartAndCollectFees() public {
        bytes32 key = _mint(-1000, 1000, 1e18);
        vm.prank(adapter);
        uint128 credit = vault.pledge(user, account, MARKET, key);
        assertEq(credit, FloorCreditMath.credit(-1000, 1000, BAND_LOWER, BAND_UPPER, 1e18));
        assertEq(npms[1].ownerOf(_id(key)), address(vault));

        npms[1].accrue(_id(key), 11, 13);
        (uint256 f0, uint256 f1) = vault.feesOf(key);
        assertEq(f0, 11);
        assertEq(f1, 13);

        vm.prank(adapter);
        (, uint256 a0, uint256 a1) = vault.removeLiquidity(key, 4e17, 0, 0, recipient);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(t0.balanceOf(recipient), a0);
        assertEq(t1.balanceOf(recipient), a1);
        // The capped collect left the fees owed to the NFT.
        (f0, f1) = vault.feesOf(key);
        assertEq(f0, 11);
        assertEq(f1, 13);

        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(adapter);
        vault.collectFees(account, keys, recipient);
        assertEq(t0.balanceOf(recipient), a0 + 11);
        assertEq(t1.balanceOf(recipient), a1 + 13);

        vm.prank(adapter);
        vault.release(key, user);
        assertEq(npms[1].ownerOf(_id(key)), user);
    }

    /// @notice Fee growth recorded outside the position's ticks (earned before the position existed, or while the price
    /// sat on the other side of a tick) is not the position's: the view counts only the growth inside, as the pool and
    /// the position manager do, so it never reports fees the collect will not pay.
    function test_feesOf_excludesGrowthOutsideTheTicks() public {
        npms[1].setTrackFees(true);
        bytes32 key = _mint(-1000, 1000, 1e18);
        vm.prank(adapter);
        vault.pledge(user, account, MARKET, key);
        uint256 q128 = uint256(1) << 128;
        pool.setFeeGrowthGlobal(3 * q128, 4 * q128);
        pool.setFeeGrowthOutside(-1000, q128, q128);
        pool.setFeeGrowthOutside(1000, q128 / 2, 2 * q128);
        (uint256 f0, uint256 f1) = vault.feesOf(key);
        assertEq(f0, 1.5e18, "token0: 3 - 1 - 0.5 per unit of liquidity");
        assertEq(f1, 1e18, "token1: 4 - 1 - 2 per unit of liquidity");

        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(adapter);
        vault.collectFees(account, keys, recipient);
        assertEq(t0.balanceOf(recipient), f0, "the collect pays what the view reported");
        assertEq(t1.balanceOf(recipient), f1);
    }

    /// @notice Fees earned before a price crosses above the position remain collectible: above the upper tick, the
    /// inside growth is upper outside minus lower outside, matching the position manager's payout.
    function test_feesOf_aboveTheUpperTickMatchesCollect() public {
        npms[1].setTrackFees(true);
        bytes32 key = _mint(-1000, 1000, 1e18);
        vm.prank(adapter);
        vault.pledge(user, account, MARKET, key);
        uint256 q128 = uint256(1) << 128;
        pool.setPrice(1500);
        pool.setFeeGrowthGlobal(3 * q128, 4 * q128);
        pool.setFeeGrowthOutside(-1000, q128, q128);
        pool.setFeeGrowthOutside(1000, q128 + q128 / 2, 3 * q128);

        (uint256 f0, uint256 f1) = vault.feesOf(key);
        assertEq(f0, 0.5e18, "token0: upper outside minus lower outside");
        assertEq(f1, 2e18, "token1: upper outside minus lower outside");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(adapter);
        vault.collectFees(account, keys, recipient);
        assertEq(t0.balanceOf(recipient), f0, "the collect pays what the view reported");
        assertEq(t1.balanceOf(recipient), f1);
    }

    function test_pledge_refusesAStakedNftAndAnUnknownGeneration() public {
        bytes32 key = _mint(-1000, 1000, 1e18);
        MockCLGauge gauge = new MockCLGauge(address(pool), npms[1], new MintableToken("AERO", 18));
        vm.startPrank(user);
        npms[1].approve(address(gauge), _id(key));
        gauge.deposit(_id(key));
        vm.stopPrank();
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotTokenOwner.selector, key));
        vault.pledge(user, account, MARKET, key);

        bytes32 unknown = bytes32((uint256(9) << 248) | 1);
        vm.prank(adapter);
        vm.expectRevert(ISlipstreamIntegration.UnsupportedNft.selector);
        vault.pledge(user, account, MARKET, unknown);
    }

    function test_pledge_refusesAnotherGenerationsPosition() public {
        uint256 id = npms[0].mint(user, address(t0), address(t1), SPACING, -1000, 1000, 1e18);
        bytes32 key = vault.positionKeyOf(0, id);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.PoolMismatch.selector, key, bytes32(0)));
        vault.pledge(user, account, MARKET, key);
    }

    /// @notice Bug hunted: a token ID the generation's manager never minted, or a position of the same tokens at
    /// another tick spacing (another pool, or none), is credited in this market.
    function test_pledge_refusesAnUnmintedIdOrAnotherSpacingsPosition() public {
        bytes32 unminted = vault.positionKeyOf(1, 999);
        vm.prank(adapter);
        vm.expectRevert(bytes("Invalid token ID"));
        vault.pledge(user, account, MARKET, unminted);

        address wide = factories[1].createPool(address(t0), address(t1), 200);
        uint256 id = npms[1].mint(user, address(t0), address(t1), 200, -1000, 1000, 1e18);
        bytes32 key = vault.positionKeyOf(1, id);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.PoolMismatch.selector, key, _word(wide)));
        vault.pledge(user, account, MARKET, key);

        id = npms[1].mint(user, address(t0), address(t1), 50, -1000, 1000, 1e18);
        key = vault.positionKeyOf(1, id);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.PoolMismatch.selector, key, bytes32(0)));
        vault.pledge(user, account, MARKET, key);
    }

    /// @notice Bug hunted: once pledged, the former owner stakes the NFT in the gauge or transfers it away, leaving a
    /// record without custody.
    function test_pledgedNft_cannotBeStakedOrTransferredByTheFormerOwner() public {
        bytes32 key = _mint(-1000, 1000, 1e18);
        vm.prank(adapter);
        vault.pledge(user, account, MARKET, key);
        MockCLGauge gauge = new MockCLGauge(address(pool), npms[1], new MintableToken("AERO", 18));
        vm.startPrank(user);
        vm.expectRevert();
        gauge.deposit(_id(key));
        vm.expectRevert();
        npms[1].transferFrom(address(vault), user, _id(key));
        vm.stopPrank();
        assertEq(npms[1].ownerOf(_id(key)), address(vault));
        assertEq(vault.getPosition(key).account, account);
    }

    /// @notice Bug hunted: `increaseLiquidity` called straight on Slipstream's manager for a pledged NFT (it lets
    /// anyone) inflates the credit, or an unwind takes the added liquidity. The record does not move, an unwind of all
    /// the credit removes only the record's liquidity, and the release returns the NFT with the rest.
    function test_directIncreaseLiquidity_isNotCreditedAndStaysWithTheNft() public {
        bytes4[] memory unwind = new bytes4[](1);
        unwind[0] = ILPVault.unwind.selector;
        am.setTargetFunctionRole(address(vault), unwind, ADAPTER_ROLE);
        bytes32 key = _mint(-1000, 1000, 1e18);
        vm.prank(adapter);
        uint128 credit = vault.pledge(user, account, MARKET, key);
        vm.prank(makeAddr("stranger"));
        npms[1].increaseLiquidity(_id(key), 5e17);
        ILPVault.Position memory p = vault.getPosition(key);
        assertEq(p.liquidity, 1e18);
        assertEq(p.credit, credit);
        assertEq(vault.previewCredit(MARKET, key), FloorCreditMath.credit(-1000, 1000, BAND_LOWER, BAND_UPPER, 1.5e18));
        assertEq(vault.getMarket(MARKET).totalCredit, credit);
        vm.prank(adapter);
        vault.unwind(key, type(uint128).max, 0, 0, recipient);
        (,,, uint128 live) = vault.positionInfo(key);
        assertEq(live, 5e17);
        assertEq(vault.getMarket(MARKET).totalCredit, 0);
        vm.prank(adapter);
        vault.release(key, user);
        assertEq(npms[1].ownerOf(_id(key)), user);
        (,,, live) = vault.positionInfo(key);
        assertEq(live, 5e17);
    }

    function _mint(
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal returns (bytes32) {
        uint256 id = npms[1].mint(user, address(t0), address(t1), SPACING, lower, upper, liquidity);
        return vault.positionKeyOf(1, id);
    }

    function _id(
        bytes32 key
    ) internal pure returns (uint256) {
        return uint256(key) & ((uint256(1) << 248) - 1);
    }

    function _word(
        address a
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
