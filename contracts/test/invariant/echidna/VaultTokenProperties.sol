// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {VaultTokenBindings} from "../../../src/types/VaultTokenBindings.sol";
import {IVaultToken} from "../../../src/vault-token/vault-token/IVaultToken.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {VaultTokenHolder} from "../../utils/mocks/VaultTokenHolder.sol";

/// @title VaultTokenProperties
/// @notice Echidna and Medusa properties of the vault token (2.4). Between transactions: the supply is the sum of the
/// balances, only the Hub, LPVaultSwap and registered proxies hold units, the registry only grows and never holds a
/// binding, and the bindings never change. Inside each assertion entry point: a mint, burn, transfer, spender transfer
/// or registration succeeds exactly when the 2.4 rule allows it, and moves exactly the stated amounts.
/// @dev The harness is the AaveAdapter. Seven holder contracts stand for the Hub, the CDP Spoke, LPVaultSwap, two
/// proxies, an unregistered contract and an outsider; actor indexes are taken modulo 7 with `if` branches, so hevm
/// sees finite branching.
contract VaultTokenProperties {
    uint256 internal constant ACTORS = 7;

    VaultToken internal immutable TOKEN;
    VaultTokenHolder internal immutable HUB;
    VaultTokenHolder internal immutable SPOKE;
    VaultTokenHolder internal immutable SWAP;
    VaultTokenHolder internal immutable PROXY_A;
    VaultTokenHolder internal immutable PROXY_B;
    VaultTokenHolder internal immutable OTHER;
    VaultTokenHolder internal immutable OUTSIDER;
    address internal immutable LP_VAULT;
    address internal immutable COLL;
    address internal immutable ORACLE;

    /// @notice Registry ghost: true once `addValidProxy` succeeded for the actor.
    mapping(address account => bool registered) public ghostRegistered;

    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        HUB = new VaultTokenHolder();
        SPOKE = new VaultTokenHolder();
        SWAP = new VaultTokenHolder();
        PROXY_A = new VaultTokenHolder();
        PROXY_B = new VaultTokenHolder();
        OTHER = new VaultTokenHolder();
        OUTSIDER = new VaultTokenHolder();
        LP_VAULT = address(new VaultTokenHolder());
        COLL = address(new VaultTokenHolder());
        ORACLE = address(new VaultTokenHolder());
        TOKEN = new VaultToken(
            VaultTokenBindings({
                marketKey: keccak256("avana.echidna.market"),
                integrationId: 1,
                integration: LP_VAULT,
                hub: address(HUB),
                spoke: address(SPOKE),
                marketId: 4,
                lpOracle: ORACLE,
                adapter: address(this),
                lpVaultSwap: address(SWAP),
                collateralization: COLL,
                decimals: 6,
                name: "VT",
                symbol: "VT"
            })
        );
        HUB.setToken(TOKEN);
        SPOKE.setToken(TOKEN);
        SWAP.setToken(TOKEN);
        PROXY_A.setToken(TOKEN);
        PROXY_B.setToken(TOKEN);
        OTHER.setToken(TOKEN);
        OUTSIDER.setToken(TOKEN);
        TOKEN.addValidProxy(address(PROXY_A));
        ghostRegistered[address(PROXY_A)] = true;
    }

    // ─── Properties (between transactions) ───

    function property_supplyIsSumOfBalances() external view returns (bool) {
        uint256 sum = TOKEN.balanceOf(address(this));
        for (uint256 i = 0; i < ACTORS; ++i) {
            sum += TOKEN.balanceOf(address(_actor(i)));
        }
        return sum == TOKEN.totalSupply();
    }

    function property_onlyAllowedHoldersHoldUnits() external view returns (bool) {
        for (uint256 i = 0; i < ACTORS; ++i) {
            address a = address(_actor(i));
            if (TOKEN.balanceOf(a) > 0 && !TOKEN.isAllowedRecipient(a)) return false;
        }
        return TOKEN.balanceOf(address(this)) == 0 && TOKEN.balanceOf(address(SPOKE)) == 0;
    }

    function property_registryMatchesGhostAndHoldsNoBinding() external view returns (bool) {
        for (uint256 i = 0; i < ACTORS; ++i) {
            address a = address(_actor(i));
            if (TOKEN.isValidProxy(a) != ghostRegistered[a]) return false;
        }
        return !TOKEN.isValidProxy(address(HUB)) && !TOKEN.isValidProxy(address(SWAP))
            && !TOKEN.isValidProxy(address(SPOKE)) && !TOKEN.isValidProxy(address(this));
    }

    function property_bindingsFixed() external view returns (bool) {
        return TOKEN.adapter() == address(this) && TOKEN.hub() == address(HUB) && TOKEN.spoke() == address(SPOKE)
            && TOKEN.lpVaultSwap() == address(SWAP) && TOKEN.collateralization() == COLL
            && TOKEN.integration() == LP_VAULT && TOKEN.lpOracle() == ORACLE && TOKEN.marketId() == 4
            && TOKEN.integrationId() == 1 && TOKEN.decimals() == 6;
    }

    // ─── Assertion entry points ───

    /// @notice A mint succeeds exactly for a registered proxy and adds exactly `amount` to it and to the supply.
    function mintTo(
        uint8 who,
        uint64 amount
    ) external {
        address to = address(_actor(who));
        bool expected = TOKEN.isValidProxy(to);
        uint256 balance = TOKEN.balanceOf(to);
        uint256 supply = TOKEN.totalSupply();
        try TOKEN.mint(to, amount) {
            assert(expected);
            assert(TOKEN.balanceOf(to) == balance + amount && TOKEN.totalSupply() == supply + amount);
        } catch (bytes memory reason) {
            assert(!expected);
            assert(
                keccak256(reason) == keccak256(abi.encodeWithSelector(IVaultToken.UnauthorizedRecipient.selector, to))
            );
        }
        ++sequences;
    }

    /// @notice A burn succeeds exactly from a registered proxy or LPVaultSwap holding the amount, with no allowance.
    function burnFrom(
        uint8 who,
        uint64 amount
    ) external {
        address from = address(_actor(who));
        uint256 balance = TOKEN.balanceOf(from);
        uint256 supply = TOKEN.totalSupply();
        bool source = TOKEN.isValidProxy(from) || from == address(SWAP);
        try TOKEN.burn(from, amount) {
            assert(source && amount <= balance);
            assert(TOKEN.balanceOf(from) == balance - amount && TOKEN.totalSupply() == supply - amount);
        } catch (bytes memory reason) {
            assert(!source || amount > balance);
            if (!source) {
                assert(
                    keccak256(reason)
                        == keccak256(
                            abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, from, address(0))
                        )
                );
            }
        }
        ++sequences;
    }

    /// @notice A `transfer` by any holder succeeds exactly for a non-zero amount on an allowed path with enough balance.
    function move(
        uint8 fromIndex,
        uint8 toIndex,
        uint64 amount
    ) external {
        VaultTokenHolder from = _actor(fromIndex);
        address to = address(_actor(toIndex));
        bool path = TOKEN.isAllowedTransfer(address(from), to) && amount > 0;
        uint256 fromBalance = TOKEN.balanceOf(address(from));
        uint256 toBalance = TOKEN.balanceOf(to);
        try from.transfer(to, amount) {
            assert(path && amount <= fromBalance);
            assert(TOKEN.balanceOf(address(from)) == fromBalance - amount);
            assert(TOKEN.balanceOf(to) == toBalance + amount);
        } catch (bytes memory reason) {
            assert(!path || amount > fromBalance);
            if (!path) {
                assert(
                    keccak256(reason)
                        == keccak256(
                            abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, address(from), to)
                        )
                );
            }
        }
        ++sequences;
    }

    /// @notice A spender transfer on an exact allowance: off the paths or for 0 it reverts and spends nothing; on a path
    /// it moves the amount and spends exactly it.
    function spend(
        uint8 fromIndex,
        uint8 toIndex,
        bool bySpoke,
        uint64 amount
    ) external {
        VaultTokenHolder from = _actor(fromIndex);
        VaultTokenHolder spender = bySpoke ? SPOKE : OUTSIDER;
        address to = address(_actor(toIndex));
        from.approve(address(spender), amount);
        bool path = TOKEN.isAllowedTransfer(address(from), to) && amount > 0;
        uint256 fromBalance = TOKEN.balanceOf(address(from));
        try spender.transferFrom(address(from), to, amount) {
            assert(path && amount <= fromBalance);
            assert(TOKEN.allowance(address(from), address(spender)) == 0);
        } catch {
            assert(!path || amount > fromBalance);
            assert(TOKEN.allowance(address(from), address(spender)) == amount);
        }
        from.approve(address(spender), 0);
        ++sequences;
    }

    /// @notice Registration succeeds exactly for an address that is not a binding; it is idempotent.
    function register(
        uint8 who
    ) external {
        address p = address(_actor(who));
        bool reserved = p == address(HUB) || p == address(SPOKE) || p == address(SWAP);
        try TOKEN.addValidProxy(p) {
            assert(!reserved);
            assert(TOKEN.isValidProxy(p));
            ghostRegistered[p] = true;
        } catch (bytes memory reason) {
            assert(reserved);
            assert(keccak256(reason) == keccak256(abi.encodeWithSelector(IVaultToken.ReservedAddress.selector, p)));
        }
        ++sequences;
    }

    /// @notice An outsider never mints, burns or registers.
    function outsiderAdapterCall(
        uint8 which,
        uint8 who,
        uint64 amount
    ) external {
        address target = address(_actor(who));
        bytes memory refused = abi.encodeWithSelector(IVaultToken.OnlyAdapter.selector);
        if (which % 3 == 0) {
            try OUTSIDER.mint(target, amount) {
                assert(false);
            } catch (bytes memory reason) {
                assert(keccak256(reason) == keccak256(refused));
            }
        } else if (which % 3 == 1) {
            try OUTSIDER.burn(target, amount) {
                assert(false);
            } catch (bytes memory reason) {
                assert(keccak256(reason) == keccak256(refused));
            }
        } else {
            try OUTSIDER.addValidProxy(target) {
                assert(false);
            } catch (bytes memory reason) {
                assert(keccak256(reason) == keccak256(refused));
            }
        }
        ++sequences;
    }

    function _actor(
        uint256 i
    ) internal view returns (VaultTokenHolder) {
        i = i % ACTORS;
        if (i == 0) return HUB;
        if (i == 1) return SPOKE;
        if (i == 2) return SWAP;
        if (i == 3) return PROXY_A;
        if (i == 4) return PROXY_B;
        if (i == 5) return OTHER;
        return OUTSIDER;
    }
}
