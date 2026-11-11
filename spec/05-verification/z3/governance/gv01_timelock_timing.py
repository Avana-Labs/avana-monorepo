# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-GOV-01..15: AvanaTimelock timing, cancel rights, the application pause state and the
governance-bounded settings ([2.15] SPEC-GOV-001..014).

Timelock:
  requiredDelay(batch) = SHORT_DELAY if the batch is non-empty and every call has a selector (payload of
                         at least 4 bytes) whose (target, selector) pair is on the short-delay list,
                         else normalDelay, with MIN_NORMAL_DELAY <= normalDelay <= MAX_DELAY.
  schedule at t_s with delay d >= requiredDelay: readyAt = t_s + d.
  executable(t) <=> readyAt <= t < readyAt + GRACE_PERIOD;  expired(t) <=> t >= readyAt + GRACE_PERIOD.
All times are integer seconds (block.timestamp); no rounding.
Constants: SHORT_DELAY 43,200; MIN_NORMAL_DELAY 345,600; MAX_DELAY 432,000; GRACE_PERIOD 1,209,600;
launch normalDelay 432,000.
"""
from z3 import Int, Ints, Bool, Bools, If, And, Or, Not, Implies, BoolVal
from _common import check, done

SHORT, MIN_NORMAL, MAX, GRACE, NORMAL = 43_200, 345_600, 432_000, 1_209_600, 432_000
N = 6  # calls per batch modelled


listed = [Bool(f"listed_{i}") for i in range(N)]       # (target_i, selector_i) on the short-delay list
plen = [Int(f"payloadLen_{i}") for i in range(N)]
sf = [And(plen[i] >= 4, listed[i]) for i in range(N)]  # a payload shorter than 4 bytes is never short


def required(short_flags, n, normal):
    """requiredDelay for a batch whose first n calls are real (n >= 0)."""
    all_short = And([Or(i >= n, short_flags[i]) for i in range(N)])
    return If(And(n >= 1, all_short), SHORT, normal)


n, normal, t_s, d, t = Ints("n normal t_s d t")
base = [n >= 0, n <= N, normal >= MIN_NORMAL, normal <= MAX, t_s >= 0, d >= required(sf, n, normal)] + \
       [plen[i] >= 0 for i in range(N)]
ready = t_s + d

# MATH-GOV-01 verifies: SPEC-GOV-001, REQ-ACCESS-141
check("MATH-GOV-01",
      "requiredDelay is SHORT_DELAY only when every call is short-listed with a 4-byte selector, else normalDelay "
      "(a short payload or an empty batch takes normalDelay); always in [SHORT, MAX]",
      base + [Or(required(sf, n, normal) < SHORT,
                 required(sf, n, normal) > MAX,
                 And(Or([And(i < n, Not(sf[i])) for i in range(N)]), required(sf, n, normal) != normal),
                 And(Or([And(i < n, plen[i] < 4) for i in range(N)]), required(sf, n, normal) != normal),
                 And(n == 0, required(sf, n, normal) != normal))],
      "PROVED")

# MATH-GOV-02 verifies: SPEC-GOV-002, REQ-ACCESS-118
check("MATH-GOV-02",
      "an operation executes only in [t_s + requiredDelay, t_s + d + GRACE): never early, never after grace",
      base + [ready <= t, t < ready + GRACE,
              Or(t - t_s < required(sf, n, normal), t >= t_s + d + GRACE)],
      "PROVED")

# MATH-GOV-03: lowering normalDelay. The change is itself an operation on the timelock (never short-listed),
# so it waits the OLD normal delay; an operation scheduled after it executes waits the NEW one.
old, new, t0, d0, t1, t2, d2, t3 = Ints("old new t0 d0 t1 t2 d2 t3")
lower = [old >= MIN_NORMAL, old <= MAX, new >= MIN_NORMAL, new <= MAX, new < old, t0 >= 0,
         d0 >= old, t1 >= t0 + d0, t1 < t0 + d0 + GRACE,       # setNormalDelay executes in its window
         t2 >= t1, d2 >= new, t3 >= t2 + d2]                     # next operation scheduled after the change
# MATH-GOV-03 verifies: SPEC-GOV-003, SPEC-GOV-015, REQ-ACCESS-029
check("MATH-GOV-03",
      "from scheduling a delay cut to the first operation under the new delay takes >= old + new >= 2 x MIN_NORMAL_DELAY (8 days)",
      lower + [Or(t3 - t0 < old + new, t3 - t0 < 2 * MIN_NORMAL)],
      "PROVED")

# MATH-GOV-04 verifies: SPEC-GOV-013, SPEC-GOV-002, REQ-ACCESS-126
check("MATH-GOV-04",
      "executable and expired are exclusive, and a ready operation that is not executable is expired",
      base + [t >= ready,
              Or(And(t < ready + GRACE, t >= ready + GRACE),          # both
                 And(Not(t < ready + GRACE), Not(t >= ready + GRACE)))],  # neither
      "PROVED")

# MATH-GOV-05: exit window before an upgrade. An upgrade selector is never short-listed (REQ-ACCESS-142), so
# its operation waits normalDelay. A borrower needs a reaction time r <= 259,200 s (3 days) plus k + 1
# transactions (repayAllAndWithdraw, one withdraw per further NFT, one spare), one per 12-second block.
k, r = Ints("k r")
exit_need = r + (k + 1) * 12
# MATH-GOV-05 verifies: SPEC-GOV-014, REQ-ACCESS-148
check("MATH-GOV-05",
      "launch normal delay 432,000 s: exit fits for any k <= 14,399 NFTs and reaction r <= 3 days",
      [k >= 0, k <= 14_399, r >= 0, r <= 259_200, t_s >= 0, d >= NORMAL, exit_need > d],
      "PROVED")

# MATH-GOV-06 verifies: SPEC-GOV-014, REQ-ACCESS-142
check("MATH-GOV-06",
      "wrong reading: if an upgrade could run at SHORT_DELAY, a 3-day reaction time could not exit first (deliberate counterexample)",
      [k >= 1, k <= 10, r >= 0, r <= 259_200, d == SHORT, exit_need > d],
      "COUNTEREXAMPLE", show=[k, r, d])

# MATH-GOV-07: application pause state with reasons (SPEC-GOV-004). States 0 None, 1 Frozen, 2 Paused; reason
# 0 None, 1 General, 2 MintPathSuspect. A caller holds any subset of APPLICATION_FREEZE_GUARDIAN (f),
# APPLICATION_PAUSE_GUARDIAN (p), APPLICATION_ADMIN (a). Actions 0 freeze, 1 pause(arg), 2 unfreeze, 3 unpause.
def step(s, rho, act, arg, f, p, a):
    ok_freeze = And(act == 0, s == 0, Or(f, a))
    ok_pause = And(act == 1, Or(p, a), Or(arg == 1, arg == 2), Or(s == 0, s == 1, And(s == 2, arg != rho)))
    ok_unfreeze = And(act == 2, s == 1, Or(p, a))
    ok_unpause = And(act == 3, s == 2, Or(p, a))
    s2 = If(ok_freeze, 1, If(ok_pause, 2, If(Or(ok_unfreeze, ok_unpause), 0, s)))
    r2 = If(ok_pause, arg, If(Or(ok_unpause, ok_unfreeze, ok_freeze), 0, rho))
    return s2, r2


K_STEPS = 4
f, p, a = Bools("f p a")
s0, rho0 = Ints("s0 rho0")
acts = [Int(f"act_{i}") for i in range(K_STEPS)]
args = [Int(f"arg_{i}") for i in range(K_STEPS)]
states, reasons = [s0], [rho0]
for i in range(K_STEPS):
    s_, r_ = step(states[-1], reasons[-1], acts[i], args[i], f, p, a)
    states.append(s_)
    reasons.append(r_)
dom = [And(x >= 0, x <= 3) for x in acts] + [And(x >= 0, x <= 2) for x in args]
init = [Or(And(s0 == 0, rho0 == 0), And(s0 == 1, rho0 == 0), And(s0 == 2, Or(rho0 == 1, rho0 == 2)))]
# MATH-GOV-07 verifies: SPEC-GOV-004, REQ-ACCESS-086, REQ-ACCESS-124
check("MATH-GOV-07",
      f"a key holding only APPLICATION_FREEZE_GUARDIAN never returns Frozen or Paused to None and never changes a pause reason in {K_STEPS} calls",
      dom + init + [Or(s0 == 1, s0 == 2), f, Not(p), Not(a),
                    Or(Or([x == 0 for x in states[1:]]), Or([r != rho0 for r in reasons[1:]]))],
      "PROVED")
# MATH-GOV-07 verifies: SPEC-GOV-004, REQ-ACCESS-122
check("MATH-GOV-07b",
      f"over {K_STEPS} calls by any caller the reason is None exactly when the state is not Paused",
      dom + init + [Or([Or(And(states[i] == 2, reasons[i] == 0),
                                                  And(states[i] != 2, reasons[i] != 0)) for i in range(1, K_STEPS + 1)])],
      "PROVED")


def allowed(s, rho, op):
    """REQ-ACCESS-072/073/074/164. op: 0 new pledge (no debt), 1 ordinary top-up, 2 rescue top-up, 3 borrow,
    4 repay, 5 fees, 6 debt-free withdraw/removal, 7 withdraw with debt, 8 liquidation, 9 pending settlement,
    10 zero-credit release, 11 repay with collateral."""
    frozen_blocks = Or(op == 0, op == 3)
    general_blocks = Or(op == 0, op == 1, op == 3, op == 7, op == 11)
    mint_blocks = Or(op == 0, op == 1, op == 2, op == 3, op == 7, op == 11)
    return If(s == 0, True, If(s == 1, Not(frozen_blocks), If(rho == 1, Not(general_blocks), Not(mint_blocks))))


st, rh, op = Ints("st rh op")
pstate = [Or(And(st == 0, rh == 0), And(st == 1, rh == 0), And(st == 2, Or(rh == 1, rh == 2)))]
# MATH-GOV-08 verifies: SPEC-GOV-004, REQ-ACCESS-068, REQ-ACCESS-072, REQ-ACCESS-073, REQ-ACCESS-074, REQ-ACCESS-164
check("MATH-GOV-08",
      "repay, fees, debt-free withdrawal and removal, liquidation, pending settlement and zero-credit release are open in "
      "None, Frozen, Paused(General) and Paused(MintPathSuspect)",
      pstate + [Or(op == 4, op == 5, op == 6, op == 8, op == 9, op == 10), Not(allowed(st, rh, op))],
      "PROVED")
# MATH-GOV-08 verifies: SPEC-GOV-004, REQ-ACCESS-074, REQ-ACCESS-164
check("MATH-GOV-08b",
      "a rescue top-up is open under Paused(General) and Frozen, and no pledge of any kind (so no mint) is open under Paused(MintPathSuspect)",
      pstate + [Or(And(Or(And(st == 2, rh == 1), st == 1), op == 2, Not(allowed(st, rh, op))),
                   And(st == 2, rh == 2, Or(op == 0, op == 1, op == 2), allowed(st, rh, op)))],
      "PROVED")

# MATH-GOV-09/10: cancel rights (SPEC-GOV-005). A caller may cancel iff it holds CANCELLER_ROLE and, for a
# role-change or restoring operation, DAO_CANCELLER_ROLE. Both marks are every-call marks; the any-call
# alternative is shown to allow shielding a harmful call. daoOnly_i holds iff call i is in the immutable DAO-only
# cancel set of REQ-ACCESS-156: MarketRegistry restoreRoute, useStandbyRoute, unfreezeAddress and LPVaultSwap
# addKeeper. Membership depends on (target, selector) only.
role_call = [Bool(f"role_{i}") for i in range(N)]
dao_only = [Bool(f"daoOnly_{i}") for i in range(N)]
canc, dao = Bools("canc dao")
is_rc_any = Or([And(i < n, role_call[i]) for i in range(N)])
is_rc_all = And(n >= 1, And([Or(i >= n, role_call[i]) for i in range(N)]))
is_rest_all = And(n >= 1, And([Or(i >= n, dao_only[i]) for i in range(N)]))
has_other_call = Or([And(i < n, Not(role_call[i]), Not(dao_only[i])) for i in range(N)])
excl = [Not(And(role_call[i], dao_only[i])) for i in range(N)]      # role selectors are not in the DAO-only set
guardian = [canc, Not(dao)]                     # Emergency Guardian, Aave Protocol Guardian, multisig
may_cancel = And(canc, Or(And(Not(is_rc_all), Not(is_rest_all)), dao))
# MATH-GOV-09 verifies: SPEC-GOV-005, REQ-ACCESS-143
check("MATH-GOV-09",
      "wrong reading (any-call marking): one no-op grantRole shields a malicious upgrade batch from every non-DAO canceller (deliberate counterexample)",
      [n >= 2, n <= N] + excl + guardian + [has_other_call, Not(And(canc, Or(Not(is_rc_any), dao)))],
      "COUNTEREXAMPLE", show=[n] + role_call)
# MATH-GOV-10 verifies: SPEC-GOV-005, SPEC-GOV-006, REQ-ACCESS-019, REQ-ACCESS-143, REQ-ACCESS-156
check("MATH-GOV-10",
      "every-call marking: any batch with a call that is neither a role call nor DAO-only is cancellable by every canceller; "
      "a pure role-change or pure restoring batch only with DAO_CANCELLER_ROLE",
      [n >= 1, n <= N] + excl + guardian
      + [Or(And(has_other_call, Not(may_cancel)),
            And(Not(has_other_call), Or(is_rc_all, is_rest_all), may_cancel))],
      "PROVED")

# MATH-GOV-11: tighten predicate (lower is safer) evaluated at execution; any sequence of tighten operations
# keeps the value non-increasing and never below the liveness bound or the hard lower bound.
lo, live = Ints("lo live")
v = [Int(f"v_{i}") for i in range(K_STEPS + 1)]
req_new = [Int(f"new_{i}") for i in range(K_STEPS)]
seq = [lo >= 0, live >= lo, v[0] >= live]
for i in range(K_STEPS):
    accept = And(req_new[i] < v[i], req_new[i] >= lo, req_new[i] >= live)
    seq.append(v[i + 1] == If(accept, req_new[i], v[i]))
# MATH-GOV-11 verifies: SPEC-GOV-011, SPEC-GOV-009, REQ-ACCESS-120
check("MATH-GOV-11",
      f"{K_STEPS} tighten executions: value never rises and never falls below max(hard bound, liveness bound)",
      seq + [Or([Or(v[i + 1] > v[i], v[i + 1] < live, v[i + 1] < lo) for i in range(K_STEPS)])],
      "PROVED")

# MATH-GOV-12: keeper floor over active keepers (SPEC-GOV-008, Q-400). keeperFloor = 1 (Avana's own keeper),
# MAX_KEEPERS = 32. State: approved-and-active A, approved-and-frozen Z, approved K = A + Z.
# Actions: 0 removeKeeper(active), 1 removeKeeper(frozen), 2 freezeAddress(active keeper), 3 unfreezeAddress(frozen
# keeper), 4 addKeeper (a non-frozen address). Removal is floor-checked at execution; freezeAddress never is, and it
# may take A to 0, which halts new borrowing on the chain (LiquidationHalted) until a keeper is active again.
KEEPER_FLOOR, MAX_KEEPERS = 1, 32
A_ = [Int(f"active_{i}") for i in range(K_STEPS + 1)]
Z_ = [Int(f"frozen_{i}") for i in range(K_STEPS + 1)]
kact = [Int(f"kact_{i}") for i in range(K_STEPS)]
kseq = [A_[0] >= KEEPER_FLOOR, Z_[0] >= 0, A_[0] + Z_[0] <= MAX_KEEPERS]
removed_ok = []
for i in range(K_STEPS):
    a_, z_, k = A_[i], Z_[i], kact[i]
    rm_act = And(k == 0, a_ >= 1, a_ - 1 >= KEEPER_FLOOR)
    rm_fz = And(k == 1, z_ >= 1, a_ >= KEEPER_FLOOR)
    frz = And(k == 2, a_ >= 1)                       # never blocked by the floor
    unf = And(k == 3, z_ >= 1)
    add = And(k == 4, a_ + z_ < MAX_KEEPERS)
    removed_ok.append(Or(rm_act, rm_fz))
    kseq += [And(k >= 0, k <= 4),
             A_[i + 1] == If(Or(rm_act, frz), a_ - 1, If(Or(unf, add), a_ + 1, a_)),
             Z_[i + 1] == If(Or(rm_fz, unf), z_ - 1, If(frz, z_ + 1, z_))]
borrow_open = [c >= 1 for c in A_]                    # RiskModule: new borrowing halts only at 0 active keepers
# MATH-GOV-12 verifies: SPEC-GOV-008, REQ-ACCESS-100, REQ-ACCESS-121, REQ-ACCESS-169
check("MATH-GOV-12",
      f"{K_STEPS} keeper removals, freezes, unfreezes and additions: a removal never leaves fewer than keeperFloor = 1 "
      "active keeper, the approved list never exceeds MAX_KEEPERS = 32, and new borrowing is open iff at least 1 keeper is active",
      kseq + [Or([Or(And(removed_ok[i], A_[i + 1] < KEEPER_FLOOR),
                     A_[i + 1] + Z_[i + 1] > MAX_KEEPERS, A_[i + 1] < 0, Z_[i + 1] < 0,
                     borrow_open[i + 1] != (A_[i + 1] > 0))
                  for i in range(K_STEPS)])],
      "PROVED")

# MATH-GOV-13: no in-kind window (SPEC-GOV-010, Q-401). No governance-timed settlement state exists, and the
# PayoutEscrow is payout escrow only: a payout x whose transfer fails (revert, false or out of gas) is credited to
# its payee, so the payee's transfer plus its escrow credit equals x exactly and nothing is paid twice.
x_pay, recv, cred = Ints("payout received credited")
ok_tx, timed = Bools("transferSucceeded settlementModeTimed")
pay = [x_pay >= 0, recv == If(ok_tx, x_pay, 0), cred == If(ok_tx, 0, x_pay), Not(timed)]
# MATH-GOV-13 verifies: SPEC-GOV-010, REQ-ACCESS-055
check("MATH-GOV-13",
      "no settlement mode is governance-timed, and a refused payout is credited in full to its payee in the escrow "
      "(received + credited = x, credited = x when the transfer fails)",
      pay + [Or(timed, recv + cred != x_pay, And(Not(ok_tx), cred != x_pay), And(recv > 0, cred > 0))],
      "PROVED")

# MATH-GOV-14: liveness bounds. Any accepted graceHealthFactor g satisfies 0.90e18 <= g < 1e18 and any accepted
# graceDuration <= 7,200 s, so an account below 0.90 is never inside grace and grace ends within 2 hours.
g, hf, gd, wait = Ints("g hf gd wait")
# MATH-GOV-14 verifies: SPEC-GOV-012, REQ-ACCESS-096
check("MATH-GOV-14",
      "accepted grace settings: HF < 0.90 is never shielded and no grace wait exceeds 7,200 s",
      [g >= 9 * 10**17, g < 10**18, gd >= 0, gd <= 7_200, wait >= 0, wait <= gd, hf >= 0,
       Or(And(hf < 9 * 10**17, hf >= g), wait > 7_200)],
      "PROVED")

# MATH-GOV-15: cancel window. Cancellers can cancel at any time from scheduling until execution; execution is
# not before readyAt, so the cancel window is at least requiredDelay long.
t_exec = Int("t_exec")
# MATH-GOV-15 verifies: SPEC-GOV-007, REQ-ACCESS-020
check("MATH-GOV-15",
      "the window in which a canceller can act lasts at least requiredDelay",
      base + [t_exec >= ready, t_exec < ready + GRACE, t_exec - t_s < required(sf, n, normal)],
      "PROVED")

done()
