# REDCap REST — improvement increment plan

A sequencing plan for the configuration and observability improvements described
in [`oauth2-config-improvements.md`](./oauth2-config-improvements.md). That
document is the rationale and detail; this document is the delivery plan — scope,
order, deliverables, and which items need a spec.

## Guiding principles

- **Ship small, independent increments.** Prefer several focused PRs over one
  large change.
- **Order by value-to-risk.** Do the high-value, low-risk items first; defer the
  items with design unknowns until a spike resolves them.
- **Fork-local for now.** All increments in this plan are **fork-local**: branch
  from `deploy-utilities` and merge back there. Do **not** open upstream PRs for
  these without an explicit decision to do so. (Two upstream PRs already exist —
  `lsgs/redcap-rest` #9 token-ref fix, #10 403-retry — but those are separate and
  not part of this plan.)
- **Verify in the live dialog.** Any change to `config.json` label strings or the
  configuration dialog must be checked against the rendered dialog and the
  summary page, because label strings are also consumed as summary-page column
  headers in `REDCapREST.php`.

## For implementers (handoff context)

Read this before starting any increment. A session picking up this work has no
memory of the conversation that produced it.

- **Repository state.** Work happens in the `naccdata/redcap-rest` fork. The
  active working branch is `deploy-utilities`, which already contains: the
  build/deploy tooling, a merged 403-retry fix, and the merged multi-token-ref
  fix (`pipeApiToken` resolving all `[token-ref:...]` placeholders).
- **Base branch for every increment:** branch from **`deploy-utilities`** and
  merge back into it. All increments here are **fork-local** (see Guiding
  Principles). Use a descriptive branch per increment, e.g.
  `feat/token-exchange-logging`.
- **Open upstream PRs (context, not a constraint):** `lsgs/redcap-rest` #9
  (token-ref fix) and #10 (403-retry) are open against the upstream maintainer.
  Increment A touches `OAuth2ClientCredentials.php` and Increment C touches
  `REDCapREST.php` — both files overlap with that upstream work, so expect those
  files to differ from upstream `main`; branching off `deploy-utilities` (not
  `main`) avoids surprises.
- **Files/symbols to read first, by increment:**
  - A (logging): `OAuth2ClientCredentials.php` (`updateAccessToken`,
    `oauth2Call`), `OAuth2.php` (constructor, `$resolvedTokens` masking),
    `REDCapREST.php` (`curlCall` and the `redcap_save_record` log-masking path).
  - C (labels): `config.json` (`name` strings for `dest-url` and the
    `token-management` `token-url`), and `REDCapREST.php` `summaryPage()` (column
    headers derived from label strings).
  - D (validation): `Instruction.php` (`getConfigErrors()`/`getConfigWarnings()`)
    and `summary.php` (where warnings render).
  - E (surface keys): `REDCapREST.php` `redcap_module_configuration_settings()`
    (already implemented — the injection point).
- **Verification commands.** Tests: `composer install` then
  `./vendor/bin/phpunit --configuration phpunit.xml`. Note `php`/`composer` may
  not be on PATH in all environments — confirm availability first. Build the
  deployable module with `./build.sh <version>`; deploy is NACC-specific and
  ephemeral (`./deploy.sh <version>`) — do not deploy as part of these increments
  unless asked.
- **Detail reference:** rationale, framework findings, and the candidate label
  table live in [`oauth2-config-improvements.md`](./oauth2-config-improvements.md).

## Increment tiers at a glance

| Tier | Increment | Size | Spec needed? | Upstream candidate? |
|---|---|---|---|---|
| 1 | A. Token-exchange logging | Small | No | Yes |
| 1 | B. Documentation + cross-config walkthrough | Small | No | Yes |
| 1 | C. Config field-label review | Small (fiddly) | No (agree wording first) | Yes |
| 2 | D. Config validation + scope-match warnings | Medium | Lightweight | Yes |
| 2 | E. Surface system token-ref keys in project dialog | Medium | Lightweight | Maybe |
| 3 | F. Conditional field display | Medium–Large | Yes + spike | Maybe |
| 3 | G. Project-side "validate configuration" action | Large | Yes | Maybe |

---

## Tier 1 — ship now, independent, no spec

Three self-contained changes that do not depend on each other and can each be a
separate PR. These clear the two issues that most directly caused the recent
troubleshooting session (A and C).

### Increment A — Token-exchange logging

- **Goal:** make the OAuth2 token exchange observable so a failure is diagnosable
  from the logs alone.
- **Scope:** `OAuth2ClientCredentials.php` (possibly a shared helper in
  `OAuth2.php`). Log the token endpoint URL, the HTTP status code, and a
  **masked** response body on the exchange; on failure, include status + masked
  body in the message rather than the bare "Unable to obtain access token".
- **Masking:** reuse the resolved-token map; also mask the returned
  `access_token`. No secret or token value may appear unmasked in any log.
- **Deliverables:** code change + unit test covering a failed exchange logs the
  status and masks credentials; full PHPUnit suite green.
- **Done when:** a forced 401/500 at the token endpoint produces a log entry that
  shows the endpoint and status with no unmasked secret.

### Increment B — Documentation + cross-config walkthrough

- **Goal:** document the non-obvious setup, especially the system↔project round
  trip.
- **Scope:** `README.md` (and/or field help). Add: `auth-url` must be the full
  token path (nothing is appended); for OAuth2, `[token-ref:...]` entries are
  scope-checked against the resource `dest-url`, not the auth URL; the
  `username`/`password` keys in the OAuth2 example are unused by
  client-credentials; a worked "system first, then project" walkthrough naming
  the same key in both dialogs.
- **Deliverables:** documentation only; no code.
- **Done when:** a new user can follow the walkthrough end-to-end without hitting
  the scope-mismatch or bare-host-`auth-url` traps.

### Increment C — Config field-label review

- **Goal:** remove ambiguous/overloaded labels, chiefly the two different
  "Destination URL" fields.
- **Scope:** `config.json` `name` strings (and dependent summary-page column
  headers in `REDCapREST.php`). Candidate relabels are listed in the improvements
  doc (resource URL vs. token scope-prefix, `token-ref` wording, OAuth2 example
  `auth-url` path, etc.).
- **Wording is part of the task, with an approval checkpoint.** The task
  proposes the exact replacement strings (starting from the candidate table in
  the detail doc) and presents them for human approval *before* finalizing.
  Labels are user-facing, so a person signs off on the words; the task is not
  blocked waiting for wording to be handed to it.
- **Risk/verification:** preserve existing HTML markup/classes; build and check
  the live project dialog, system dialog, and summary page render correctly.
- **Deliverables:** proposed wording (for approval) → label edits + any mirrored
  summary-page header updates in `REDCapREST.php`; visual verification notes.
- **Done when:** proposed wording is approved, and both dialogs and the summary
  page render with the approved labels and no broken markup.

**Tier 1 exit:** three merged PRs (A, B, C). Reassess whether Tier 2 is warranted
based on how often setup issues recur.

---

## Tier 2 — validation layer (lightweight spec)

Shares a home (`Instruction.php` config warnings surfaced on `summary.php`, and
the `redcap_module_configuration_settings` hook the module already implements).
Build after Tier 1.

**Why a lightweight spec:** the value is in getting the warning *conditions*
right so they match real failure modes without false positives. A short written
list of "warn when X" rules is enough — no full requirements/design/tasks cycle.
This can be a section appended to the improvements doc.

### Increment D — Config validation + scope-match warnings

- **Goal:** catch the two most common setup errors at configuration time instead
  of at send time.
- **Scope:** extend `Instruction::getConfigWarnings()` (and/or errors) to warn
  when: OAuth2 type is selected but `oauth2-config` is empty/invalid JSON or
  missing `auth-url`/`client-id`/`client-secret`; `auth-url` has no path
  component (likely bare host); a referenced `[token-ref:X]` has no system entry
  whose scope URL is a prefix of the message's `dest-url` (or `auth-url` for
  OAuth2).
- **Note:** no framework URL validator exists; this is custom logic.
- **Deliverables:** warning logic + tests + summary-page display; spec section
  listing exact conditions.
- **Done when:** a mis-scoped token-ref or incomplete OAuth2 config is flagged on
  the summary page before any record is saved.

### Increment E — Surface system token-ref keys in the project dialog

- **Goal:** eliminate the "remember and retype the exact key" guesswork.
- **Scope:** via `redcap_module_configuration_settings`, render the list of
  defined system `token-ref` **keys** (names only, never values) as help text
  near fields that accept them.
- **Open questions for the spec section:** what is cleanly accessible from a
  project context, and the permission implications of exposing system key names
  to project users.
- **Deliverables:** hook enhancement + tests where feasible; manual dialog
  verification.
- **Done when:** the project dialog lists available token-ref key names so a user
  can copy an exact key.

---

## Tier 3 — ambitious UX (full spec + spike)

Most new surface area and real design unknowns. Do last. These are good
candidates for Kiro **Spec** sessions (requirements → design → tasks).

### Increment F — Conditional field display

- **Goal:** show OAuth2/token sub-fields only when relevant (OAuth2 type
  selected; the lookup-vs-specify band matching the chosen option) to reduce the
  "everything shown at once" confusion.
- **Required first step — research spike:** the framework docs flag that
  `branchingLogic` has known issues *inside `sub_settings`*, which is exactly
  where these fields live. Spike: determine whether `branchingLogic` works in
  sub_settings in the target framework version. The outcome decides the design
  (native `branchingLogic` vs. doing it through the
  `redcap_module_configuration_settings` hook).
- **Spec needed:** yes — design depends on the spike result.
- **Done when:** irrelevant OAuth2/token fields are hidden until their governing
  option is chosen, verified in the live dialog.

### Increment G — Project-side "validate configuration" / "test" action

- **Goal:** collapse the two-surface round trip into a single check: resolve
  referenced keys, verify existence and scope match against the configured URL,
  report pass/fail **without** sending a real request or exposing values.
- **Scope:** new AJAX action (declared in `auth-ajax-actions`), resolution logic,
  masking, and dialog UI.
- **Spec needed:** yes — meaningful UI/AJAX/security surface.
- **Done when:** a user can validate a message's token wiring from the project
  dialog and get an actionable pass/fail without saving a record or leaking
  values.

---

## Recommended path

1. **Start Tier 1 now**, as three independent PRs. Suggested order: **C** (labels
   — wording agreed inline, file already open), then **A** (logging), then **B**
   (docs). Decide upstream vs. fork per PR.
2. **Pause and reassess** after Tier 1. If setup issues keep recurring, write the
   lightweight Tier 2 spec section and build **D**, then **E**.
3. **Spec Tier 3** only when there is appetite for the larger UX work; begin with
   the **F** branchingLogic-in-sub_settings spike before committing to a design.

## Decisions

Resolved:

- **Upstream vs. fork:** all increments are **fork-local** (branch from and merge
  to `deploy-utilities`). Revisit only by explicit decision.
- **Label wording (Increment C):** produced *within* the task and approved by a
  human before finalizing (see Increment C).

Still open (owner input, not blocking Tier 1):

- Whether Tier 2/3 are in scope at all, or whether Tier 1 is sufficient for now.
  Decide after Tier 1 ships.
