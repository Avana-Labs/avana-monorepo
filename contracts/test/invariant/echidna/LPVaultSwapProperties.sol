// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwap} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {ILPVaultSwapLogic} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapLogic.sol";
import {LPVaultSwap} from "../../../src/liquidation/lp-vault-swap/LPVaultSwap.sol";
import {LPVaultSwapImmutables} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {LPVaultSwapLogics} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapLogics.sol";
import {
    LPVaultSwapSettlementHarness,
    LVSHarnessRegistry,
    LVSHarnessRoute,
    LVSHarnessToken
} from "../../utils/harness/LPVaultSwapSettlementHarness.sol";
import {LVSMarketRegistryMock} from "../../utils/mocks/LPVaultSwapMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice A logic-contract stand-in reporting the kind and immutables hash the implementation checks (the three real
/// logic contracts with the implementation exceed one harness's initcode limit; their bodies run in the Foundry suites).
contract LVSEchidnaLogic is ILPVaultSwapLogic {
    bytes32 internal immutable _KIND;
    bytes32 internal immutable _HASH;

    constructor(
        bytes32 kind,
        bytes32 hash
    ) {
        (_KIND, _HASH) = (kind, hash);
    }

    function logicConfig() external view returns (bytes32, bytes32) {
        return (_KIND, _HASH);
    }
}

/// @notice An account without a role, calling the keeper registry.
contract LVSEchidnaOutsider {
    function add(
        ILPVaultSwap lvs,
        address keeper
    ) external returns (bool ok) {
        (ok,) = address(lvs).call(abi.encodeWithSignature("addKeeper(address)", keeper));
    }

    function remove(
        ILPVaultSwap lvs,
        address keeper
    ) external returns (bool ok) {
        (ok,) = address(lvs).call(abi.encodeWithSignature("removeKeeper(address)", keeper));
    }
}

/// @title LPVaultSwapProperties
/// @notice Echidna and Medusa properties of LPVaultSwap (2.11): the committed-operator registry behind the real proxy
/// and implementation, with this harness as the timelock, and the shared swap-leg step on the real
/// `LPVaultSwapSettlement` code. Between transactions: the registry holds between `keeperFloor` (1) and `MAX_KEEPERS`
/// (32) entries and at least `keeperFloor` active ones; only the timelock holds the admin roles. Inside one
/// transaction: `addKeeper` succeeds exactly for a new, unfrozen keeper below the cap; `removeKeeper` exactly for a
/// registered keeper whose removal keeps the floor; an outsider changes nothing; a leg step never routes the debt asset
/// (no buy leg), routes each other token into the debt asset only, at a minimum of at least 1.
/// @dev `property_` functions run in property mode; `addKeeper`, `removeKeeper`, `freeze`, `outsider` and `legs` run in
/// assertion mode, each selecting among eight concrete keepers with `if` branches.
contract LPVaultSwapProperties {
    uint256 internal constant FLOOR = 1;
    uint256 internal constant MAX_KEEPERS = 32;

    ILPVaultSwap internal immutable LVS;
    LVSMarketRegistryMock internal immutable REGISTRY;
    LVSEchidnaOutsider internal immutable OUTSIDER;
    LPVaultSwapSettlementHarness internal immutable LEGS;
    LVSHarnessToken internal immutable USDC;
    LVSHarnessToken internal immutable USDT;
    LVSHarnessRoute internal immutable USDT_ROUTE;
    LVSHarnessRoute internal immutable USDC_ROUTE;

    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        REGISTRY = new LVSMarketRegistryMock();
        LPVaultSwapImmutables memory im = LPVaultSwapImmutables({
            lock: address(0x1001),
            aaveAdapter: address(0x1002),
            collateralization: address(0x1003),
            marketRegistry: address(REGISTRY),
            parameterStore: address(0x1005),
            payoutEscrow: address(0x1006),
            keeperFloor: FLOOR
        });
        bytes32 hash = keccak256(abi.encode(im));
        LPVaultSwapLogics memory logics = LPVaultSwapLogics({
            liquidation: address(new LVSEchidnaLogic(keccak256("LPVaultSwapLiquidationLogic"), hash)),
            pending: address(new LVSEchidnaLogic(keccak256("LPVaultSwapPendingLogic"), hash)),
            deleverage: address(new LVSEchidnaLogic(keccak256("LPVaultSwapDeleverageLogic"), hash))
        });
        address implementation = address(new LPVaultSwap(im, logics));
        address[] memory keepers = new address[](1);
        keepers[0] = _keeper(0);
        LVS = ILPVaultSwap(
            address(new ERC1967Proxy(implementation, abi.encodeCall(LPVaultSwap.initialize, (address(this), keepers))))
        );
        OUTSIDER = new LVSEchidnaOutsider();

        LVSHarnessRegistry routes = new LVSHarnessRegistry();
        USDC = new LVSHarnessToken("USDC", 6);
        USDT = new LVSHarnessToken("USDT", 6);
        LEGS = new LPVaultSwapSettlementHarness(
            LPVaultSwapImmutables({
                lock: address(0x1001),
                aaveAdapter: address(0x1002),
                collateralization: address(0x1003),
                marketRegistry: address(routes),
                parameterStore: address(0x1005),
                payoutEscrow: address(0x1006),
                keeperFloor: FLOOR
            })
        );
        USDT_ROUTE = new LVSHarnessRoute(USDT, USDC, 1, 1);
        USDC_ROUTE = new LVSHarnessRoute(USDC, USDT, 1, 1);
        routes.setRoute(address(USDT), address(USDC), address(USDT_ROUTE));
        routes.setRoute(address(USDC), address(USDT), address(USDC_ROUTE));
    }

    function _keeper(
        uint256 i
    ) internal pure returns (address) {
        return address(uint160(0xA000 + (i % 8)));
    }

    function _active() internal view returns (uint256 n) {
        for (uint256 i = 0; i < 8; ++i) {
            if (LVS.isApprovedKeeper(_keeper(i)) && !REGISTRY.isFrozenAddress(_keeper(i))) ++n;
        }
    }

    // ─── Properties ───

    function property_registryWithinFloorAndCap() external view returns (bool) {
        uint256 n = LVS.approvedKeeperCount();
        return n >= FLOOR && n <= MAX_KEEPERS && LVS.activeKeeperCount() >= FLOOR;
    }

    function property_activeCountMatchesRegistry() external view returns (bool) {
        return LVS.activeKeeperCount() == _active();
    }

    function property_onlyTimelockIsAdmin() external view returns (bool) {
        bytes32 admin = 0x00;
        IAccessControl ac = IAccessControl(address(LVS));
        return ac.hasRole(admin, address(this)) && !ac.hasRole(admin, address(OUTSIDER))
            && !ac.hasRole(admin, address(REGISTRY));
    }

    // ─── Assertion entry points ───

    function addKeeper(
        uint8 i
    ) external {
        ++sequences;
        address k = _keeper(i);
        bool expected =
            !LVS.isApprovedKeeper(k) && !REGISTRY.isFrozenAddress(k) && LVS.approvedKeeperCount() < MAX_KEEPERS;
        uint256 before = LVS.approvedKeeperCount();
        (bool ok,) = address(LVS).call(abi.encodeWithSignature("addKeeper(address)", k));
        assert(ok == expected);
        assert(LVS.approvedKeeperCount() == (ok ? before + 1 : before));
    }

    function removeKeeper(
        uint8 i
    ) external {
        ++sequences;
        address k = _keeper(i);
        uint256 active = LVS.activeKeeperCount();
        bool registered = LVS.isApprovedKeeper(k);
        uint256 activeAfter = registered && !REGISTRY.isFrozenAddress(k) ? active - 1 : active;
        bool expected = registered && activeAfter >= FLOOR;
        (bool ok,) = address(LVS).call(abi.encodeWithSignature("removeKeeper(address)", k));
        assert(ok == expected);
        if (ok) assert(!LVS.isApprovedKeeper(k) && LVS.activeKeeperCount() >= FLOOR);
    }

    function freeze(
        uint8 i,
        bool frozen
    ) external {
        ++sequences;
        address k = _keeper(i);
        // A freeze is the MarketRegistry's; it may take the active count below the floor only through the registry,
        // which PROP-071 bounds. Here it is applied only while it keeps one active keeper.
        bool was = REGISTRY.isFrozenAddress(k);
        REGISTRY.setFrozen(k, frozen);
        if (LVS.activeKeeperCount() < FLOOR) REGISTRY.setFrozen(k, was);
        assert(LVS.activeKeeperCount() >= FLOOR);
    }

    function outsider(
        uint8 i,
        bool add
    ) external {
        ++sequences;
        address k = _keeper(i);
        bool before = LVS.isApprovedKeeper(k);
        bool ok = add ? OUTSIDER.add(LVS, k) : OUTSIDER.remove(LVS, k);
        assert(!ok);
        assert(LVS.isApprovedKeeper(k) == before);
    }

    function legs(
        uint32 a0,
        uint32 a1
    ) external {
        ++sequences;
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(USDC), address(USDT));
        uint8[] memory decimals = new uint8[](2);
        (decimals[0], decimals[1]) = (6, 6);
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (1e8, 1e8);
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (a0, a1);
        USDC.mint(address(LEGS), a0);
        USDT.mint(address(LEGS), a1);
        uint256 usdcCalls = USDC_ROUTE.calls();
        uint256 usdtCalls = USDT_ROUTE.calls();
        (uint8[] memory used, uint256 recovered,) =
            LEGS.swapLegs(address(USDC), 6, tokens, decimals, prices, amounts, 100, 1e6);
        assert(USDC_ROUTE.calls() == usdcCalls);
        assert(used[0] == 0);
        if (a1 > 1) {
            assert(USDT_ROUTE.calls() == usdtCalls + 1 && USDT_ROUTE.lastMinOut() >= 1);
            assert(recovered == uint256(a0) + a1);
        } else {
            assert(recovered == a0);
        }
    }
}
