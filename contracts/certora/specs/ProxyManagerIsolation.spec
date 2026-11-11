/*
 * ProxyManager (interface src/proxy/proxy-manager/IProxyManager.sol): account isolation.
 *
 * Each wallet has one PositionProxy per (CDP Spoke, market), created by CREATE2 with the wallet, the Spoke and the
 * market bound into its creation code. Every market therefore has its own Aave account and health factor, and nothing
 * is cross-collateralised. The proxy holds no logic and is never upgraded or migrated.
 *
 * Implementation: src/proxy/proxy-manager/ProxyManager.sol. The salt and the init code come from `_salt` and
 * `_initCode`, and `deployProxy` creates with OpenZeppelin `Create2.deploy` over the same bytes `predictProxy` hashes.
 * The prover's hashing model is injective, which is what makes distinct CREATE2 preimages give distinct addresses.
 */

methods {
    function ADAPTER() external returns (address) envfree;
    function predictProxy(address, address, uint256) external returns (address) envfree;
    function deployProxy(address, address, uint256) external returns (address);
}

// PROP-076 verifies: INV-064, INV-012, REQ-PROXY-052, REQ-PROXY-055
rule deployProxyAtPredictedAddress(address wallet, address spoke, uint256 marketId) {
    env e;
    address predicted = predictProxy(wallet, spoke, marketId);

    address proxy = deployProxy(e, wallet, spoke, marketId);

    assert proxy == predicted, "the proxy is not at the CREATE2 address of its (wallet, Spoke, market)";
    assert e.msg.sender == ADAPTER(), "a proxy was deployed for a caller other than the Adapter";
}

// PROP-076 verifies: INV-064, INV-012, REQ-PROXY-052, REQ-PROXY-055
rule oneProxyPerWalletSpokeMarket(address wallet, address spoke, uint256 marketId) {
    env e1; env e2;

    deployProxy(e1, wallet, spoke, marketId);
    deployProxy@withrevert(e2, wallet, spoke, marketId);

    assert lastReverted, "a second proxy was deployed for the same (wallet, Spoke, market)";
}

// PROP-076: for any two successful deployProxy calls the triples differ and so do the addresses. A CREATE2 address is
// 160 bits of a hash, so two triples can predict the same address only through a hash collision (the accepted
// assumption of REQ-PROXY-055). Whatever the triples, a deployment whose predicted address already holds a proxy
// reverts, so two successful deployments never share an address; with oneProxyPerWalletSpokeMarket this is the
// whole row. The rule is stated with one deployment and the occupied address: with two deployments in one rule the
// prover's contract-creation model reached no path where both succeed (the sanity check reported it vacuous, with
// dynamic_bound 1 and 2).
// PROP-076 verifies: INV-064, INV-012, REQ-PROXY-052, REQ-PROXY-055
rule distinctAccountsHaveDistinctProxies(address w1, address s1, uint256 m1, address w2, address s2, uint256 m2) {
    env e1; env e2;

    address p1 = deployProxy(e1, w1, s1, m1);
    require predictProxy(w2, s2, m2) == p1;

    deployProxy@withrevert(e2, w2, s2, m2);

    assert lastReverted, "a second deployment landed on an address that already holds a proxy";
}
