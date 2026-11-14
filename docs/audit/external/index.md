# External audit reports

Every report from an external audit or formal-verification engagement on Avana code is committed here as a PDF and listed in the table below. A report is valid only for the commit it audited: the deployment check compares deployed bytecode with the build of a tagged release, and this table ties each release back to the audited commit and the commit that fixed the findings.

**File name:** `YYYY-MM-DD_<Scope>_<Firm>.pdf`, where the date is the report's final delivery, `<Scope>` names what was reviewed in PascalCase (for example `CoreContracts`, `LPOracle`, `Keeper`) and `<Firm>` is the reviewing firm's name without spaces. A revised report keeps its scope and firm and takes the new date; the earlier file stays.

| Date | Firm | Scope | Audited commit | Fix commit | Release | Report | Findings |
|---|---|---|---|---|---|---|---|

Columns:

- **Audited commit** and **Fix commit**: full 40-character commit hashes. The release built from the fix commit (or a later commit with no change to the audited files) is the one a verified manifest may name.
- **Release**: the `vX.Y.Z` tag that first shipped the fixes ([`CHANGELOG.md`](../../../CHANGELOG.md)).
- **Findings**: the `FINDING-NNN` range in [5.3 Audit Findings](../../spec/05-verification/03-audit-findings.md) and the rows of [`findings-register.md`](../findings-register.md) the report produced.

The scope each engagement covers is set in [`../README.md`](../README.md#scope-q-115). [`SECURITY.md`](../../../SECURITY.md) links this index.
