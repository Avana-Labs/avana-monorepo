// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapterSteps} from "../../src/policy/aave-adapter/AaveAdapterSteps.sol";
import {AaveAdapterStorage} from "../../src/policy/aave-adapter/AaveAdapterStorage.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {AaveAdapterImmutables} from "../../src/policy/aave-adapter/types/AaveAdapterImmutables.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Token stand-in for the vault token and a debt asset: plain balances, allowances and supply, `burn` and
/// `mint` open, and a `move` the Spoke stand-in uses to pay out of the Hub's balance.
contract HalmosToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public hub;
    address public spoke;

    function bind(
        address hub_,
        address spoke_
    ) external {
        hub = hub_;
        spoke = spoke_;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function move(
        address from,
        address to,
        uint256 amount
    ) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Logic-free proxy stand-in: forwards the call and bubbles a revert, as the PositionProxy does.
contract HalmosProxy {
    function execute(
        address target,
        bytes calldata data
    ) external returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

/// @notice Spoke and Hub stand-in with shares == assets for the vault token: `withdraw` removes shares from the
/// account and the Hub and pays the units out of the Hub's balance. In `faulty` mode it returns `returned` and pays
/// `delivered` whatever was asked. `repay` takes `min(amount, debt)` from the caller into the Hub.
contract HalmosSpoke {
    HalmosToken public immutable VT;
    HalmosToken public immutable ASSET;
    address public constant HUB = address(0x4B0B);
    mapping(address => uint256) public shares;
    uint256 public hubShares;
    uint256 public debt;
    bool public faulty;
    uint256 public returned;
    uint256 public delivered;

    constructor(
        HalmosToken vt,
        HalmosToken asset
    ) {
        VT = vt;
        ASSET = asset;
    }

    function seed(
        address proxy,
        uint256 s
    ) external {
        shares[proxy] = s;
        hubShares = s;
        VT.mint(HUB, s);
    }

    function setDebt(
        uint256 d
    ) external {
        debt = d;
    }

    function setFaulty(
        uint256 r,
        uint256 dlv
    ) external {
        faulty = true;
        returned = r;
        delivered = dlv;
    }

    function withdraw(
        uint256,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256) {
        if (faulty) {
            VT.move(HUB, msg.sender, delivered);
            return (amount, returned);
        }
        shares[onBehalfOf] -= amount;
        hubShares -= amount;
        VT.move(HUB, msg.sender, amount);
        return (amount, amount);
    }

    function getUserTotalDebt(
        uint256,
        address
    ) external view returns (uint256) {
        return debt;
    }

    function getReserve(
        uint256
    ) external view returns (IAaveV4Spoke.Reserve memory r) {
        r.underlying = address(ASSET);
    }

    function repay(
        uint256,
        uint256 amount,
        address
    ) external returns (uint256, uint256) {
        uint256 taken = amount < debt ? amount : debt;
        ASSET.transferFrom(msg.sender, HUB, taken);
        debt -= taken;
        return (0, taken);
    }
}

/// @notice Collateralization stand-in: the market's credited total and pending units, and a debit.
contract HalmosCollateralization {
    uint256 public credited;
    uint256 public pendingUnits;

    function set(
        uint256 c,
        uint256 p
    ) external {
        credited = c;
        pendingUnits = p;
    }

    function debit(
        uint256 units
    ) external {
        credited -= units;
    }

    function getTotalCredited(
        address
    ) external view returns (uint256) {
        return credited;
    }

    function getPending(
        address
    ) external view returns (Pending memory p) {
        p.units = pendingUnits;
    }
}

/// @notice The production account steps and backing-gap check of the Adapter, exposed for symbolic execution.
contract AaveAdapterStepsHarness is AaveAdapterSteps {
    constructor(
        AaveAdapterImmutables memory im
    ) AaveAdapterStorage(im) {}

    function withdrawRecord(
        address proxy,
        address spoke,
        address vt,
        uint256 units
    ) external {
        int256 gapBefore = _gap(vt);
        _withdrawAndBurn(proxy, spoke, vt, 0, units);
        HalmosCollateralization(_COLLATERALIZATION).debit(units);
        _checkGap(vt, gapBefore);
    }

    function withdrawStep(
        address proxy,
        address spoke,
        address vt,
        uint256 units
    ) external {
        _withdrawAndBurn(proxy, spoke, vt, 0, units);
    }

    function repayDebt(
        address payer,
        address proxy,
        address spoke,
        uint256 cap,
        bool repayAll
    ) external returns (uint256 spent, uint256 debtAfter, bool moved) {
        (spent, debtAfter, moved) = _repayDebt(payer, proxy, spoke, 0, cap, repayAll);
    }

    function checkGap(
        address vt,
        int256 gapBefore
    ) external view {
        _checkGap(vt, gapBefore);
    }
}

/// @title AaveAdapterHalmosTest
/// @notice Symbolic checks of the Adapter's own account steps on the production code (`AaveAdapterSteps`): the
/// withdrawal step's unit equalities (PROP-011), its refusal of a Spoke that pays or reports other than `units`, the
/// repay sizing and refund of SPEC-PROXY-003 and SPEC-PROXY-007, and the backing-gap check of SPEC-PROXY-008.
/// @dev The Spoke, Hub, tokens, proxy and Collateralization are small stand-ins with exact integer behaviour; the
/// amounts are bounded to `uint128`, the Hub's amount bound. Addresses are constants or contracts built in `setUp`.
contract AaveAdapterHalmosTest is Test {
    address internal constant PAYER = address(0xBA7E5);

    HalmosToken internal vt;
    HalmosToken internal asset;
    HalmosProxy internal proxy;
    HalmosSpoke internal spoke;
    HalmosCollateralization internal coll;
    AaveAdapterStepsHarness internal steps;

    function setUp() public {
        vt = new HalmosToken();
        asset = new HalmosToken();
        proxy = new HalmosProxy();
        spoke = new HalmosSpoke(vt, asset);
        vt.bind(spoke.HUB(), address(spoke));
        coll = new HalmosCollateralization();
        AaveAdapterImmutables memory im = AaveAdapterImmutables({
            proxyManager: address(0x1001),
            collateralization: address(coll),
            riskModule: address(0x1003),
            marketRegistry: address(0x1004),
            parameterStore: address(0x1005),
            lpVaultSwap: address(0x1006),
            lock: address(0x1007),
            vaultTokenFactory: address(0x1008),
            timelock: address(0x1009)
        });
        steps = new AaveAdapterStepsHarness(im);
    }

    // PROP-011 verifies: REQ-PROXY-037, REQ-PROXY-038, REQ-PROXY-089, REQ-ADAPTER-005, REQ-ADAPTER-069, SPEC-PROXY-008, INV-013, Q-224
    /// @notice With shares == assets, a withdrawal of any `units` the account holds drops the proxy's shares, the Hub's
    /// shares, the vault-token supply (the burn) and Collateralization's credited units by the same `units`, leaves the
    /// proxy with no vault tokens, and keeps the backing gap.
    function check_PROP_011_withdrawUnitsAllEqual(
        uint128 held,
        uint128 units
    ) public {
        vm.assume(units > 0 && units <= held);
        spoke.seed(address(proxy), held);
        coll.set(held, 0);
        uint256 shares0 = spoke.shares(address(proxy));
        uint256 hub0 = spoke.hubShares();
        uint256 supply0 = vt.totalSupply();
        uint256 credited0 = coll.credited();
        steps.withdrawRecord(address(proxy), address(spoke), address(vt), units);
        assert(shares0 - spoke.shares(address(proxy)) == units);
        assert(hub0 - spoke.hubShares() == units);
        assert(supply0 - vt.totalSupply() == units);
        assert(credited0 - coll.credited() == units);
        assert(vt.balanceOf(address(proxy)) == 0);
    }

    // PROP-011 verifies: REQ-PROXY-089, REQ-PROXY-094, SPEC-PROXY-005
    /// @notice Whatever a Spoke reports and pays, the withdrawal step completes only if both the returned amount and
    /// the proxy's vault-token balance rise equal `units`, so the burn always equals what arrived.
    function check_PROP_011_withdrawRefusesOtherAmounts(
        uint128 held,
        uint128 units,
        uint128 returned,
        uint128 delivered
    ) public {
        vm.assume(units > 0 && delivered <= held);
        spoke.seed(address(proxy), held);
        spoke.setFaulty(returned, delivered);
        uint256 supply0 = vt.totalSupply();
        try steps.withdrawStep(address(proxy), address(spoke), address(vt), units) {
            assert(returned == units && delivered == units);
            assert(supply0 - vt.totalSupply() == units);
        } catch (bytes memory reason) {
            assert(returned != units || delivered != units);
            bytes4 s = bytes4(reason);
            assert(s == IAaveAdapterErrors.UnitsMismatch.selector);
        }
    }

    /// @notice Repay sizing (SPEC-PROXY-003, SPEC-PROXY-007): at zero debt nothing moves; a repay-all above its cap
    /// reverts `RepayExceedsMax` before any transfer; otherwise the pull is `cap` for a repay-all and `min(cap, D)` for a
    /// partial repay, Aave takes `min(pull, D)`, the payer gets `pull − spent` back, and a repay-all ends at zero debt.
    function check_repaySizingAndRefund(
        uint128 d,
        uint128 cap,
        bool repayAll
    ) public {
        vm.assume(cap > 0);
        spoke.setDebt(d);
        asset.mint(PAYER, cap);
        vm.prank(PAYER);
        asset.approve(address(steps), cap);
        try steps.repayDebt(PAYER, address(proxy), address(spoke), cap, repayAll) returns (
            uint256 spent, uint256 debtAfter, bool moved
        ) {
            if (d == 0) {
                assert(!moved && spent == 0 && asset.balanceOf(PAYER) == cap);
                return;
            }
            assert(!repayAll || d <= cap);
            uint256 pulled = repayAll || cap < d ? cap : d;
            uint256 expectedSpent = pulled < d ? pulled : d;
            assert(moved);
            assert(spent == expectedSpent);
            assert(asset.balanceOf(PAYER) == uint256(cap) - spent);
            assert(debtAfter == uint256(d) - spent);
            assert(!repayAll || debtAfter == 0);
            assert(asset.balanceOf(address(proxy)) == 0);
            assert(asset.allowance(address(proxy), address(spoke)) == 0);
        } catch (bytes memory reason) {
            assert(repayAll && d > cap);
            assert(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(IAaveAdapterErrors.RepayExceedsMax.selector, d, cap))
            );
        }
    }

    /// @notice The backing-gap check (SPEC-PROXY-008) passes exactly when `supply ≤ credited + pending` and
    /// `credited + pending − supply` equals the gap read before; otherwise it reverts `BackingMismatch(supply,
    /// credited, pending)`.
    function check_backingGapCheck(
        uint128 supply,
        uint128 credited,
        uint128 pending,
        int128 gapBefore
    ) public {
        vt.mint(address(0xD00D), supply);
        coll.set(credited, pending);
        bool ok = uint256(supply) <= uint256(credited) + pending
            && int256(uint256(credited) + pending) - int256(uint256(supply)) == int256(gapBefore);
        try steps.checkGap(address(vt), gapBefore) {
            assert(ok);
        } catch (bytes memory reason) {
            assert(!ok);
            assert(
                keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(IAaveAdapterErrors.BackingMismatch.selector, supply, credited, pending)
                    )
            );
        }
    }
}
