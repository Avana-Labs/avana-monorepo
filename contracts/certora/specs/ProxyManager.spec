/*
 * ProxyManager (src/proxy/proxy-manager/ProxyManager.sol, interface src/proxy/proxy-manager/IProxyManager.sol,
 * spec 2.5): the only contract that creates PositionProxies, one per (wallet, CDP Spoke, market).
 *
 * `deployProxy(wallet, spoke, marketId)` succeeds only for the Adapter and a wallet that is not frozen, deploys at
 * exactly `predictProxy(wallet, spoke, marketId)` and at most once per (wallet, Spoke, market).
 *
 * Storage assumption: the ProxyManager is immutable and keeps no storage; `ADAPTER` and `MARKET_REGISTRY` are
 * constructor immutables. OpenZeppelin `Create2` v5.1.0 runs as real code, and the new PositionProxy's constructor
 * only stores its immutables, so the creation needs no summary.
 *
 * Summaries: the MarketRegistry freeze list by a ghost map, the freeze part of the registry model (setup/RegistryModel.spec);
 * the model itself is not imported because its pause-state ghosts name MarketRegistry types, which are not in this
 * conf's scene.
 */

methods {
    function ADAPTER() external returns (address) envfree;
    function MARKET_REGISTRY() external returns (address) envfree;
    function predictProxy(address, address, uint256) external returns (address) envfree;
    function deployProxy(address, address, uint256) external returns (address);

    function _.isFrozenAddress(address a) external => registryIsFrozenAddress(a) expect bool;
}

persistent ghost mapping(address => bool) regFrozen;

function registryIsFrozenAddress(address a) returns bool {
    return regFrozen[a];
}

// PROP-064 verifies: INV-012, INV-064, Q-225, Q-226
rule deployProxyOnlyAdapterAtPredictedAddress(address wallet, address spoke, uint256 marketId) {
    env e;
    address predicted = predictProxy(wallet, spoke, marketId);

    address proxy = deployProxy(e, wallet, spoke, marketId);

    assert e.msg.sender == ADAPTER(), "deployProxy ran for a caller other than the Adapter";
    assert proxy == predicted && proxy != 0, "the proxy is not at predictProxy(wallet, spoke, marketId)";
    assert !regFrozen[wallet], "a proxy was deployed for a frozen wallet";
}

// PROP-064 verifies: INV-012, INV-064, Q-225
rule atMostOneProxyPerWalletSpokeMarket(address wallet, address spoke, uint256 marketId) {
    env e1;
    env e2;

    deployProxy(e1, wallet, spoke, marketId);
    deployProxy@withrevert(e2, wallet, spoke, marketId);

    assert lastReverted, "a second proxy was deployed for the same (wallet, spoke, marketId)";
}

// PROP-064 verifies: INV-064, Q-225
rule adapterCanDeploy(address wallet, address spoke, uint256 marketId) {
    env e;
    require e.msg.sender == ADAPTER();
    address proxy = deployProxy(e, wallet, spoke, marketId);
    satisfy proxy != 0;
}
