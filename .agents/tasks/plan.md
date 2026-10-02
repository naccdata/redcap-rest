# Implementation Plan — OAuth2 token-ref scope fix

Fix the bug where OAuth2 `client-id`/`client-secret` `[token-ref:...]` placeholders are
scope-checked against the resource/Request URL (`$this->destURL`, e.g. `.../echo`) instead of
the OAuth2 token endpoint (`auth-url`, e.g. `.../token`). A correctly-scoped OAuth2 secret
therefore fails the `starts_with($this->destURL, token-url)` check and forces users to widen
their system-level token-url prefix to a shared host. The fix adds an optional target URL to
`pipeApiToken` and has `OAuth2.php` pass the parsed `auth-url` as that target.

Worktree root (all absolute paths below are rooted here):
`/Users/bjkeller/Documents/workspace/naccdata/redcap-rest/.worktrees/fix-oauth2-token-scope`

## Findings from exploration (ground truth — read before trusting the spec prose)

- **The worktree is on branch `fix/oauth2-token-scope` at tag `2.0.0`, an OLDER commit than the
  parent repo's `develop`.** The `pipeApiToken` here is the single-match version. The spec's
  description of it ("preg_match_all multi-token loop, resolvedTokens bookkeeping, masking stays
  as-is") describes the NEWER parent-repo version and does NOT match this worktree. Plan against
  the actual code in this worktree, quoted below.

- **Actual `pipeApiToken` in the worktree** (`REDCapREST.php`, approx. lines 197–225):
  ```php
  public function pipeApiToken($string) {
      $found = false;
      $matches = array();
      $pattern = "/\[token-ref:([-\w]+)\]/";
      if (!preg_match($pattern, $string, $matches)) return $string;

      $systemTokens = $this->getSubSettings('token-management');
      foreach ($systemTokens as $i => $systemToken) {
          if (  array_key_exists(1, $matches) && $matches[1]==$systemToken['token-ref'] &&
              starts_with($this->destURL, $systemToken['token-url']) ) {
              $found = true;
              break;
          }
      }

      if (!$found) throw new \Exception('Token with reference "'.$matches[1].'" for destination URL "'.$this->destURL.'" not found in system-level token management.');

      if ($systemToken['token-lookup-option']==='lookup') { ... }
      else if ($systemToken['token-lookup-option']==='specify') { $this->token = $this->escape($systemToken['token-specified']); }

      if (empty($this->token)) throw new \Exception('Could not read token with reference "'.$matches[1].'" in system-level token management.');
      $this->tokenRef = $matches[1];
      return str_replace($matches[0], $this->token, $string);
  }
  ```
  It resolves a SINGLE `[token-ref:...]` per call (not multiple), has no `resolvedTokens` map and
  no masking logic. There are exactly two `$this->destURL` usages inside the method: the
  `starts_with(...)` scope check and the "not found" exception message. Both must switch to the
  new `$scopeURL`.

- **Callers of `pipeApiToken`** (confirmed by grep across all `*.php` in the worktree):
  1. `REDCapREST::pipe()` (approx. line 135): `$string = $this->pipeApiToken($string);` — a
     resource-call path (payload/header/url piping). It passes NO second argument, so with the
     new optional param it falls back to `$this->destURL` and behaves identically. **No change
     needed.** This is the only resource-call caller; `pipe()` is in turn the single funnel used
     by header building, curl options, dest-url, and payload formatting, so none of those need
     changes either.
  2. `OAuth2.php` constructor (line 30): `$this->module->pipeApiToken($instruction['oauth2-config'])`
     — the OAuth2-credential path. This is the one to change (step 2).

- **Test files present in the worktree `tests/`:** `OAuth2ClientCredentialsTest.php` and
  `bootstrap.php` only. **`tests/PipeApiTokenTest.php` does NOT exist in this worktree** — it must
  be CREATED, not edited. (The spec said "read that file first"; it is absent here. The
  parent-repo copy exists but targets the newer method and is not applicable verbatim.)

- **Test harness patterns (from `OAuth2ClientCredentialsTest.php` + `bootstrap.php`):**
  - `bootstrap.php` stubs `ExternalModules\AbstractExternalModule` with no-op
    `getSubSettings`/`getProjectSetting`/`query`/`escape`, defines a global `starts_with($haystack,$needle)`
    = `strpos($haystack,$needle)===0`, and `db_fetch_assoc()` returning `[]`.
  - Tests build the module with `getMockBuilder(REDCapREST::class)->disableOriginalConstructor()->onlyMethods([...])->getMock()`.
  - For the REAL `pipeApiToken` to run, stub only `getSubSettings`, `escape`, `query` (NOT
    `pipeApiToken`). `getSubSettings` returns the token-management fixture for key
    `'token-management'`, `escape` returns its argument.
  - `destURL` is a `protected` property; set it via `ReflectionProperty::setValue`.
  - PHPUnit 10 is the dev dependency; `tests/` directory is the single testsuite in `phpunit.xml`
    (bootstrap `tests/bootstrap.php`). PHP 8.5 and composer are available locally; `vendor/` is
    gitignored and absent, so `composer install` is required before running tests.

- **Scope guard:** the `starts_with` prefix semantics are unchanged (no host/path tightening) —
  out of scope per the spec.

## Plan

- [ ] 1. Install dev dependencies so the test suite can run.
      Run `composer install` in the worktree to create `vendor/` (PHPUnit 10). `vendor/`,
      `composer.lock`, and `.phpunit.cache/` are gitignored, so this does not dirty the tree.
      Files: none committed (installs `vendor/` locally only).
      Verify: `./vendor/bin/phpunit` runs and the existing suite
      (`OAuth2ClientCredentialsTest`) passes — establishes a green baseline before changes.

- [ ] 2. Add an optional `$targetURL` scope override to `pipeApiToken` in `REDCapREST.php`.
      Change the signature to `public function pipeApiToken($string, $targetURL = null)`. At the
      top of the body (after the early-return guard is fine, but before the `foreach`) compute
      `$scopeURL = ($targetURL !== null && $targetURL !== '') ? $targetURL : $this->destURL;`.
      Replace `starts_with($this->destURL, $systemToken['token-url'])` with
      `starts_with($scopeURL, $systemToken['token-url'])`, and in the "not found" `\Exception`
      message replace the interpolated `$this->destURL` with `$scopeURL`. Leave everything else
      (preg_match single-match loop, `$found`/`break`, lookup/specify branches, `$this->token`,
      `$this->tokenRef`, `str_replace` return) exactly as-is. The default preserves identical
      behavior for the `pipe()` resource caller (step findings confirm it passes no second arg).
      Files: `REDCapREST.php`
      Verify: `./vendor/bin/phpunit` — existing `OAuth2ClientCredentialsTest` still passes
      (that suite mocks `pipeApiToken`, so it must remain green), and the file parses with no
      syntax error (`php -l REDCapREST.php`).

- [ ] 3. Scope OAuth2 credential refs to the token endpoint in `OAuth2.php`.
      In the constructor, replace:
      ```php
      $configString = $this->module->pipeApiToken($instruction['oauth2-config']);
      $config = json_decode($configString, true);
      ```
      with:
      ```php
      $rawConfig = json_decode($instruction['oauth2-config'], true);
      $authUrl = is_array($rawConfig) && isset($rawConfig['auth-url']) ? $rawConfig['auth-url'] : null;
      $configString = $this->module->pipeApiToken($instruction['oauth2-config'], $authUrl);
      $config = json_decode($configString, true);
      ```
      Keep the subsequent `token_endpoint`/`client_id`/`client_secret` assignments from `$config`
      unchanged. When raw config is not valid JSON or lacks `auth-url`, `$authUrl` is `null` and
      `pipeApiToken` falls back to `$this->destURL` (prior behavior). Do NOT add a new fatal/throw.
      Files: `OAuth2.php`
      Verify: `php -l OAuth2.php` parses clean; `./vendor/bin/phpunit` — existing
      `OAuth2ClientCredentialsTest` still passes (its mocked `pipeApiToken` ignores the extra arg
      via `willReturnArgument(0)`, so the OAuth2 flow is unaffected).

- [ ] 4. Create `tests/PipeApiTokenTest.php` proving the scope override and the regression guard.
      New PHPUnit test class `MCRI\REDCapREST\Tests\PipeApiTokenTest` in the `tests/` directory,
      following `OAuth2ClientCredentialsTest.php` conventions: `require_once __DIR__ . '/../REDCapREST.php';`,
      build the module via `getMockBuilder(REDCapREST::class)->disableOriginalConstructor()
      ->onlyMethods(['getSubSettings','escape','query'])->getMock()` so the REAL `pipeApiToken`
      runs; stub `getSubSettings` to return a `token-management` fixture of `specify`-type entries;
      stub `escape` to return its argument; set the protected `destURL` via `ReflectionProperty`.
      Use host `https://host.example.com` with token endpoint `.../token` and resource
      `.../echo`. Cover three cases (one coherent test file):
      - **OAuth2 scope success:** `destURL` = `https://host.example.com/echo`; token entry has
        `token-url` = `https://host.example.com/token`; call
        `pipeApiToken('[token-ref:ref]', 'https://host.example.com/token')` and assert the
        placeholder is replaced with the specified value.
      - **URLs are independent:** same entry (`token-url` = `.../token`), but call
        `pipeApiToken('[token-ref:ref]')` with NO target (so scope = `destURL` = `.../echo`);
        assert it throws (`expectException(\Exception::class)` or try/catch) because `.../echo`
        does not start with `.../token`. This demonstrates token-url and dest-url are checked
        independently.
      - **Resource-call regression guard:** `destURL` = `https://host.example.com/echo`; token
        entry `token-url` = `https://host.example.com`; call `pipeApiToken('[token-ref:ref]')`
        with no target and assert it resolves (scope still uses `destURL` as before).
      Files: `tests/PipeApiTokenTest.php`
      Verify: `./vendor/bin/phpunit` — the full suite passes including all new assertions.
      Record the exact command and full output.

- [ ] 5. Run the full test suite and record the exact command + output.
      Confirm all tests (existing `OAuth2ClientCredentialsTest` + new `PipeApiTokenTest`) pass.
      Files: none.
      Verify: `./vendor/bin/phpunit` from the worktree root prints OK with the new tests counted;
      paste the command and summary line (tests/assertions, OK) into the implementation record.

## Notes / assumptions

- The spec's reference to the parent repo's `PipeApiTokenTest.php` and to "preg_match_all /
  resolvedTokens / masking" does not match this worktree's older `pipeApiToken`. The fix itself
  is unaffected (both versions scope-check with `starts_with(<url>, token-url)` in the same spot),
  so the plan applies the two required edits to the ACTUAL code and creates the test fresh. No
  attempt is made to backport the newer multi-token/masking machinery — that is out of scope.
- `starts_with` prefix-matching semantics are intentionally left unchanged.
- `vendor/`/`composer.lock`/`.phpunit.cache/` are gitignored; only `REDCapREST.php`, `OAuth2.php`,
  and `tests/PipeApiTokenTest.php` should appear in the commit.
