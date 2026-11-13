/*
 * RiskModule drift check (interface src/policy/risk-module/IRiskModuleChecks.sol, `checkAaveConfig`).
 *
 * Every Avana collateral reserve sits on a standard, unmodified Aave V4 Spoke. Liquidation exclusivity rests on three
 * Aave settings the listing AIP sets and the drift check enforces: `receiveSharesEnabled = false` (a liquidator taking
 * vault-token shares would hold collateral Avana can never settle), `liquidationFee = 0`, and no reinvestment controller
 * on the vault-token asset. A drift trips the breaker of new activity; liquidation never reads this check.
 *
 * The Aave reads are summarised so that each rule records whether the check read a drifted value; a check that read
 * one must revert. The implementation binding reads MarketRegistry `spokeImplementationStatus`, summarised by a ghost.
 */

methods {
    function checkAaveConfig(address, uint256[]) external;
    function _.getReserveConfig(uint256 rid) external => readReserveConfig(rid) expect IAaveV4Spoke.ReserveConfig;
    function _.getDynamicReserveConfig(uint256 rid, uint32 key) external => readDynamicConfig(rid, key)
        expect IAaveV4Spoke.DynamicReserveConfig;
    function _.getAssetConfig(uint256 assetId) external => readAssetConfig(assetId) expect IAaveV4Hub.AssetConfig;
    function preBorrowCheck(address, uint256, uint256) external;
    function preWithdrawCheck(address) external;
    function pokeConfig(address) external returns (DriftReason);
    function _.spokeImplementationStatus(address s) external => implStatusOf(s) expect (address, bytes32, bool);
    function _.SPOKE() external => proxySpokeOf(calledContract) expect address;
}

// Whether the implementation behind a Spoke proxy is the one recorded at approval (MarketRegistry
// `spokeImplementationStatus`: address and code hash), and the Spoke a proxy is bound to.
ghost implCurrent(address) returns bool;
ghost proxySpokeOf(address) returns address;

function implStatusOf(address s) returns (address, bytes32, bool) {
    address impl;
    bytes32 codeHash;
    return (impl, codeHash, implCurrent(s));
}

ghost bool sawReceiveShares;
ghost bool sawLiquidationFee;
ghost bool sawReinvestmentController;

function readReserveConfig(uint256 rid) returns IAaveV4Spoke.ReserveConfig {
    IAaveV4Spoke.ReserveConfig c;
    sawReceiveShares = sawReceiveShares || c.receiveSharesEnabled;
    return c;
}

function readDynamicConfig(uint256 rid, uint32 key) returns IAaveV4Spoke.DynamicReserveConfig {
    IAaveV4Spoke.DynamicReserveConfig c;
    sawLiquidationFee = sawLiquidationFee || c.liquidationFee != 0;
    return c;
}

function readAssetConfig(uint256 assetId) returns IAaveV4Hub.AssetConfig {
    IAaveV4Hub.AssetConfig c;
    sawReinvestmentController = sawReinvestmentController || c.reinvestmentController != 0;
    return c;
}

// PROP-078 verifies: INV-093, INV-029, REQ-ADAPTER-028, REQ-ADAPTER-029, REQ-ADAPTER-030, REQ-ADAPTER-031, REQ-ADAPTER-032, REQ-ADAPTER-033, REQ-ADAPTER-034, REQ-ADAPTER-035, REQ-ADAPTER-036
rule driftCheckRefusesDriftedSettings(address spoke, uint256[] marketIds) {
    env e;
    require !sawReceiveShares && !sawLiquidationFee && !sawReinvestmentController;

    checkAaveConfig@withrevert(e, spoke, marketIds);

    assert sawReceiveShares => lastReverted, "the drift check passed with receiveSharesEnabled on a collateral reserve";
    assert sawLiquidationFee => lastReverted, "the drift check passed with a non-zero liquidationFee";
    assert sawReinvestmentController => lastReverted,
        "the drift check passed with a reinvestment controller on the vault-token asset";
}

// Spoke implementation binding: whatever the implementation address and code hash are, an implementation that is not
// the approved one stops the drift check, every borrow and every withdrawal with debt on that Spoke, and the
// permissionless poke reports it (so it latches CONFIG_DRIFT). Revalidated on any Spoke implementation change: the
// position-manager routes of the new implementation are checked again before `deployCdpSpoke` re-approves it.
// PROP-078 verifies: REQ-ADAPTER-063, REQ-RISK-088, REQ-CONFIG-074
rule driftCheckRefusesAReplacedImplementation(address spoke, uint256[] marketIds) {
    env e;
    require !implCurrent(spoke);

    checkAaveConfig@withrevert(e, spoke, marketIds);

    assert lastReverted, "the drift check passed on a Spoke whose implementation is not the approved one";
}

// PROP-078 verifies: REQ-ADAPTER-063, REQ-RISK-088
rule borrowSideRefusesAReplacedImplementation(address proxy, uint256 debtReserveId, uint256 amount, bool borrow) {
    env e;
    require !implCurrent(proxySpokeOf(proxy));

    if (borrow) {
        preBorrowCheck@withrevert(e, proxy, debtReserveId, amount);
    } else {
        preWithdrawCheck@withrevert(e, proxy);
    }

    assert lastReverted, "a borrow-side check passed on a Spoke whose implementation is not the approved one";
}

// PROP-078 verifies: REQ-ADAPTER-063, REQ-RISK-088, REQ-RISK-090
rule pokeConfigReportsAReplacedImplementation(address spoke) {
    env e;
    require !implCurrent(spoke);

    RiskModule.DriftReason r = pokeConfig(e, spoke);

    assert r == RiskModule.DriftReason.SpokeImplementation, "the poke did not report the replaced implementation";
}
