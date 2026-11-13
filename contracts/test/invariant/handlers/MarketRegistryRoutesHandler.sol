// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryFixture} from "../../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryRouteMock} from "../../utils/mocks/MarketRegistryMocks.sol";

/// @title MarketRegistryRoutesHandler
/// @notice Route handler of the market-registry suite: on the USDC -> GHO slots of one market it sets, disables and
/// restores routes drawn from eight candidate contracts over four venues (each candidate names one or two venues), by
/// the timelock and by a guardian. A model of REQ-CONFIG-060, REQ-CONFIG-061 and REQ-CONFIG-062 predicts each outcome
/// and the two slot records; ghosts count every departure.
contract MarketRegistryRoutesHandler is MarketRegistryFixture {
    uint256 public constant CANDIDATES = 8;

    struct Rec {
        address route;
        bool active;
    }

    uint256 public marketId;
    address[CANDIDATES] internal _cands;
    Rec[2] internal _model;
    mapping(uint8 kind => mapping(address route => bool)) internal _approved;

    uint256 public calls;
    uint256 public outcomeMismatch;
    uint256 public recordMismatch;
    uint256 public guardianSucceeded;
    uint256 public restoredUnapproved;

    function init() external {
        _setUpWorld();
        (marketId,,) = _listMarket();
        // Venues v0..v3; candidate i uses venue i % 4 and, for i >= 4, also venue (i + 1) % 4.
        for (uint256 i = 0; i < CANDIDATES; ++i) {
            uint256 n = i < 4 ? 1 : 2;
            address[] memory deps = new address[](n);
            deps[0] = _venue(i % 4);
            if (n == 2) deps[1] = _venue((i + 1) % 4);
            _cands[i] = address(new RegistryRouteMock(address(usdc), address(gho), address(lpVaultSwap), deps));
        }
    }

    function _venue(
        uint256 i
    ) internal pure returns (address) {
        return address(uint160(0xDE0000 + i));
    }

    function reg() external view returns (MarketRegistry) {
        return registry;
    }

    function usdcAddr() external view returns (address) {
        return address(usdc);
    }

    function ghoAddr() external view returns (address) {
        return address(gho);
    }

    function modelOf(
        uint8 kind
    ) external view returns (address route, bool active) {
        return (_model[kind].route, _model[kind].active);
    }

    function _sharesVenue(
        address a,
        address b
    ) internal view returns (bool) {
        address[] memory da = RegistryRouteMock(a).dependencies();
        address[] memory db = RegistryRouteMock(b).dependencies();
        for (uint256 i = 0; i < da.length; ++i) {
            for (uint256 j = 0; j < db.length; ++j) {
                if (da[i] == db[j]) return true;
            }
        }
        return false;
    }

    /// @dev Whether `route` may sit in `kind` next to the other slot's record.
    function _fits(
        uint8 kind,
        address route
    ) internal view returns (bool) {
        address other = _model[1 - kind].route;
        return other == address(0) || (other != route && !_sharesVenue(other, route));
    }

    function _caller(
        bool guardian
    ) internal view returns (address) {
        return guardian ? emergencyGuardian : address(timelock);
    }

    function _after(
        bool ok,
        bool expected,
        bool guardian
    ) internal {
        ++calls;
        if (ok != expected) ++outcomeMismatch;
        if (ok && guardian) ++guardianSucceeded;
        for (uint8 k = 0; k < 2; ++k) {
            (address r, bool usable) = registry.getRoute(marketId, address(usdc), address(gho), k);
            if (r != _model[k].route || usable != (_model[k].route != address(0) && _model[k].active)) {
                ++recordMismatch;
            }
        }
    }

    // ─── Actions ───

    function setRoute(
        bool backup,
        uint256 pick,
        bool guardian
    ) external {
        uint8 kind = backup ? 1 : 0;
        address route = _cands[pick % CANDIDATES];
        bool expected = !guardian && _fits(kind, route);
        vm.prank(_caller(guardian));
        try registry.setRoute(marketId, address(usdc), address(gho), kind, route) {
            // REQ-ROUTE-017: a different route this call replaces leaves the slot's approved set.
            address replaced = _model[kind].route;
            if (replaced != address(0) && replaced != route) _approved[kind][replaced] = false;
            _model[kind] = Rec(route, true);
            _approved[kind][route] = true;
            _after(true, expected, guardian);
        } catch {
            _after(false, expected, guardian);
        }
    }

    function disableRoute(
        bool backup,
        bool guardian
    ) external {
        uint8 kind = backup ? 1 : 0;
        bool expected = !guardian && _model[kind].route != address(0);
        vm.prank(_caller(guardian));
        try registry.disableRoute(marketId, address(usdc), address(gho), kind) {
            _model[kind].active = false;
            _after(true, expected, guardian);
        } catch {
            _after(false, expected, guardian);
        }
    }

    function restoreRoute(
        bool backup,
        uint256 pick,
        bool guardian
    ) external {
        uint8 kind = backup ? 1 : 0;
        address route = _cands[pick % CANDIDATES];
        bool wasApproved = _approved[kind][route];
        bool expected = !guardian && wasApproved && _fits(kind, route);
        vm.prank(_caller(guardian));
        try registry.restoreRoute(marketId, address(usdc), address(gho), kind, route) {
            if (!wasApproved) ++restoredUnapproved;
            _model[kind] = Rec(route, true);
            _after(true, expected, guardian);
        } catch {
            _after(false, expected, guardian);
        }
    }
}
