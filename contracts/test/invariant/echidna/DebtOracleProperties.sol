// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";
import {DebtOracle} from "../../../src/oracle/debt-oracle/DebtOracle.sol";
import {DebtOracleInitParams} from "../../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {DebtPriceView} from "../../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {DebtRegistryMock, DebtStoreMock} from "../../utils/mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../../utils/mocks/MockAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DebtOracleProperties
/// @notice Echidna and Medusa properties of the DebtOracle (2.10). The harness is the oracle's timelock and drives a
/// one-leg primary, a one-leg alternate and a standby feed through moves, bounds, outages and hostile reads while the
/// fuzzers advance time. Between transactions: the served price is at least 1 and never reverts; a DebtOracle that is
/// not Live serves at least its accepted price, exactly it when Cached and the stress price when Expired; `decimals()`
/// is 8; only the harness holds an admin role. Inside one transaction: a poke with enough gas never reverts and never
/// moves the accepted timestamp backwards; a feed move or switch leaves a positive served price; an admin grant to
/// anyone but the timelock reverts.
/// @dev `property_` functions run in property mode; `move`, `breakFeed`, `switchStandby`, `pokeChecked` and
/// `grantAdmin` run in assertion mode, each selecting among concrete cases with `if` branches.
contract DebtOracleProperties {
    address internal constant ASSET = address(0xA55E7);
    uint256 internal constant A_SEED = 99_990_000;

    DebtOracle internal immutable ORACLE;
    DebtRegistryMock internal immutable REG;
    DebtStoreMock internal immutable STORE;
    MockAggregator internal immutable P;
    MockAggregator internal immutable B;
    MockAggregator internal immutable S;

    /// @notice Accepted timestamp after the last checked poke.
    uint64 public lastAcceptedAt;

    constructor() {
        P = new MockAggregator(8, int256(A_SEED), block.timestamp);
        B = new MockAggregator(8, int256(A_SEED), block.timestamp);
        S = new MockAggregator(8, 99_995_000, block.timestamp);
        MockAggregator second = new MockAggregator(8, int256(A_SEED), block.timestamp);
        REG = new DebtRegistryMock();
        STORE = new DebtStoreMock();
        address[] memory p = new address[](1);
        address[] memory b = new address[](1);
        address[] memory s = new address[](1);
        (p[0], b[0], s[0]) = (address(P), address(B), address(S));
        REG.list(ASSET, p, b, s);
        STORE.setFeed(address(P), 8, 0, 1e12, 86_400, 1800);
        STORE.setFeed(address(B), 8, 0, 1e12, 3600, 1800);
        STORE.setFeed(address(S), 8, 0, 1e12, 86_400, 1800);
        STORE.setFeed(address(second), 8, 0, 1e12, 86_400, 1800);
        STORE.setTolerance(ASSET, 225);
        STORE.setStressRise(ASSET, 500);
        STORE.setSecondSource(
            ASSET,
            SecondSource({
                kind: SecondSourceKind.OracleNetwork,
                source: address(second),
                poolRef: bytes32(0),
                maxAge: 88_200,
                twapWindow: 0,
                toleranceBps: 100
            })
        );
        DebtOracle impl = new DebtOracle(address(this));
        DebtOracleInitParams memory params = DebtOracleInitParams({
            timelock: address(this),
            asset: ASSET,
            marketRegistry: address(REG),
            parameterStore: address(STORE),
            description: "USDC / USD",
            pokeMinGas: 600_000
        });
        ORACLE = DebtOracle(address(new ERC1967Proxy(address(impl), abi.encodeCall(DebtOracle.initialize, (params)))));
        (, lastAcceptedAt) = ORACLE.lastAcceptedPrice();
    }

    function _feed(
        uint8 which
    ) internal view returns (MockAggregator) {
        if (which % 3 == 0) return P;
        if (which % 3 == 1) return B;
        return S;
    }

    function _served() internal view returns (bool ok, uint256 served) {
        try ORACLE.latestAnswer{gas: 3_000_000}() returns (int256 a) {
            return (a >= 1, a >= 1 ? uint256(a) : 0);
        } catch {
            return (false, 0);
        }
    }

    function _accepted() internal view returns (uint256 price8) {
        (price8,) = ORACLE.lastAcceptedPrice();
    }

    // ─── Properties (between transactions) ───

    function property_servedAtLeastOneAndNeverReverts() external view returns (bool) {
        (bool ok,) = _served();
        return ok;
    }

    function property_nonLiveServesAtLeastAccepted() external view returns (bool) {
        DebtPriceView memory v = ORACLE.getPriceState{gas: 3_000_000}();
        uint256 a = _accepted();
        uint256 served = uint256(v.answer);
        if (v.state == PriceState.Live) return served == v.quote;
        if (v.state == PriceState.Cached) return served == a;
        if (v.state == PriceState.Expired) return served == (a * 10_500 + 9999) / 10_000;
        uint256 m = v.primaryValue > v.alternateValue ? v.primaryValue : v.alternateValue;
        return served == (m > a ? m : a) && v.liquidationPaused;
    }

    function property_decimalsEight() external view returns (bool) {
        return ORACLE.decimals() == 8;
    }

    function property_adminRolesOnlyTimelock() external view returns (bool) {
        bytes32 admin = AvanaRoles.APPLICATION_ADMIN;
        return ORACLE.hasRole(admin, address(this)) && !ORACLE.hasRole(admin, address(P))
            && !ORACLE.hasRole(bytes32(0), address(REG)) && ORACLE.TIMELOCK() == address(this);
    }

    // ─── Assertion entry points ───

    /// @notice A new round on one feed: honest, ±50 %, zero, negative, at the maximum, old or in the future.
    function move(
        uint8 which,
        uint8 kind
    ) external {
        MockAggregator f = _feed(which);
        uint256 k = kind % 7;
        int256 v = int256(A_SEED);
        if (k == 0) f.push(v, block.timestamp);
        else if (k == 1) f.push(v + v / 2, block.timestamp);
        else if (k == 2) f.push(v - v / 2, block.timestamp);
        else if (k == 3) f.push(0, block.timestamp);
        else if (k == 4) f.push(-v, block.timestamp);
        else if (k == 5) f.push(1e12, block.timestamp);
        else f.push(v, block.timestamp + 1);
        (bool ok,) = _served();
        assert(ok);
    }

    function breakFeed(
        uint8 which,
        uint8 mode
    ) external {
        MockAggregator f = _feed(which);
        f.setMode(f.latestRoundData.selector, MockAggregator.Mode(mode % 6));
        (bool ok,) = _served();
        assert(ok);
    }

    function switchStandby(
        bool alternate
    ) external {
        if (REG.replaced(ASSET) == RouteSlot.None) {
            REG.useStandby(ASSET, alternate ? RouteSlot.Alternate : RouteSlot.Primary);
        } else {
            REG.restore(ASSET);
        }
        (bool ok,) = _served();
        assert(ok);
    }

    function pokeChecked() external {
        bool done;
        try ORACLE.poke{gas: 5_000_000}() returns (PriceState) {
            done = true;
        } catch {}
        assert(done);
        (, uint64 at) = ORACLE.lastAcceptedPrice();
        assert(at >= lastAcceptedAt);
        assert(at <= block.timestamp);
        lastAcceptedAt = at;
    }

    function grantAdmin(
        uint8 who
    ) external {
        address candidate = who % 2 == 0 ? address(P) : address(this);
        bytes32 admin = AvanaRoles.APPLICATION_ADMIN;
        bool granted;
        try ORACLE.grantRole(admin, candidate) {
            granted = true;
        } catch {}
        assert(granted == (candidate == address(this)));
    }
}
