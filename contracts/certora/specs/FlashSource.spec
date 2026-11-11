/*
 * AaveV3FlashSource (src/flash/AaveV3FlashSource.sol, interfaces src/flash/IFlashSource.sol and
 * src/interfaces/external/aave/IAaveV3FlashLoanReceiver.sol; spec 2.11 Flash source): the Aave V3 Pool `flashLoan` of
 * the debt asset, single asset, mode 0.
 *
 * The flash source lends the debt asset to LPVaultSwap for one liquidation. Before the loan it checks the caller, that
 * no loan is open, that the lender is not the Hub of the CDP Spoke being liquidated, the lender's available liquidity
 * and the premium against `maxFlashFeeBps` (exact: `premium * 1e4 <= maxFlashFeeBps * amount`). In the lender's
 * callback it checks the caller (the lender), the initiator (itself), one asset and the active context set by
 * `flashLoan`, so no one can enter the callback outside a loan it started.
 *
 * Storage assumption: none; the contract has only immutables, and the flash context is transient, so it is empty at
 * the start of every rule (each rule is one transaction, setup/TransientModel.spec).
 *
 * Summaries: the Pool's views (`getConfiguration`, `getReserveAToken`, `FLASHLOAN_PREMIUM_TOTAL`,
 * `ADDRESSES_PROVIDER`), the PoolAddressesProvider (`getACLManager`), the ACLManager (`isFlashBorrower`) and the
 * ParameterStore (`maxFlashFeeBps`) are deterministic ghost reads, so a value the rule reads equals the value the
 * contract reads in the same transaction; token balances use the ERC-20 model. `LENDER` is linked to the Pool model
 * `MockAaveV3Pool` (test/utils/mocks/AaveV3PoolMocks.sol), whose `flashLoan` calls the source's `executeOperation`
 * back (dispatched), so a loan can complete; the satisfy rules at the end show that it does, so the flashLoan rules
 * cannot pass vacuously.
 */

import "setup/Erc20Model.spec";
import "setup/TransientModel.spec";

methods {
    function LENDER() external returns (address) envfree;
    function LP_VAULT_SWAP() external returns (address) envfree;
    function PARAMETER_STORE() external returns (address) envfree;
    function maxFlashLoan(address) external returns (uint256) envfree;
    function flashPremium(address, uint256) external returns (uint256) envfree;
    function flashLoan(address, uint256, address, bytes) external returns (uint256);
    function executeOperation(address[], uint256[], uint256[], address, bytes) external returns (bool);

    function _.executeOperation(address[], uint256[], uint256[], address, bytes) external => DISPATCHER(true);
    function _.getConfiguration(address a) external => poolConfiguration[a] expect uint256;
    function _.getVirtualUnderlyingBalance(address a) external => poolVirtualBalance[a] expect uint128;
    function _.getReserveAToken(address a) external => poolAToken[a] expect address;
    function _.FLASHLOAN_PREMIUM_TOTAL() external => poolPremiumTotal expect uint128;
    function _.ADDRESSES_PROVIDER() external => poolAddressesProvider expect address;
    function _.getACLManager() external => aclManager expect address;
    function _.isFlashBorrower(address b) external => flashBorrower[b] expect bool;
    function _.maxFlashFeeBps() external => capBps expect uint16;
    function _.balanceOf(address a) external => erc20BalanceOf(calledContract, a) expect uint256;
}

// Deterministic state of the Pool, its ACLManager and the ParameterStore for one transaction.
ghost mapping(address => uint256) poolConfiguration;
ghost mapping(address => address) poolAToken;
ghost mapping(address => uint128) poolVirtualBalance;
ghost uint128 poolPremiumTotal;
ghost address poolAddressesProvider;
ghost address aclManager;
ghost mapping(address => bool) flashBorrower;
ghost uint16 capBps;

// Flash callback authentication: only LPVaultSwap starts a loan.
// PROP-080 verifies: INV-095, INV-040, REQ-FLASH-001, REQ-FLASH-004
rule flashLoanOnlyForLPVaultSwap(address asset, uint256 amount, address spokeHub, bytes context) {
    env e;
    transientStorageEmpty();

    flashLoan(e, asset, amount, spokeHub, context);

    assert e.msg.sender == LP_VAULT_SWAP(), "a flash loan was started by an address other than LPVaultSwap";
}

// Flash callback authentication: the lender's callback runs only from the lender, for a loan this contract initiated,
// for one asset.
// PROP-080 verifies: INV-095, INV-040, REQ-FLASH-001, REQ-FLASH-004
rule executeOperationOnlyFromLenderForOwnLoan(address[] assets, uint256[] amounts, uint256[] premiums,
                                              address initiator, bytes params) {
    env e;
    transientStorageEmpty();

    executeOperation@withrevert(e, assets, amounts, premiums, initiator, params);
    bool reverted = lastReverted;

    assert !reverted => e.msg.sender == LENDER(), "the callback accepted a caller other than the lender";
    assert !reverted => initiator == currentContract, "the callback accepted a loan another address initiated";
    assert !reverted => assets.length == 1, "the callback accepted more than one asset";
}

// The callback reads the transient context `flashLoan` sets; a call that does not come from inside `flashLoan` finds
// no context and reverts, whoever the caller.
// PROP-080 verifies: INV-095, INV-040, REQ-FLASH-001, REQ-FLASH-004
rule executeOperationRevertsWithoutActiveContext(address[] assets, uint256[] amounts, uint256[] premiums,
                                                 address initiator, bytes params) {
    env e;
    transientStorageEmpty();

    executeOperation@withrevert(e, assets, amounts, premiums, initiator, params);

    assert lastReverted, "the callback ran outside an active flashLoan context";
}

// The flash source is never the Hub of the Borrow Spoke being liquidated: borrowing the debt asset from that Hub would
// draw the liquidity the liquidation is repaying.
// PROP-080 verifies: INV-095, REQ-FLASH-002, REQ-FLASH-003
rule flashLoanRefusesTheLiquidatedHub(address asset, uint256 amount, address spokeHub, bytes context) {
    env e;
    transientStorageEmpty();
    require spokeHub == LENDER();

    flashLoan@withrevert(e, asset, amount, spokeHub, context);

    assert lastReverted, "a flash loan was drawn from the Hub of the Spoke being liquidated";
}

// Before the loan: the amount is within the lender's available liquidity.
// PROP-080 verifies: INV-095, REQ-FLASH-002, REQ-FLASH-003
rule flashLoanWithinAvailableLiquidity(address asset, uint256 amount, address spokeHub, bytes context) {
    env e;
    transientStorageEmpty();
    uint256 available = maxFlashLoan(asset);

    flashLoan(e, asset, amount, spokeHub, context);

    assert amount <= available, "a flash loan exceeded the lender's available liquidity";
}

// Before the loan: the premium the lender quotes passes the exact cap `premium * 1e4 <= maxFlashFeeBps * amount`.
// PROP-080 verifies: INV-095, REQ-FLASH-001, REQ-FLASH-002, SPEC-LIQ-015
rule flashLoanWithinPremiumCap(address asset, uint256 amount, address spokeHub, bytes context) {
    env e;
    transientStorageEmpty();
    uint256 premium = flashPremium(asset, amount);
    // The cap the source reads before the Pool call; the ghost is not persistent, so it is read here, at the same point.
    uint16 cap = capBps;

    flashLoan(e, asset, amount, spokeHub, context);

    assert premium * 10000 <= to_mathint(cap) * amount, "a flash loan was taken with a premium above maxFlashFeeBps";
}

// Reachability: a loan by LPVaultSwap completes (the Pool model ran the callback, LPVaultSwap repaid), so the
// flashLoan rules above are not vacuous.
// PROP-080 verifies: REQ-FLASH-001, REQ-FLASH-003
rule flashLoanCanComplete(address asset, uint256 amount, address spokeHub, bytes context) {
    env e;
    transientStorageEmpty();

    flashLoan(e, asset, amount, spokeHub, context);

    satisfy true;
}

// Reachability: a completed loan can carry a non-zero premium within the cap.
// PROP-080 verifies: REQ-FLASH-001, REQ-FLASH-003, SPEC-LIQ-015
rule flashLoanCanCompleteWithPremium(address asset, uint256 amount, address spokeHub, bytes context) {
    env e;
    transientStorageEmpty();

    uint256 premium = flashLoan(e, asset, amount, spokeHub, context);

    satisfy premium > 0 && capBps > 0;
}
