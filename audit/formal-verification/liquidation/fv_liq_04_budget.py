"""FV-LIQ-04: the caller funding and top-up that replaced the SettlementBudget (Q-397, Q-404; 2.11 SPEC-LIQ-010,
SPEC-LIQ-019, 2.13 SPEC-SET-001).

There is no settlement budget, and `liquidate`, the one liquidation entry point, takes no flash loan. LPVaultSwap pulls
`X = debtToCover` from the caller, measures `Kf` with `0 < Kf <= X` and passes `Kf` to `liquidationCall`, so Aave pulls
`D <= Kf`. After the swaps it computes the waterfall on `R_f = max(R, minRec)` and

    gap = max(0, D + A + B - Kf - R),   shortfall = max(0, minRec - R, gap)

pulled from the caller within its `maxShortfall`. Because `D <= Kf`, the gap never exceeds the floor gap: the caller
tops up only a floor gap, and a recovery below `D` is the caller's loss in `keeperOut = Kf + R' - D - A - B >= 0`.
The call reverts with `RecoveryBelowFloor` when the floor term exceeds `maxShortfall`; `InsufficientProceeds` is
defensive. A flash liquidation helper's loan `F` and premium `phi` are repaid by the helper from `keeperOut` and a
bounded top-up (REQ-HELPER-007); they never enter LPVaultSwap's formulas. The file keeps the FV-LIQ-04 IDs of the
budget checks; each states the property of the rule that replaced the budget rule it checked.

Every claim is linear integer arithmetic over unbounded integers; the sequence claims use N = 6 calls.
"""
import z3

from _lib import BPS, check, expect_violation, finish, prove, z_max

I_ = z3.Ints
N = 6

# ---------------------------------------------------------------- one call
X, K, D, R, mr, msf, sh, Rp, S, G, A, kr, B, kout, pulled, gap = I_(
    "X Kf D R minRec maxShortfall shortfall Rprime S G A kr B keeperOut pulled gap")
floor_t = mr - R
Rf = z_max(R, mr)
base = [X >= 1, K >= 1, K <= X, D >= 0, D <= K, R >= 0, mr >= 0, msf >= 0, G >= 0]
rule = [S == z_max(0, Rf - D), A >= 0, A <= S, A <= G, kr == z3.If(S < G, S, G) - A, B == S - A - kr,
        gap == z_max(0, D + A + B - K - R), sh == z_max(z_max(0, floor_t), gap), Rp == R + sh,
        kout == (K + Rp) - (D + A + B)]
ok = z3.And(floor_t <= msf, gap <= msf, kout >= 0)       # the call completes
call = base + rule + [pulled == sh]

# FV-LIQ-04 verifies: SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-026, REQ-SWAP-101
prove("FV-LIQ-04a", "Q-397, Q-404: whenever the floor gap is within maxShortfall the call completes, pulls exactly "
      "max(0, minRec - R) from its own caller, and after it R' >= minRec and Kf + R' >= D + A + B",
      call + [floor_t <= msf],
      z3.And(ok, pulled == z_max(0, floor_t), sh <= msf, Rp >= mr, K + Rp >= D + A + B))
drops = {"maxShortfall bound": [sh == z_max(z_max(0, floor_t), gap), Rp == R + sh],
         "floor term": [sh == gap, Rp == R + sh]}
claims = {"maxShortfall bound": sh <= msf, "floor term": Rp >= mr}
for i, (drop, rl) in enumerate(drops.items()):
    gate = [] if drop == "maxShortfall bound" else [floor_t <= msf]
    # FV-LIQ-04 verifies: SPEC-LIQ-019, REQ-SWAP-101
    expect_violation(f"FV-LIQ-04b{i}", f"mutation: drop the '{drop}' from the top-up; FV-LIQ-04a catches it",
                     base + [S == z_max(0, Rf - D), A >= 0, A <= S, A <= G, kr == z3.If(S < G, S, G) - A,
                             B == S - A - kr, gap == z_max(0, D + A + B - K - R)] + rl + gate,
                     claims[drop], label="mutant")
# FV-LIQ-04 verifies: SPEC-LIQ-019, REQ-SWAP-101, REQ-SWAP-046
prove("FV-LIQ-04c", "maxShortfall = 0: a completed call pulls nothing, so R >= minRec held already, and keeperOut >= 0",
      call + [ok, msf == 0], z3.And(sh == 0, R >= mr, kout >= 0))

# ---------------------------------------------------------------- the dust liquidation of 2.11 (USDC, 6 decimals)
d_K, d_D, d_R, d_phi = 3_000_000, 3_000_000, 2_950_000, 1_500
d_gap = max(0, d_D - d_K - d_R)
d_sh = max(0, 0 - d_R, d_gap)
d_out = (d_K + d_R + d_sh) - d_D
d_top = max(0, d_K + d_phi - d_out)
# FV-LIQ-04 verifies: SPEC-LIQ-010, SPEC-LIQ-019, REQ-SWAP-073, REQ-HELPER-007
check("FV-LIQ-04d", "dust example: Kf = D = 3 USDC, R = 2.95 USDC give gap = shortfall = 0 and keeperOut = 2.95 USDC; "
      "through the helper (F = 3 USDC, phi = 0.0015 USDC) the top-up is 0.0515 USDC",
      d_gap == 0 and d_sh == 0 and d_out == 2_950_000 and d_top == 51_500,
      f"(gap {d_gap}, shortfall {d_sh}, keeperOut {d_out}, top-up {d_top})")

# ---------------------------------------------------------------- sequences: no Avana balance pays a gap
Xs, Ks, Ds, Rs, mrs, mss, gs, shs, Rps, Ss, Gs, As_, krs, Bs, kos = (
    [z3.Int(f"{n}{i}") for i in range(N)] for n in
    ("X", "Kf", "D", "R", "minRec", "maxShortfall", "gap", "sh", "Rp", "S", "G", "A", "kr", "B", "kout"))
seq = []
for i in range(N):
    seq += [Xs[i] >= 1, Ks[i] >= 1, Ks[i] <= Xs[i], Ds[i] >= 0, Ds[i] <= Ks[i], Rs[i] >= 0, mrs[i] >= 0,
            mss[i] >= 0, Gs[i] >= 0,
            Ss[i] == z_max(0, z_max(Rs[i], mrs[i]) - Ds[i]), As_[i] >= 0, As_[i] <= Ss[i], As_[i] <= Gs[i],
            krs[i] == z3.If(Ss[i] < Gs[i], Ss[i], Gs[i]) - As_[i], Bs[i] == Ss[i] - As_[i] - krs[i],
            gs[i] == z_max(0, Ds[i] + As_[i] + Bs[i] - Ks[i] - Rs[i]),
            shs[i] == z_max(z_max(0, mrs[i] - Rs[i]), gs[i]), Rps[i] == Rs[i] + shs[i],
            kos[i] == (Ks[i] + Rps[i]) - (Ds[i] + As_[i] + Bs[i]),
            mrs[i] - Rs[i] <= mss[i]]
t_in = z3.Sum([Ks[i] + Rs[i] + shs[i] for i in range(N)])
t_out = z3.Sum([Ds[i] + As_[i] + Bs[i] + kos[i] for i in range(N)])
# FV-LIQ-04 verifies: SPEC-LIQ-010, SPEC-SET-003, INV-037
prove("FV-LIQ-04e", f"Q-397: over any {N} completed liquidations, LPVaultSwap's debt-asset balance is unchanged: the only "
      "inflows are each caller's funding, its recovery and its own top-up, and every keeperOut is >= 0",
      seq, z3.And(t_in == t_out, *[kos[i] >= 0 for i in range(N)]))
pool, draw = I_("sharedPool draw")
# FV-LIQ-04 verifies: SPEC-SET-003, SPEC-SET-006, SPEC-SET-007
expect_violation("FV-LIQ-04f", "mutation (the design before Q-397): a shared pool that pays the shortfall D - R loses "
                 "value on every call whose routes return less than the debt; FV-LIQ-04e shows caller funding keeps "
                 "Avana's balance unchanged",
                 [D >= 1, R >= 0, R < D, draw == z_max(0, D - R), pool >= draw],
                 pool - draw == pool, show=[D, R, draw], label="mutant")

# ---------------------------------------------------------------- dust sizing up front (REQ-SWAP-005)
total, margin = I_("wholeDebt LENS_DUST_MARGIN_BPS")
# FV-LIQ-04 verifies: REQ-SWAP-005, SPEC-SET-005
prove("FV-LIQ-04g", "Q-397 sizing: debtToCover = ceil(whole debt x (1e4 + margin) / 1e4) is at least the whole debt, so a "
      "dust-rule close is funded when Kf = debtToCover, and Aave never pulls more than Kf",
      [total >= 0, margin >= 0, X * BPS >= total * (BPS + margin), (X - 1) * BPS < total * (BPS + margin),
       D >= 0, D <= total, K == X], z3.And(X >= total, K >= D))

# ---------------------------------------------------------------- properties of the top-up amount
# FV-LIQ-04 verifies: SPEC-LIQ-019, REQ-SWAP-101, SPEC-SET-002
prove("FV-LIQ-04h", "the top-up is zero when the routes meet the floor (R >= minRec), whatever R is against D",
      call + [R >= mr], sh == 0)
sh2 = z3.Int("smallerPull")
prove("FV-LIQ-04i", "the top-up is the least pull that meets the floor: any smaller pull leaves R + pull < minRec",
      call + [sh2 >= 0, sh2 < sh], R + sh2 < mr)
K2, kout2 = I_("Klarger koutLarger")
prove("FV-LIQ-04j", "more caller funding never changes the top-up or the split and raises keeperOut by the same amount",
      call + [K2 >= K, K2 <= X, kout2 == (K2 + Rp) - (D + A + B)], kout2 - kout == K2 - K)
# FV-LIQ-04 verifies: SPEC-LIQ-010, SPEC-LIQ-022, SPEC-SET-001
prove("FV-LIQ-04k", "the gap never binds beyond the floor gap: gap <= max(0, minRec - R), so no part of a top-up falls "
      "outside R_f", call, gap <= z_max(0, floor_t))
gap_x, kout_x = I_("gapExt koutExt")
# FV-LIQ-04 verifies: SPEC-LIQ-019, REQ-SWAP-062, REQ-SWAP-011
expect_violation("FV-LIQ-04km", "mutation (a repayment not drawn from the measured Kf, as if a flash loan were taken "
                 "inside LPVaultSwap and not counted): with D > Kf the gap exceeds the floor gap and keeperOut can be "
                 "negative; REQ-SWAP-011 and REQ-SWAP-016 bound D by Kf",
                 [K >= 0, D >= 1, D > K, R >= 0, mr <= R, S == 0, A == 0, B == 0,
                  gap_x == z_max(0, D - K - R), kout_x == (K + R) - D],
                 z3.And(gap_x <= z_max(0, mr - R), kout_x >= 0), show=[K, D, R], label="mutant")
# FV-LIQ-04 verifies: SPEC-LIQ-019, REQ-SWAP-046
expect_violation("FV-LIQ-04l", "mutation: a top-up pulled without the maxShortfall check takes more from the caller than "
                 "it allowed; FV-LIQ-04a catches it", base + rule, sh <= msf, show=[sh, msf], label="mutant")
# FV-LIQ-04 verifies: SPEC-LIQ-010, SPEC-SET-006, INV-037
prove("FV-LIQ-04m", "a completed call is balance-neutral for LPVaultSwap: Kf + R + shortfall = D + A + B + keeperOut, "
      "with every term paid from the call's own funds", call + [ok], K + R + sh == D + A + B + kout)
# FV-LIQ-04 verifies: SPEC-SET-006, SPEC-SET-007, INV-097
prove("FV-LIQ-04n", f"over any {N} completed liquidations each caller's top-up is within its own maxShortfall and no call's "
      "top-up depends on another call", seq, z3.And(*[z3.And(shs[i] >= 0, shs[i] <= mss[i]) for i in range(N)]))
# FV-LIQ-04 verifies: SPEC-SET-007, REQ-SWAP-043, SPEC-LIQ-010
prove("FV-LIQ-04o", "keeperOut >= 0 on every call: keeperOut = Kf + kr when R' >= D and Kf - (D - R') when R' < D",
      call, z3.And(kout >= 0, z3.Implies(Rp >= D, kout == K + kr), z3.Implies(Rp < D, kout == K - (D - Rp))))
# FV-LIQ-04 verifies: SPEC-SET-007, AMMN-RT-13
prove("FV-LIQ-04p", "a market's liquidation cannot be blocked by another market's liquidations: completion depends only on "
      "the call's own R, Kf, minRec and maxShortfall (maxShortfall >= max(0, minRec - R) completes)",
      call + [msf >= z_max(0, floor_t)], ok)
# FV-LIQ-04 verifies: SPEC-SET-007, AMMN-RT-13, Q-387
expect_violation("FV-LIQ-04pm", "mutation (the design before Q-387 and Q-397): a gap paid from a balance shared by markets "
                 "lets one market's draws leave another market's liquidation unfunded; FV-LIQ-04p shows the top-up has no "
                 "shared balance", [pool >= 0, draw > 0, draw <= pool, z3.Int("otherNeed") > pool - draw],
                 z3.Int("otherNeed") <= pool - draw, label="mutant")

finish()
