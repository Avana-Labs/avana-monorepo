"""Counters for outcomes, failures, frustrations and invariant checks."""
from collections import Counter, defaultdict

# Frustration codes: what the user would say, the cause in the spec, the fix and
# where the fix belongs. The engine counts the users who hit each one.
FRUSTRATIONS = {
    'cap_full': ("The market is full, so I can't pledge.",
                 'marketUsdCap per market (1.5, Q-055); caps fill on a first-come basis and a debt-free pledger keeps its cap room while earning fees',
                 'Show remaining cap room and a queue/notify-when-room; publish cap-raise plans; consider a per-wallet share of new cap room', 'app + governance'),
    'low_ltv': ('I can only borrow about $28 per $100 of LP.',
                'LP CF = min(CF0, CF1) x poolRiskFactor (~25-31%) and then minOpeningHealthFactor 1.10 on top (Q-018)',
                'Show the effective borrow limit before pledging; raise poolRiskFactor for the deepest pools after a track record', 'app + risk'),
    'concentrated_rejected': ('My concentrated-range position was rejected; full range earns far less in fees.',
                              'Full-range positions only (Q-017, DEP-007 NotFullRange)',
                              'Explain before the NFT approval, show the fee-yield difference, offer a one-click convert; concentrated ranges are a later expansion', 'app (now), contracts (later)'),
    'below_min': ('My small position is below the $10 minimum.',
                  'minPledgeUsd = $10 (Q-230)', 'Pre-check value before approval; state the minimum on the pledge screen', 'app'),
    'gas_exceeds_value': ('The gas to pledge and borrow cost more than I can borrow.',
                          'minPledgeUsd $10 can be below the gas cost of approve + pledge + borrow (about $0.27-3.20 at 0.1-1.2 gwei, about $80 at 30 gwei, ETH $2,080)',
                          'Raise minPledgeUsd to a gas-aware level (e.g. $500-1,000) or show a break-even warning', 'app + parameter'),
    'borrow_blocked_price': ("Borrow is blocked even though prices look normal.",
                             'Every collateral input must be Live and within borrowPriceMaxAge (1 h) at the block (BOR-006); heartbeat = max age leaves windows each hour',
                             'Set borrowPriceMaxAge >= heartbeat + margin; app explains the state and when it clears', 'spec parameter + app'),
    'borrow_blocked_other_market': ('A problem in one of my markets blocked borrowing and withdrawing in all of them.',
                                    'One PositionProxy per wallet per Spoke; worst-state rule over every collateral market (Q-081, Q-225, Q-234)',
                                    'Allow several accounts per wallet (proxy index) so markets can be isolated; app shows which market blocks', 'contracts + app'),
    'max_borrow_reverted': ("I pressed 'max' and the borrow reverted.",
                            'BOR-011 checks HF >= 1.10 after the call; interest accrues between preview and inclusion, so a borrow sized to exactly 1.10 fails',
                            'App sizes "max" to 1.10 plus a margin (e.g. +0.5%), and the spec states that margin', 'app (+ spec note)'),
    'topup_refused_paused': ("I wanted to add collateral during the pause and couldn't, then I was liquidated.",
                             'Paused refuses top-ups (EMG-018, Q-227) while liquidation continues (LIQ-002)',
                             'Allow top-ups in Paused (they only add collateral) or make the pause reason explicit and pair it with a repay prompt', 'contracts/spec + app'),
    'topup_refused_stale': ("I couldn't add collateral during the price outage.",
                            'Top-ups need Live or Drifting (Q-132); Cached/Expired refuse them',
                            'App suggests repay (always open) during outages; notify when top-ups reopen', 'app'),
    'topup_refused_pool_share': ('My rescue top-up was refused because Avana holds too much of the pool.',
                                 'Pool-share cap applies to every pledge, including rescue top-ups (REQ-RISK-023, SPEC-CAP-005); in-range liquidity collapses in a depeg',
                                 'Exempt top-ups of indebted accounts below 1.10 (up to the restore amount) from the pool-share test, as the slice already is from token/depositor caps', 'contracts/spec'),
    'topup_refused_slice': ('My top-up was refused because the market is full, even though my account is getting weak.',
                            'Slice only while HF < 1.10 and only up to the restore amount (Q-157); pre-emptive top-ups at HF 1.10-1.3 need regular room',
                            'Allow slice top-ups up to a higher rescue target (e.g. HF 1.25) and show slice room', 'spec parameter + app'),
    'liquidated': ('I was liquidated.', 'HF < 1 (LIQ-003)', 'Alerts, previews of liquidation price, rescue paths', 'app'),
    'liquidated_unable_to_act': ('I tried to save my position but the protocol refused my top-up, then I was liquidated.',
                                 'Rescue paths refused by Paused / price state / pool share while liquidation ran',
                                 'See topup_refused_*; app routes the user to repay or third-party repay', 'contracts/spec + app'),
    'no_alerts': ("Nobody told me my position was at risk.", 'The app plan has no notification service (webapp/README.md)',
                  'Opt-in health alerts (email/push/Telegram) at user-chosen HF levels via the indexer', 'app/services'),
    'liquidated_good_collateral': ('The crash was in one market but my other, healthy LP was seized.',
                                   'Keeper chooses the market per call (LIQ-052); one account across markets',
                                   'Let users isolate markets in separate accounts; show which collateral would be seized first', 'contracts + app'),
    'whole_nft_withdraw': ('To take out part of my liquidity I have to repay and withdraw the whole NFT.',
                           'Withdrawal returns one whole NFT; units must equal credited units (WDR-014); no partial decrease while pledged',
                           'Add a partial-decrease path that removes liquidity from a pledged NFT subject to the same HF checks', 'contracts'),
    'donation_not_credited': ('I added liquidity to my pledged position but my health factor did not change.',
                              'NFPM.increaseLiquidity on a pledged NFT is a donation; credit is read only at pledge (DEP-009, Q-134)',
                              'Add a re-credit (top-up of an existing record) path or warn in the app and integrations', 'contracts + app'),
    'exit_needs_external_funds': ('I have to find outside GHO/USDC to close; I cannot repay with my collateral.',
                                  'No repay-with-collateral / self-deleverage path; withdraw-with-debt needs HF >= 1.10 after',
                                  'Add a self-deleverage call that unwinds part of the pledged liquidity to repay (reusing LPVaultSwap routes, no bonus)', 'contracts'),
    'repay_short_interest': ('Repay-all failed because my debt grew while my transaction was pending.',
                             'Repay-all pulls the live debt at inclusion (REP-005); the app approves exactly the quoted amount (webapp/README.md)',
                             'Quote debt at the deadline and approve that cap; the spec should state the margin rule', 'app + spec'),
    'deadline_expired': ('My transaction failed with DeadlineExpired.', 'Deadline checked on every call (DEP-002, BOR-003)',
                         'Longer default deadline on mobile; re-prepare automatically', 'app'),
    'tx_dropped': ('My transaction never confirmed.', 'Slow network / low fee', 'Fee bumping and pending-tx status in the app', 'app'),
    'bad_nonce': ('My second borrow failed with BadNonce.', 'One borrow nonce per proxy (Q-106)', 'Single pending borrow across tabs/devices (already planned); clear message', 'app'),
    'units_mismatch': ('My withdrawal failed because the units changed.', 'units must equal credited units at inclusion (WDR-014); a liquidation in between changes them',
                       'Accept a "whole record" sentinel (units = 0 meaning current credited units) with a minimum', 'contracts'),
    'fees_manual': ('I collect fees and then repay by hand; it should be one step.', 'Fees always go to the depositor (Q-105); no collect-and-repay',
                    'Batch collect + swap + repay (EIP-5792 batch in the app, or an Adapter helper)', 'app (contracts optional)'),
    'depositor_cap_split': ('I hit the per-depositor cap and had to split across wallets.', 'depositorUsdCap (Q-055) is per wallet and easy to bypass with more wallets',
                            'Either accept and document, or drop the per-depositor cap in favour of market/token caps', 'governance'),
    'drawcap_exhausted': ('Borrowing is unavailable: the credit line is used up.', 'GHO credit line 2,000,000 (Q-006) / Hub drawCap', 'Show remaining credit line; raise with demand', 'app + Aave governance'),
    'paused_withdraw_with_debt': ('During the pause I could not take one NFT out while keeping my loan.',
                                  'Paused refuses withdraw-with-debt (Q-227)', 'App offers repay-all-and-withdraw (works in Paused)', 'app'),
    'zero_credit_nft_left': ('After a full liquidation my NFT (with its fees) is still in the vault.',
                             'Zero-credit records need releaseZeroCredit (WDR-019)', 'App prompts release; consider auto-release in the liquidation that empties the record', 'app (contracts optional)'),
    'usdc_feed_stall_blocked': ('My USDC loan could not be changed while the USDC price feed stalled.',
                                'A debt reserve has one Aave price source and no alternate route (Q-238); stale -> borrow, withdraw-with-debt and liquidation stop',
                                'Give debt reserves the same primary/alternate route model as collateral legs', 'contracts/spec'),
    'band_blocked_gho_premium': ('Borrowing GHO stopped exactly when GHO traded above $1.',
                                 'USD band uses uncapped prices (SPEC-ORC-011); GHO above ~$1.0404 breaches usdBandHigh 1.02 although REQ-ORACLE-009 says GHO markets stay Live above peg',
                                 'Test the upper band on capped prices, or only on a common-mode move of both tokens', 'contracts/spec'),
    'twap_griefed': ('Borrowing was blocked for hours in a thin pool for no visible reason.',
                     'TWAP guard (SPEC-ORC-010) can be pushed in a drained pool; Drifting blocks borrow/withdraw-with-debt',
                     'Monitor pool depth vs listing threshold; offboard/cap when depth falls; explain Drifting(TWAP) in the app', 'risk ops + app'),
    # outcomes and refusals of the rules added by Q-241 to Q-278 (the final spec)
    'borrow_blocked_breaker': ('Borrowing stopped because a circuit breaker tripped on one of my markets.',
                               'Market and debt breakers stop new borrowing and withdraw-with-debt (Q-241)',
                               'App names the breaker and when it clears; repay and rescue top-ups stay open', 'app'),
    'rescue_refused_pool_share': ('My rescue top-up was refused because Avana holds too much of the pool.',
                                  'A rescue top-up is exempt from the pool-share cap only up to its restore amount (Q-252)',
                                  'App sizes the top-up to Lens usdToRestore', 'app'),
    'rescue_refused_breaker': ('My rescue top-up was refused while a breaker was tripped.',
                               'Rescue top-ups are exempt from breakers up to the restore amount (Q-252)', 'App sizes to the restore amount', 'app'),
    'rescue_refused_size': ('My top-up was refused as larger than a rescue.',
                            'An exempted top-up must not exceed the restore amount (REQ-RISK-066)', 'App offers the restore amount', 'app'),
    'topup_refused_breaker': ('My top-up above HF 1.10 was refused while a breaker was tripped.',
                              'Only rescue top-ups pass a tripped market breaker (Q-241, Q-252)', 'App explains; rescue opens below 1.10', 'app'),
    'topup_refused_not_rescue': ('My top-up was refused during the pause.',
                                 'Paused(General) and a frozen address admit only rescue top-ups (Q-252, EMG-018)',
                                 'App explains that top-ups open below HF 1.10 and offers repay', 'app'),
    'rescued_by_topup_exemption': ('A rescue top-up went through although the market was constrained.',
                                   'Rescue exemption from pool share, breakers, Paused(General) and the address freeze (Q-252)', '-', 'outcome'),
    'used_repay_with_collateral': ('I repaid part of my loan with my own LP.', 'repayWithCollateral (Q-255)', '-', 'outcome'),
    'exit_via_repay_with_collateral': ('I closed my loan with my own LP instead of outside funds.', 'repayWithCollateral (Q-255)', '-', 'outcome'),
    'deleverage_refused': ('Repay with collateral was refused.',
                           'It needs fresh liquidation-grade prices, Paused refuses it, routes must meet the per-leg minimum (Q-255)',
                           'App explains the gate; repay with outside funds stays open', 'app'),
    'used_partial_removal': ('I took part of my liquidity out without withdrawing the NFT.', 'removeLiquidity (Q-254)', '-', 'outcome'),
    'partial_removal_refused': ('My partial removal was refused.',
                                'With debt it is a withdraw-with-debt: gates, rescue-excluded HF >= 1.10 and a $10 remaining record (Q-254)',
                                'Preview the largest removal that passes', 'app'),
    'recredit_refused': ('My added liquidity could not be credited yet.',
                         'recredit is a top-up with every top-up check, caps included (Q-254)', 'App shows cap room and retries', 'app'),
}


class Metrics:
    def __init__(self):
        self.app_refusals = Counter()          # (action, reason)
        self.app_refusal_users = defaultdict(set)
        self.reverts = Counter()               # (action, error)
        self.revert_users = defaultdict(set)
        self.revert_gas = Counter()
        self.successes = Counter()
        self.frust = defaultdict(set)          # code -> users
        self.frust_events = Counter()
        self.liquidations = []
        self.liq_blocked = Counter()           # reason -> account-scans (10 min each)
        self.liq_blocked_accounts = defaultdict(set)
        self.invariant_checks = Counter()
        self.invariant_violations = []
        self.attacks = []
        self.governance = []
        self.borrow_window = Counter()         # (market, allowed?) per minute sample
        self.notes = []

    def frustrate(self, code, uid, n=1):
        self.frust[code].add(uid)
        self.frust_events[code] += n

    def refusal(self, action, reason, uid):
        self.app_refusals[(action, reason)] += 1
        self.app_refusal_users[(action, reason)].add(uid)

    def revert(self, action, err, uid, gas_usd):
        self.reverts[(action, err)] += 1
        self.revert_users[(action, err)].add(uid)
        self.revert_gas[(action, err)] += gas_usd

    def check(self, name, ok, detail=''):
        self.invariant_checks[name] += 1
        if not ok:
            self.invariant_violations.append((name, detail))
