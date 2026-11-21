# Pre-merge security

PR CI runs the same policy scan on the complete PR diff, title, body and branch name. If it finds a policy violation, the workflow fails and cancels the other queued or running CI workflows associated with that PR. GitHub schedules independent workflows concurrently, so this fast scan cannot be guaranteed to start before every other workflow; cancellation occurs as soon as its failure step runs.

The names and terminology policy is in [`.github/security/premerge-names.json`](../../.github/security/premerge-names.json), owned by the security team in CODEOWNERS. Add unreleased codenames to `restricted_names` and incorrect phrases with their preferred term to `incorrect_terminology`. The checked-in AI/tool list is an initial maintained vocabulary, not a complete list of every product or model.

## Email DLP

Git hooks cannot see messages composed in Outlook or Gmail. For automatic pre-send enforcement, configure both mail tenants:

### Microsoft 365

In Microsoft Purview, create a DLP policy scoped to Exchange email. Add sensitive information types or custom detectors for secrets, credential-bearing RPC URLs, internal endpoints, restricted names and confidential release language. Start in simulation or policy-tip mode, review false positives, then block or require approval for matches sent outside the organization. Exchange DLP supports content conditions and actions for outgoing mail; see Microsoft's [Exchange DLP conditions and actions](https://learn.microsoft.com/en-us/purview/dlp-exchange-conditions-and-actions) and [DLP policy reference](https://learn.microsoft.com/purview/dlp-policy-reference).

### Google Workspace

In the Admin console, open **Security → Access and data control → Data protection → Manage rules**. Create Gmail outbound data-protection rules using custom detectors/regular expressions for the same policy, initially warn or audit, then block external sends after tuning. Google describes Workspace DLP and Gmail data protection in its [DLP administration guide](https://knowledge.workspace.google.com/admin/security/about-dlp) and [Gmail content filtering guidance](https://knowledge.workspace.google.com/admin/gmail/advanced/enhance-rules-for-advanced-email-content-filtering-with-predefined-detectors).

As a local helper for a saved draft, run `python contracts/script/premerge_scan.py --email-file <draft.txt>`. This is a manual check; it does not replace either provider's pre-send DLP enforcement. Keep exception review security-owned and do not log message bodies in DLP alerts.

