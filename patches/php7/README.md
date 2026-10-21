# PHP 7.x ports: serialize_lock wrap in object_custom

Ports of `../0001-serialize-lock-in-zend_user_unserialize.patch` (verified on
php-8.5.4) to the five final PHP 7.x release tags, plus 0002/0004 ports for
7.4.33 (2026-10-21): `php-7.4.33-serialize-dispatch-lock.patch` (the dispatch
line is byte-identical 7.4-8.5, so the 0002 port is mechanical) and
`php-7.4.33-session-upload-progress-lifetime-hardening.patch` (0004 anchor
sites identical through 8.4; note 7.x never received the official OOM-bailout
fix, so the 0004-without-bailout caveat in the 8.x README applies: an OOM
mid-upload leaks the widened progress set - stock behavior, not a regression).
0003 (enum grammar) and 0005 (post-8.1 code shapes) do not exist for 7.x.
0006 (destroy-window detach, 2026-10-21) applies verbatim to 7.4.33 too:
the destroy function is byte-identical 7.4-8.5.

The fix wraps the
`ce->unserialize(...)` dispatch in `ext/standard/var_unserializer.re`
(`object_custom()`) with `BG(serialize_lock)++` / `BG(serialize_lock)--`, so a
nested `php_var_unserialize()` call made from inside
`Serializable::unserialize()` allocates its own var_hash instead of sharing -
and freeing - the caller's (UAF).

## Per-tag results

| Tag | Patch | `git apply --check` | Call site (stock) | Enclosing function | Build | Behavioral check |
|---|---|---|---|---|---|---|
| php-7.0.33 | `php-7.0.33-serialize-lock.patch` | PASS (clean shallow clone) | `ext/standard/var_unserializer.re:450` | `object_custom()` | skipped (modern-gcc incompat per brief) | n/a |
| php-7.1.33 | `php-7.1.33-serialize-lock.patch` | PASS (clean shallow clone) | `ext/standard/var_unserializer.re:494` | `object_custom()` | skipped (modern-gcc incompat per brief) | n/a |
| php-7.2.34 | `php-7.2.34-serialize-lock.patch` | PASS (clean shallow clone) | `ext/standard/var_unserializer.re:536` | `object_custom()` | skipped (modern-gcc incompat per brief) | n/a |
| php-7.3.33 | `php-7.3.33-serialize-lock.patch` | PASS (clean shallow clone) | `ext/standard/var_unserializer.re:558` | `object_custom()` | skipped (modern-gcc incompat per brief) | n/a |
| php-7.4.33 | `php-7.4.33-serialize-lock.patch` | PASS (clean shallow clone) | `ext/standard/var_unserializer.re:669` | `object_custom()` | PASS - docker `phpguard-lab:php74build` (Ubuntu 26.04, gcc 15, `CFLAGS=-std=gnu99`, `--disable-all --enable-cli`) | PASS - stock vs patched identical: `string(3) "ok!"` |

All five patches touch exactly one file/one hunk (11 insertions, 2 deletions),
generated with `git diff` from shallow clones of the tags
(github.com/php/php-src.git), applied-checked against clean checkouts.

## Porting notes (differences vs the 8.5.4 reference)

- The call-site shape `} else if (ce->unserialize(rval, ce, (const unsigned
  char*)*p, datalen, (zend_unserialize_data *)var_hash) != SUCCESS) {` is
  byte-identical in all five tags; only line numbers differ. 7.0.33's
  surrounding code differs slightly (`(*p) += datalen;` without the `+1 for
  '}'`), outside the hunk.
- 8.5.4 declares `zend_result tmp = ce->unserialize(...)`. `zend_result` does
  not exist in PHP 7.x, and the 7.x handler returns `int`; the ports declare
  `int tmp;` at the top of the new `else` block (C89-safe placement) and assign
  after the lock bump. Comment wording matches the reference.

## php-7.4.33 build & behavioral verification

- The git tag ships no `configure` script; `./buildconf --force` (autoconf) is
  required before `./configure --disable-all --enable-cli`.
- Ubuntu 26.04 gcc 15 defaults to C23; the 7.4 tree builds with
  `CFLAGS="-std=gnu99 -O1"`. `make -j8` succeeds for both stock and patched
  trees inside the derived image `phpguard-lab:php74build`
  (FROM `phpguard-lab:phase1` + build-essential, autoconf, re2c, bison,
  libxml2-dev).
- re2c is present, so `make` regenerates `ext/standard/var_unserializer.c`
  from the patched `.re`; the generated scanner contains the new wrap
  (comment matched once) - the compiled binary is built from the patched
  scanner, not a stale generated file.
- Behavioral test (benign semantics - must be identical stock vs patched):

  ```php
  class A implements Serializable {
      public $x = "";
      public function serialize() { return serialize($this->x); }
      public function unserialize($d) { $this->x = unserialize($d); }
  }
  $payload = serialize("ok!");                       // s:3:"ok!";  -> 10 bytes
  $wrapped = 'C:1:"A":' . strlen($payload) . '{' . $payload . '}';
  var_dump(unserialize($wrapped)->x);
  ```

  Both binaries print `string(3) "ok!"` (so does the lab's patched PHP 8.5.4).

- Gotcha: the datalen for payload `s:3:"ok!";` is **10**, not 9 - a `9:`
  payload fails at the `(*p)[datalen] != '}'` check on both stock and patched
  (and on patched 8.5.4), unrelated to this fix. Build the payload with
  `strlen(serialize(...))` rather than hand-counting.

## Patch checksums

```
3f58383f3cac4aa3f4adc0bfc29097527570b5d156b24bae2394eef548849a99  php-7.0.33-serialize-lock.patch
caf80dae70642e968c265b04b0257794604b3d57220fbc1fc56ecdd0c0f52f64  php-7.1.33-serialize-lock.patch
531a2764b3369b1c512403755e86f15b708568cb8694c1d2db974f50d235ae5f  php-7.2.34-serialize-lock.patch
deb885e006371fa8e82a1e7ac67f2072c3394f6aa21608e3294df6851d41fd23  php-7.3.33-serialize-lock.patch
00f6168ed9f39734a774cdf0f6b3445ea0fc136486aa2c1e54205dd6eb77c291  php-7.4.33-serialize-lock.patch
```
