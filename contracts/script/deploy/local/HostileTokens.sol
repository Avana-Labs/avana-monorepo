// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Hostile test tokens
/// @notice Stand-ins for the token behaviours `REQ-ARCH-014` keeps out of listing: a transfer fee, a rebasing balance,
/// a missing `decimals()`, and an issuer fee switch read by `basisPointsRate()`. The local rehearsal lists each and
/// expects the listing to be refused. Only the minter (the world deployer) can mint or change a token's behaviour.
/// Never deployed on Ethereum or Base.
abstract contract HostileBase is ERC20 {
    address public immutable MINTER;

    error NotMinter();

    constructor(
        string memory name_,
        string memory symbol_,
        address minter
    ) ERC20(name_, symbol_) {
        MINTER = minter;
    }

    modifier onlyMinter() {
        if (msg.sender != MINTER) revert NotMinter();
        _;
    }

    function mint(
        address to,
        uint256 amount
    ) external virtual onlyMinter {
        _mint(to, amount);
    }
}

/// @notice Takes `feeBps` of every transfer (burned). The fee starts at 0 so the world can fund its pool, then the
/// minter switches it on.
contract FeeOnTransferToken is HostileBase {
    uint16 public feeBps;

    constructor(
        string memory symbol_,
        address minter
    ) HostileBase(string.concat("Test fee-on-transfer ", symbol_), symbol_, minter) {}

    function setFeeBps(
        uint16 bps
    ) external onlyMinter {
        feeBps = bps;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) return super._update(from, to, value);
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// @notice Balances are shares times `index / 1e18`; the minter rebases by setting the index.
contract RebasingToken is HostileBase {
    uint256 public index = 1e18;

    constructor(
        string memory symbol_,
        address minter
    ) HostileBase(string.concat("Test rebasing ", symbol_), symbol_, minter) {}

    function rebase(
        uint256 newIndex
    ) external onlyMinter {
        index = newIndex;
    }

    function balanceOf(
        address account
    ) public view override returns (uint256) {
        return (super.balanceOf(account) * index) / 1e18;
    }

    function totalSupply() public view override returns (uint256) {
        return (super.totalSupply() * index) / 1e18;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._update(from, to, (value * 1e18) / index);
    }
}

/// @notice An ERC-20 whose `decimals()` reverts, as for a token that does not implement it.
contract NoDecimalsToken is HostileBase {
    error NoDecimals();

    constructor(
        string memory symbol_,
        address minter
    ) HostileBase(string.concat("Test without decimals ", symbol_), symbol_, minter) {}

    function decimals() public pure override returns (uint8) {
        revert NoDecimals();
    }
}

/// @notice 6 decimals and an issuer fee switch read through `basisPointsRate()`, like USDT; the fee is charged on
/// transfers once switched on.
contract FeeSwitchToken is HostileBase {
    uint256 public basisPointsRate;

    constructor(
        string memory symbol_,
        address minter
    ) HostileBase(string.concat("Test fee-switch ", symbol_), symbol_, minter) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setBasisPointsRate(
        uint256 bps
    ) external onlyMinter {
        basisPointsRate = bps;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == address(0) || to == address(0) || basisPointsRate == 0) return super._update(from, to, value);
        uint256 fee = (value * basisPointsRate) / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}
