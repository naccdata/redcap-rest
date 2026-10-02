# Verification — Increment A: Token-exchange logging

Branch: `feat/token-exchange-logging` (fork-local, no PR, no deploy).

## Environment

- `php` 8.5.11 and `composer` 2.10 on PATH (`/opt/homebrew/bin/php`, `/opt/homebrew/bin/composer`).
- `vendor/` already present in the worktree; `composer install` was not required.

## Commands run (from the worktree root)

```
./vendor/bin/phpunit --configuration phpunit.xml --display-deprecations
```

## Results

- Baseline (before changes): **17 tests, 51 assertions, OK.**
- After changes: **20 tests, 64 assertions, OK** — no failures, no deprecations.

The suite was run and passed in this environment; the reviewer does not need to
re-run it to confirm the result above.

## What changed (and why it's verified)

1. `REDCapREST::maskSecrets(string $text): string` — new public method, single
   source of truth for resolved-`[token-ref:...]` masking. The inline loop in
   `redcap_save_record()` that built `$payloadForLog` was refactored to call it.
   The existing 17 tests (which cover the payload-masking path indirectly) still
   pass, confirming the refactor preserved behavior.

2. `OAuth2ClientCredentials::updateAccessToken()` — logs every token-exchange
   attempt (success and failure) via `$this->module->log(...)`, consistent with
   the existing `cURL info:` line, recording the endpoint URL and HTTP status.
   The response body is masked before it reaches any log line or exception:
   first `$this->module->maskSecrets(...)` for resolved client-id/secret values,
   then `str_replace` of the returned `access_token` with
   `|||access_token removed|||`. Failure throws now include the HTTP status and
   masked body while PRESERVING the `\Exception` type and the original message
   substrings (`Unable to obtain access token`, `Unexpected access token
   response`), so `redcap_save_record()`'s try/catch behavior is unchanged.

## New tests (tests/OAuth2ClientCredentialsTest.php)

- `testFailedExchangeLogsStatusAndEnrichedException` — non-200 (401) logs the
  endpoint + `HTTP 401`; thrown exception message contains both
  `Unable to obtain access token` and `401`.
- `testAccessTokenMaskedInLogs` — a 200 body whose `access_token` is the
  sentinel `SUPER-SECRET-TOKEN-XYZ`; asserts the raw sentinel appears in NO
  logged message and that `|||access_token removed|||` is present, plus the
  exchange was logged with the endpoint and `HTTP 200`.
- `testMaskSecretsReplacesResolvedTokenValue` — exercises
  `REDCapREST::maskSecrets()` directly with a reflection-set `resolvedTokens`
  map (the existing OAuth2 mock does not populate `resolvedTokens`, so a direct
  unit test on the single source of truth is the faithful check); asserts a
  known resolved secret is replaced by `|||Token <ref> removed|||`.

The `log` mock now captures messages so tests can assert on logged content.

## Constraints honored

- No secret, client_secret, client_id value, or access_token appears unmasked in
  any log line (verified by the masking tests).
- No method signatures changed; `oauth2Call` and `updateAccessToken` keep their
  signatures. `maskSecrets` is additive and public.
- Observability-only: token-exchange protocol, 401/403 retry, caching, and
  `pipeApiToken` are untouched.
