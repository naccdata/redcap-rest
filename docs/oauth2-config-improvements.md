# REDCap REST — configuration & observability improvements

Notes captured after troubleshooting an OAuth2 client-credentials integration
against a test API. The integration eventually worked, but getting there
surfaced one real code bug (already fixed) plus several configuration and
observability weaknesses worth addressing.

## Background: what the troubleshooting session exposed

The symptom was a persistent `HTTP 500` / `rest_response = "Unable to obtain
access token"` in the project log on every save of the trigger form. The actual
causes, in the order they were uncovered:

1. **`auth-url` set to the base domain, not the token path.** The module POSTs
   the client-credentials exchange to `auth-url` *verbatim* — it does not append
   a path. The endpoint was `https://HOST/token`, but `auth-url` was
   `https://HOST`, so the exchange hit the wrong URL.
2. **Token-ref scope confusion** ("Token ... not found"). The `[token-ref:...]`
   scope guard checks the reference's configured URL against `$this->destURL`,
   which is the **resource** URL (`/echo`), not the token endpoint. Scoping the
   system token entries to `/token` made them fail the prefix check against
   `/echo`.
3. **The real bug — only the first `[token-ref:...]` was resolved.**
   `pipeApiToken()` used `preg_match()` (first match only) + a single
   `str_replace()`. An OAuth2 config string carries **two** references by design
   (`client-id` and `client-secret`); only `client-id` was substituted, and
   `client-secret` was sent as the literal text `[token-ref:...]`, so the token
   endpoint returned 401. Fixed (see "Status" below).
4. **A paste error in the stored secret.** After the code fix, a masked debug
   fingerprint showed `secret_len=45 secret=YY..Q=` for a secret that should be
   44 chars starting `Yh`. An extra leading character had been introduced when
   pasting the value into the config textarea — invisible in the dialog.

The through-line: the token-exchange step is the most failure-prone part of the
flow and the **least observable**. Every distinct failure collapsed into the
same generic message, and the only way to see what was actually sent was to add
temporary logging to the code.

## Proposed improvements

### 1. Log the token exchange as a first-class event (highest value)

**Problem.** The resource call gets a proper `REDCap::logEvent` ("Sent POST
to..."). The token-endpoint call only emits a terse `cURL info:` line to the EM
log (which is itself truncated), and any failure is reported solely as "Unable
to obtain access token." There is no record of the token endpoint hit, the HTTP
code it returned, or the response body.

**Change.** In `OAuth2ClientCredentials::updateAccessToken()`, log the token
exchange: the endpoint URL, the HTTP status code, and a **masked** response body
(mask any resolved token values and the returned `access_token`). On failure,
include the status and masked body in the thrown/logged message rather than the
bare "Unable to obtain access token."

**Why.** This single change would have short-circuited the entire
troubleshooting session: the 401 and the wrong endpoint would both have been
visible immediately.

**Area:** `OAuth2ClientCredentials.php` (and possibly a shared helper in
`OAuth2.php`). Should run with the PHPUnit suite.

### 2. Validate / warn on incomplete OAuth2 configuration

**Problem.** Nothing flags a missing or malformed `oauth2-config` when OAuth2
type is selected. A bare-host `auth-url` (missing the token path) fails silently
at runtime.

**Change.** Extend the existing config-warning mechanism (the `Instruction`
class already produces warnings shown on the summary page) to warn when:
- OAuth2 type is selected but `oauth2-config` is empty or not valid JSON.
- `oauth2-config` is missing `auth-url`, `client-id`, or `client-secret`.
- `auth-url` has no path component (likely a bare host — a common mistake, since
  the module appends nothing).

**Area:** `Instruction.php` (warnings), surfaced on `summary.php`.

### 3. Make stored token values verifiable (catch paste errors)

**Problem.** Secrets are entered into textareas that reveal nothing about the
stored value, so a stray leading character or trailing whitespace is invisible.
This caused the final 401 after the code was already fixed.

**Change (options, smallest first):**
- Show a **masked fingerprint** next to each stored token value: length +
  first/last 2 chars (e.g. `len=44, Yh..Q=`). Enough to spot a paste error,
  not enough to leak the value.
- Or add a **"test this entry"** affordance that performs the lookup/resolution
  and reports success + fingerprint without exposing the full value.

**Area:** system-settings UI for `token-management`; may require a small AJAX
action.

### 4. Documentation: OAuth2 setup gotchas

Add a README (and/or field-help) section covering the non-obvious points:
- `auth-url` must be the **full token endpoint path**; the module POSTs to it
  verbatim and appends nothing.
- For OAuth2, `[token-ref:...]` store entries are scope-checked against the
  **resource** URL (`dest-url`), *not* the auth URL. Scope them to a prefix that
  covers the resource URL (commonly the base host), or the reference won't
  resolve.
- The OAuth2 config example mentions `username`/`password`, but the
  client-credentials implementation **does not use them**. Only `auth-url`,
  `client-id`, and `client-secret` are read. Either remove them from the example
  or note they apply only to grant types not yet implemented.

### 5. Config field `name` label review

Several `name` values in `config.json` are ambiguous or overloaded. The clearest
example is **"Destination URL"**, which labels two *different* things:

| Where | Current label | What it actually is | Suggested label |
|---|---|---|---|
| Project `message-config` → `dest-url` | "Destination URL" | The endpoint the API call is sent to (the resource URL). | "Request / Resource URL" — the endpoint this message calls. |
| System `token-management` → `token-url` | "Destination URL (pipe token only in requests to this URL)" | A **scope prefix**: the token is only substituted when the outgoing request URL *starts with* this value. Not a destination at all — a guard. | "Allowed request URL prefix (token used only for requests starting with this)". |

Other labels worth tightening (candidates — confirm wording before changing, as
labels are user-facing and may appear in docs/screenshots):

- **`token-ref` — "Arbitrary unique reference/key".** Accurate but jargon-heavy.
  Consider "Reference name (used as `[token-ref:NAME]` in project settings)".
- **`auth-url` (inside the `oauth2-config` example).** The example should show a
  full token path, e.g. `https://example.com/oauth/token`, not
  `https://example.com/auth`, to reinforce improvement #4.
- **`token-lookup-option` values** — "Read token for project/username" vs. "Use
  token as specified". Fine, but the two conditional sub-sections
  ("Settings for option ...") could name the option they belong to more
  prominently.
- **`result-field` / `result-http-code` / `map-to-field`** — all correctly note
  "Field must be present in the triggering event", which is good. The behavior
  that mappings to a field *not* in project metadata are silently dropped could
  be worth a warning (ties into #2).

> Note: `name` values contain HTML markup and are rendered in the EM config
> dialog. Any relabeling should preserve the existing markup/classes and be
> checked against the live dialog, since the strings also drive the summary-page
> column headers in `REDCapREST.php`.

## Cross-configuration friction (system key store ↔ project config)

A distinct usability problem, separate from labeling: setting up a single
OAuth2 (or token-authenticated) call requires **flipping back and forth between
two disconnected configuration surfaces**, with no cross-visibility and no
validation that they line up.

The round trip looks like:

1. **Control Center → System config** → "API Token Management": create a token
   entry with a `token-ref` key, a scope URL, and the secret value.
2. **Project → module Configure dialog**: reference that key as
   `[token-ref:NAME]` inside the payload / headers / OAuth2 config — typed by
   hand, from memory, in a different dialog.

Why this hurts:

- **No cross-reference or lookup.** The project dialog gives no list of which
  `token-ref` keys exist at system level. You have to remember the exact string
  (`echo-test-api-client-id`) and type it correctly. A typo surfaces only at
  send time as "Token ... not found."
- **Scope coupling is invisible across the boundary.** The system entry's scope
  URL is checked against the project's resource `dest-url`, but the two values
  live in different dialogs, so you can't see both at once to confirm the prefix
  actually matches. This was a direct cause of confusion in the troubleshooting
  session.
- **No "does this resolve?" feedback until a record is saved.** Validation of
  the pairing happens only at runtime, in the save path, reported in the log.
- **Permissions mismatch.** System config is admin-only; project config may be
  done by project users. The person wiring up `[token-ref:...]` in the project
  often cannot see or create the system entry, so setup spans two people.

Possible mitigations (increasingly ambitious):

- **Document the round trip explicitly** (part of improvement #4): a step-by-step
  "system first, then project" walkthrough with a worked example naming the same
  key in both places. Low effort, high clarity.
- **Surface available `token-ref` keys in the project dialog.** Via the
  `redcap_module_configuration_settings` hook (already used by this module), the
  project config could render the list of defined system `token-ref` keys (names
  only, never values) as help text next to the fields that accept them, so the
  user can copy an exact key instead of recalling it.
- **A project-side "validate configuration" / "test" action** that resolves the
  referenced keys (checking existence and scope match against the configured
  `dest-url`) and reports pass/fail *without* sending a real request or exposing
  values. This collapses the two-surface guesswork into one check and ties in
  with improvements #2 (validation warnings) and #3 (verifiable values).
- **Scope-match warning on the summary page.** When a project message references
  `[token-ref:X]` whose system entry's scope URL is not a prefix of the
  message's `dest-url` (or, for OAuth2, the `auth-url`), flag it in the existing
  `Instruction` config-warnings mechanism. This catches the exact
  scope-mismatch class of error at configuration time rather than at send time.

## REDCap External Module framework capabilities we can lean on

Reviewed against the official framework config reference
([vanderbilt-redcap/external-module-framework-docs → config.md](https://github.com/vanderbilt-redcap/external-module-framework-docs/blob/main/config.md)).
Content below is paraphrased from the framework docs. Several native features map
onto the improvements above:

- **`branchingLogic` on settings** — a setting can be shown/hidden based on the
  values of *other settings* in `config.json` (supports comparison operators and
  and/or groups of conditions). This directly helps field clarity: the OAuth2
  config textarea could appear only when an OAuth2 type is selected, and the
  token "lookup" vs. "specify" sub-fields could show only the band matching the
  chosen `token-lookup-option` instead of always rendering both "Settings for
  option ..." sections.
  - **Caveat (from the docs):** `branchingLogic` has known issues *inside
    `sub_settings`* — which is exactly where this module's OAuth2 and token
    fields live. So this may be only partially usable; verify behavior rather
    than assume it works, and fall back to the hook below where it doesn't.
- **`redcap_module_configuration_settings` hook** — the docs recommend this hook
  for conditional logic beyond `branchingLogic`. **This module already
  implements it** (it injects the summary-page link in `REDCapREST.php`), so
  there is a proven, existing home for dynamic show/hide, for surfacing the list
  of system `token-ref` keys in the project dialog, and for validation-driven
  field adjustments.
- **`password` field type** — exists, but the docs explicitly note values are
  still **stored as plain text (not encrypted)**. So it does not improve at-rest
  security; the module's existing `[token-ref:...]` + system-store + log-masking
  approach remains the better pattern. A password field would only help the
  entry UX, and even then does not reveal paste errors (improvement #3 still
  stands).
- **No built-in URL validation type.** The framework offers validated types
  (`email`, `date`, etc.) but nothing for URLs. So the `auth-url` / `dest-url`
  validation in improvement #2 must be **custom logic** in `Instruction.php`;
  the framework will not do it for us.
- **`description-system` / `description-project` and context-specific
  documentation** — the framework allows different help text and documentation
  links in the Control Center (system) vs. project contexts. This is relevant to
  the "Destination URL" ambiguity, which is partly a *context* problem: the
  system-level field (a token scope prefix) and the project-level field (the
  resource URL) are genuinely different things shown in different dialogs.
- **`tt_`-prefixed internationalization keys** — `name`, `description`, etc. have
  translatable companions. Not a current priority, but any relabeling (#5) should
  be done with i18n in mind if translation is ever a goal.

Reference repos for module development, for whoever implements these:
- [external-module-framework-docs](https://github.com/vanderbilt-redcap/external-module-framework-docs)
  — authoritative config/hooks/methods reference.
- [external_module_template](https://github.com/vanderbilt-redcap/external_module_template)
  — starter template.
- [ctsit/redcap_external_module_development_guide](https://github.com/ctsit/redcap_external_module_development_guide)
  — community development tutorial.

Content was rephrased for compliance with licensing restrictions.

## Status / what's already done

- **Multi-token-ref fix** — `pipeApiToken()` now resolves *all* `[token-ref:...]`
  occurrences (not just the first), preserves the per-reference scope check and
  error behavior, and masks every resolved token in the event log. Committed and
  proposed upstream (PR to `lsgs/redcap-rest`).
- **403 retry** — the single token-refresh retry now triggers on 403 as well as
  401. Proposed upstream as a separate PR.
- The improvements listed above (#1–#5) are **not yet implemented**; this
  document is the backlog.

## Suggested priority

1. **#1 Token-exchange logging** — biggest reduction in future debugging time.
2. **#4 / #5 Documentation + label review**, including a worked "system first,
   then project" cross-configuration walkthrough — low-risk, high-clarity, no
   code risk (label changes need a visual check).
3. **Scope-match + incomplete-config warnings on the summary page** (combines #2
   with the cross-configuration scope-mismatch warning) — moderate code change
   in `Instruction.php`, catches the two most common setup errors at config time.
4. **Surface system `token-ref` keys in the project dialog** (via the hook the
   module already implements) — addresses the cross-surface guesswork directly.
5. **#3 Verifiable token values / project-side "validate configuration" action**
   — most UI work; nice-to-have, but collapses the two-surface round trip into a
   single check.
