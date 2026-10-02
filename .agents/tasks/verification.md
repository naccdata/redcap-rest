# Verification — OAuth2 token-ref scope fix

## Changes made
- `REDCapREST.php`: `pipeApiToken($string)` → `pipeApiToken($string, $targetURL = null)`.
  Added `$scopeURL = ($targetURL !== null && $targetURL !== '') ? $targetURL : $this->destURL;`
  and switched the `$this->destURL` usages (the `starts_with(...)` scope check and the
  "not found" exception message) to `$scopeURL`. The default preserves identical behavior for
  the only resource-call caller, `pipe()`, which passes no second argument. Rebased onto
  `develop`, this fix is layered on the multi-token (`preg_match_all`) resolver so every
  distinct `[token-ref:...]` is scope-checked against `$scopeURL`.
- `OAuth2.php` constructor: parse `auth-url` from the RAW config (literal, not a token-ref) and
  pass it as the `$targetURL` so OAuth2 credential refs are scoped to the token endpoint.
  Invalid JSON / missing `auth-url` yields `$authUrl = null` and falls back to `$this->destURL`
  (prior behavior); no new fatal thrown.
- `tests/PipeApiTokenTest.php`: exercises the real `pipeApiToken()` (only
  `getSubSettings`/`escape`/`query` stubbed; protected `destURL` set via reflection) and proves:
  1. a `/token`-scoped entry resolves when `$targetURL` = `.../token`;
  2. the same entry does NOT resolve with no target (scope = `.../echo` destURL) — URLs independent;
  3. regression guard: with no target, scope still uses `destURL` as before;
  plus the pre-existing multi-token resolution and masking cases retained from `develop`.

## Dependency setup
```
composer install --no-interaction
```
(`vendor/`, `composer.lock`, `.phpunit.cache/` are gitignored and not committed.)

## Syntax check
```
php -l REDCapREST.php && php -l OAuth2.php && php -l tests/PipeApiTokenTest.php
```

## Test command run (from worktree root)
```
./vendor/bin/phpunit
```

All tests pass (existing `OAuth2ClientCredentialsTest` + `PipeApiTokenTest`), no deprecations.
The exact run and output after the rebase are recorded in the integration step report.
