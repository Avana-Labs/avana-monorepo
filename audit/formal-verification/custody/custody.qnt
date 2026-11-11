// Custody state machine of one market: NFT custody, records, the largest-first walk
// (fixed list order here), reconcile on exit, partial removal, re-credit, deleverage
// release, rescue units, pending settlement and the vault-token supply. Every Adapter
// call carries the backing-gap check (supply <= credited + pending, gap unchanged) as
// part of its guard, so a call that would fail it reverts. Randomized simulation with
// `quint run` (no Apalache): see run.sh.
//
// FV-CUS-QNT-01 verifies: INV-001, INV-002, INV-005, INV-008, INV-058, INV-088, SPEC-BACK-009, SPEC-BACK-010, SPEC-BACK-011, SPEC-BACK-014, REQ-COLL-006, REQ-COLL-016
// FV-CUS-QNT-02 verifies: INV-001, INV-080, INV-045, REQ-ADAPTER-069, REQ-ADAPTER-070, REQ-VAULT-029, SPEC-BACK-012, SPEC-PROXY-008
module custody {
  pure val NFTS = Set(0, 1, 2)
  pure val ORDER = [0, 1, 2]
  pure val PROXIES = Set(0, 1)
  // owner wallet (and so proxy) of each NFT
  pure val WALLET = Map(0 -> 0, 1 -> 1, 2 -> 0)

  var nftAtVault: int -> bool
  var isOpen: int -> bool
  var cred: int -> int
  var live: int -> int
  var rs: int -> int
  var acct: int -> int
  var arsc: int -> int
  var sh: int -> int
  var TC: int
  var P: int
  var supply: int
  var lpvs: int
  var hub: int

  pure def min2(a: int, b: int): int = if (a < b) a else b
  pure def max0(a: int): int = if (a > 0) a else 0

  // Debit u units from proxy p's open records in list order; returns new credited map.
  pure def debit(c: int -> int, o: int -> bool, p: int, u: int): (int -> int, int) =
    ORDER.foldl((c, u), (acc, t) =>
      if (o.get(t) and WALLET.get(t) == p) {
        val take = min2(acc._2, acc._1.get(t))
        (acc._1.set(t, acc._1.get(t) - take), acc._2 - take)
      } else acc)

  pure def subTakes(l: int -> int, before: int -> int, after: int -> int): int -> int =
    NFTS.mapBy(t => l.get(t) - (before.get(t) - after.get(t)))

  // SPEC-BACK-014: rescue units capped at the credited units after a debit.
  pure def capRescue(r: int -> int, c: int -> int): int -> int = NFTS.mapBy(t => min2(r.get(t), c.get(t)))

  pure def sumOf(m: int -> int, p: int): int =
    NFTS.filter(t => WALLET.get(t) == p).fold(0, (s, t) => s + m.get(t))

  pure def acctRescue(r: int -> int): int -> int = PROXIES.mapBy(p => sumOf(r, p))

  // Adapter backing-gap check (REQ-ADAPTER-069): supply <= credited + pending after the
  // call, and the gap credited + pending - supply unchanged by the call.
  pure def gapOk(tc0: int, p0: int, s0: int, tc1: int, p1: int, s1: int): bool =
    s1 <= tc1 + p1 and tc1 + p1 - s1 == tc0 + p0 - s0

  action init = all {
    nftAtVault' = NFTS.mapBy(t => false),
    isOpen' = NFTS.mapBy(t => false),
    cred' = NFTS.mapBy(t => 0),
    live' = NFTS.mapBy(t => 0),
    rs' = NFTS.mapBy(t => 0),
    acct' = PROXIES.mapBy(p => 0),
    arsc' = PROXIES.mapBy(p => 0),
    sh' = PROXIES.mapBy(p => 0),
    TC' = 0, P' = 0, supply' = 0, lpvs' = 0, hub' = 0,
  }

  action pledge = {
    nondet t = NFTS.oneOf()
    nondet L = 1.to(10).oneOf()
    nondet ru = 0.to(10).oneOf()
    val p = WALLET.get(t)
    val rs1 = rs.set(t, ru)
    all {
      not(isOpen.get(t)),
      ru <= L,
      gapOk(TC, P, supply, TC + L, P, supply + L),
      nftAtVault' = nftAtVault.set(t, true),
      isOpen' = isOpen.set(t, true),
      cred' = cred.set(t, L),
      live' = live.set(t, L),
      rs' = rs1,
      arsc' = arsc.set(p, arsc.get(p) + ru),
      acct' = acct.set(p, acct.get(p) + L),
      sh' = sh.set(p, sh.get(p) + L),
      TC' = TC + L, P' = P, supply' = supply + L, lpvs' = lpvs, hub' = hub + L,
    }
  }

  action donate = {
    nondet t = NFTS.oneOf()
    nondet d = 1.to(3).oneOf()
    all {
      isOpen.get(t),
      live' = live.set(t, live.get(t) + d),
      nftAtVault' = nftAtVault, isOpen' = isOpen, cred' = cred, rs' = rs, acct' = acct, arsc' = arsc,
      sh' = sh, TC' = TC, P' = P, supply' = supply, lpvs' = lpvs, hub' = hub,
    }
  }

  // Conforming liquidation: snapshot, seize, burnSeized, settleSeizure (reconcile, debit).
  action seize = {
    nondet p = PROXIES.oneOf()
    nondet u = 1.to(10).oneOf()
    val shB = sh.get(p)
    val sf = max0(acct.get(p) - shB)
    val r1 = debit(cred, isOpen, p, sf)
    val r2 = debit(r1._1, isOpen, p, u)
    val rs2 = capRescue(rs, r2._1)
    all {
      u <= shB,
      u <= acct.get(p) - sf,
      cred' = r2._1,
      live' = subTakes(live, cred, r2._1),
      rs' = rs2,
      arsc' = arsc.set(p, arsc.get(p) - (sumOf(rs, p) - sumOf(rs2, p))),
      acct' = acct.set(p, acct.get(p) - sf - u),
      sh' = sh.set(p, shB - u),
      TC' = TC - sf - u, P' = P + sf, supply' = supply - u, lpvs' = lpvs, hub' = hub - u,
      nftAtVault' = nftAtVault, isOpen' = isOpen,
    }
  }

  // Non-conforming LPVaultSwap: seizes and never burns or settles.
  action seizeUnsettled = {
    nondet p = PROXIES.oneOf()
    nondet u = 1.to(10).oneOf()
    all {
      u <= sh.get(p),
      sh' = sh.set(p, sh.get(p) - u),
      hub' = hub - u, lpvs' = lpvs + u,
      nftAtVault' = nftAtVault, isOpen' = isOpen, cred' = cred, live' = live, rs' = rs, acct' = acct,
      arsc' = arsc, TC' = TC, P' = P, supply' = supply,
    }
  }

  // Debt-free withdraw with the previewRelease units: proxy withdraw, burn, release.
  action withdraw = {
    nondet t = NFTS.oneOf()
    val p = WALLET.get(t)
    val S = sh.get(p)
    val sf = max0(acct.get(p) - S)
    val r1 = debit(cred, isOpen, p, sf)
    val units = r1._1.get(t)
    val rs1 = capRescue(rs, r1._1).set(t, 0)
    all {
      isOpen.get(t),
      units > 0, units <= S,
      gapOk(TC, P, supply, TC - sf - units, P + sf, supply - units),
      cred' = r1._1.set(t, 0),
      live' = subTakes(live, cred, r1._1).set(t, 0),
      rs' = rs1,
      arsc' = arsc.set(p, arsc.get(p) - (sumOf(rs, p) - sumOf(rs1, p))),
      isOpen' = isOpen.set(t, false),
      nftAtVault' = nftAtVault.set(t, false),
      acct' = acct.set(p, acct.get(p) - sf - units),
      sh' = sh.set(p, S - units),
      TC' = TC - sf - units, P' = P + sf, supply' = supply - units, lpvs' = lpvs, hub' = hub - units,
    }
  }

  // Partial removal (Adapter.removeLiquidity, Collateralization.releasePartial).
  action removePartial = {
    nondet t = NFTS.oneOf()
    nondet u = 1.to(10).oneOf()
    val p = WALLET.get(t)
    val S = sh.get(p)
    val sf = max0(acct.get(p) - S)
    val r1 = debit(cred, isOpen, p, sf)
    val c = r1._1.get(t)
    val c2 = r1._1.set(t, c - u)
    val rs1 = capRescue(rs, c2)
    all {
      isOpen.get(t),
      u <= S, u < c,
      gapOk(TC, P, supply, TC - sf - u, P + sf, supply - u),
      cred' = c2,
      live' = subTakes(live, cred, c2),
      rs' = rs1,
      arsc' = arsc.set(p, arsc.get(p) - (sumOf(rs, p) - sumOf(rs1, p))),
      acct' = acct.set(p, acct.get(p) - sf - u),
      sh' = sh.set(p, S - u),
      TC' = TC - sf - u, P' = P + sf, supply' = supply - u, lpvs' = lpvs, hub' = hub - u,
      nftAtVault' = nftAtVault, isOpen' = isOpen,
    }
  }

  // Re-credit (Adapter.recredit, Collateralization.recredit): credit live - credited.
  action recredit = {
    nondet t = NFTS.oneOf()
    nondet ru = 0.to(10).oneOf()
    val p = WALLET.get(t)
    val sf = max0(acct.get(p) - sh.get(p))
    val r1 = debit(cred, isOpen, p, sf)
    val l1 = subTakes(live, cred, r1._1)
    val c = r1._1.get(t)
    val added = l1.get(t) - c
    val rs0 = capRescue(rs, r1._1)
    val rs1 = rs0.set(t, rs0.get(t) + ru)
    all {
      isOpen.get(t),
      c > 0, added > 0, ru <= added,
      gapOk(TC, P, supply, TC - sf + added, P + sf, supply + added),
      cred' = r1._1.set(t, l1.get(t)),
      live' = l1,
      rs' = rs1,
      arsc' = arsc.set(p, arsc.get(p) - (sumOf(rs, p) - sumOf(rs1, p))),
      acct' = acct.set(p, acct.get(p) - sf + added),
      sh' = sh.set(p, sh.get(p) + added),
      TC' = TC - sf + added, P' = P + sf, supply' = supply + added, lpvs' = lpvs, hub' = hub + added,
      nftAtVault' = nftAtVault, isOpen' = isOpen,
    }
  }

  // Deleverage release inside a repay with collateral (releaseForDeleverage).
  action deleverage = {
    nondet t = NFTS.oneOf()
    nondet u = 1.to(10).oneOf()
    val p = WALLET.get(t)
    val S = sh.get(p)
    val sf = max0(acct.get(p) - S)
    val r1 = debit(cred, isOpen, p, sf)
    val c = r1._1.get(t)
    val closed = c - u == 0
    val c2 = r1._1.set(t, c - u)
    val l2 = subTakes(live, cred, c2)
    val rs1 = capRescue(rs, c2)
    all {
      isOpen.get(t),
      u <= S, u <= c,
      gapOk(TC, P, supply, TC - sf - u, P + sf, supply - u),
      cred' = c2,
      live' = if (closed) l2.set(t, 0) else l2,
      rs' = rs1,
      arsc' = arsc.set(p, arsc.get(p) - (sumOf(rs, p) - sumOf(rs1, p))),
      isOpen' = if (closed) isOpen.set(t, false) else isOpen,
      nftAtVault' = if (closed) nftAtVault.set(t, false) else nftAtVault,
      acct' = acct.set(p, acct.get(p) - sf - u),
      sh' = sh.set(p, S - u),
      TC' = TC - sf - u, P' = P + sf, supply' = supply - u, lpvs' = lpvs, hub' = hub - u,
    }
  }

  action releaseZero = {
    nondet t = NFTS.oneOf()
    val p = WALLET.get(t)
    val sf = max0(acct.get(p) - sh.get(p))
    val r1 = debit(cred, isOpen, p, sf)
    val rs1 = capRescue(rs, r1._1).set(t, 0)
    all {
      isOpen.get(t),
      r1._1.get(t) == 0,
      cred' = r1._1,
      live' = subTakes(live, cred, r1._1).set(t, 0),
      rs' = rs1,
      arsc' = arsc.set(p, arsc.get(p) - (sumOf(rs, p) - sumOf(rs1, p))),
      isOpen' = isOpen.set(t, false),
      nftAtVault' = nftAtVault.set(t, false),
      acct' = acct.set(p, acct.get(p) - sf),
      sh' = sh, TC' = TC - sf, P' = P + sf, supply' = supply, lpvs' = lpvs, hub' = hub,
    }
  }

  // Conforming settlePending: burnSeized(x), then the one-sided check of SPEC-BACK-012.
  action settlePending = {
    nondet x = 1.to(10).oneOf()
    all {
      x <= P, x <= lpvs,
      (supply - x) + x <= TC + P,
      P' = P - x, lpvs' = lpvs - x, supply' = supply - x,
      nftAtVault' = nftAtVault, isOpen' = isOpen, cred' = cred, live' = live, rs' = rs, acct' = acct,
      arsc' = arsc, sh' = sh, TC' = TC, hub' = hub,
    }
  }

  // Non-conforming LPVaultSwap: settlePending(x) with no burn (passes only within the gap).
  action settlePendingNoBurn = {
    nondet x = 1.to(10).oneOf()
    all {
      x <= P,
      supply + x <= TC + P,
      P' = P - x,
      lpvs' = lpvs, supply' = supply,
      nftAtVault' = nftAtVault, isOpen' = isOpen, cred' = cred, live' = live, rs' = rs, acct' = acct,
      arsc' = arsc, sh' = sh, TC' = TC, hub' = hub,
    }
  }

  // Non-conforming LPVaultSwap: has the Adapter burn held units and never settles.
  action orphanBurn = {
    nondet y = 1.to(10).oneOf()
    all {
      y <= lpvs,
      lpvs' = lpvs - y, supply' = supply - y,
      nftAtVault' = nftAtVault, isOpen' = isOpen, cred' = cred, live' = live, rs' = rs, acct' = acct,
      arsc' = arsc, sh' = sh, TC' = TC, P' = P, hub' = hub,
    }
  }

  action step = any { pledge, donate, seize, seizeUnsettled, withdraw, removePartial, recredit,
                      deleverage, releaseZero, settlePending }
  action stepOrphan = any { step, orphanBurn, settlePendingNoBurn }

  // Invariants
  val backingEq = supply == TC + P
  val backingLe = supply <= TC + P
  val creditSum = TC == NFTS.fold(0, (s, t) => s + cred.get(t))
  val accountSum = PROXIES.forall(p => acct.get(p) == sumOf(cred, p))
  val sharesBelowCredit = PROXIES.forall(p => sh.get(p) >= 0 and sh.get(p) <= acct.get(p))
  val liveCoversCredit = NFTS.forall(t => isOpen.get(t) implies live.get(t) >= cred.get(t))
  val custodyIffRecord = NFTS.forall(t => isOpen.get(t) == nftAtVault.get(t))
  val unitsAtRest = supply == hub + lpvs
  val rescueBound = NFTS.forall(t => rs.get(t) >= 0 and rs.get(t) <= cred.get(t)
                                     and (not(isOpen.get(t)) implies rs.get(t) == 0))
  val rescueSum = PROXIES.forall(p => arsc.get(p) == sumOf(rs, p))
  // T-19: every open record with credit left after reconciliation can be withdrawn
  // (its previewRelease units are at most the proxy's supplied shares).
  val exitLive = NFTS.forall(t => isOpen.get(t) implies {
    val p = WALLET.get(t)
    val sf = max0(acct.get(p) - sh.get(p))
    val units = debit(cred, isOpen, p, sf)._1.get(t)
    units <= sh.get(p)
  })
  val ledger = creditSum and accountSum and sharesBelowCredit and liveCoversCredit
               and custodyIffRecord and unitsAtRest and rescueBound and rescueSum and exitLive
  val inv = backingEq and ledger
  val invOneSided = backingLe and ledger
}
