# PHP 5.x port: serialize_lock around `ce->unserialize()` (UAF fix)

Port of the fix verified on php-8.5.4
(../0001-serialize-lock-in-zend_user_unserialize.patch): wrap the
`ce->unserialize(...)` dispatch in `object_custom()` with
`BG(serialize_lock)++` / `BG(serialize_lock)--` so a nested
`php_var_unserialize()` invoked from user code inside
`Serializable::unserialize()` gets its own var_hash instead of sharing
the outer one.

## Verification method

- Each patch was generated with `git diff` from an edited shallow clone
  (`git clone --depth 1 -b <tag> https://github.com/php/php-src.git`,
  clones kept under /tmp/patch-port-php5/) and validated with
  `git apply --check` **and** a real `git apply` on the clean clone.
- **Not built**: the host compiler (gcc 16) cannot build PHP 5.x; no
  compile/runtime verification was done. `git apply --check` + applied
  diff inspection only.

## Per-tag results

| Tag | Patch | `git apply --check` | Call site (object_custom) | Notes |
|---|---|---|---|---|
| php-5.1.6 | - not produced | n/a | var_unserializer.re:302 / .c:298 | **NOT AFFECTED** (see below); dispatch is a standalone `if` after an early-return NULL check at .re:288 |
| php-5.2.17 | - not produced | n/a | var_unserializer.re:345 / .c:341 | **NOT AFFECTED** (see below); same code shape as 5.1.6 |
| php-5.3.29 | - not produced | n/a | var_unserializer.re:350 / .c:346 | **NOT AFFECTED** (see below); code shape already matches 5.4's `else if` form |
| php-5.4.45 | php-5.4.45-serialize-lock.patch | PASS | var_unserializer.re:400 / .c:396 | applied cleanly; both .re and .c patched |
| php-5.5.38 | php-5.5.38-serialize-lock.patch | PASS | var_unserializer.re:400 / .c:396 | applied cleanly; both .re and .c patched |
| php-5.6.40 | php-5.6.40-serialize-lock.patch | PASS | var_unserializer.re:437 / .c:433 | applied cleanly; both .re and .c patched |

No tag required the UNVERIFIED_SEMANTICS marker: for the three affected
tags the wrap target was unambiguous, and for 5.1-5.3 the branch is
unaffected by construction (below).

## Why php-5.1/5.2/5.3 are NOT affected

`BG(serialize_lock)` does not exist anywhere in these trees (no member in
ext/standard/basic_functions.h, no reads/writes in var.c or var_unserializer).
That is not just a missing guard - the sharing mechanism itself is absent:

- ext/standard/php_var.h `PHP_VAR_UNSERIALIZE_INIT(var_hash)` is simply
  `(var_hash).first = 0; (var_hash).first_dtor = 0` on a stack-local struct
  in `PHP_FUNCTION(unserialize)`. There is no `BG(unserialize)` global
  var_hash and no level refcount, so a nested `unserialize()` call always
  operates on its own private var_hash; it can never share, replace, or
  destroy the outer unserializer's entries. No shared-var_hash UAF is
  reachable via `Serializable::unserialize()`.
- `zend_user_unserialize()` (Zend/zend_interfaces.c) receives the outer
  var_hash pointer but ignores it - it only invokes the user method.

## Why php-5.4/5.5/5.6 ARE affected

ext/standard/php_var.h `PHP_VAR_UNSERIALIZE_INIT/DESTROY` became
level-refcounted over `BG(unserialize).var_hash`: with `serialize_lock == 0`
and a level open, a nested `PHP_FUNCTION(unserialize)` **reuses the outer
var_hash** (`var_hash_ptr = BG(unserialize).var_hash; ++level`). The dispatch
in `object_custom()` ran with the lock at 0, which is the bug. Bumping
`BG(serialize_lock)` around the dispatch forces the nested call down the
private `ecalloc` path (own hash, own destroy) - identical semantics to the
8.5 reference fix.

## Differences vs the 8.5 reference patch

- `zend_result tmp = <call>` (8.5, C99) became `int tmp;` declared at the top
  of the new `else` block with the call assigned after the lock bump -
  PHP 5 builds target C89 compilers (VC6-era), where a declaration must lead
  its block. Behavior identical; `!= SUCCESS` check preserved.
- The 5.x call expression is kept verbatim, including the trailing
  `TSRMLS_CC` and the surrounding `object_init_ex(*rval, ce)` fallback.
- **Both** ext/standard/var_unserializer.re **and** var_unserializer.c are
  patched (the reference only touched .re). In 5.x both files are tracked in
  git and the committed .c is what compiles when re2c is not installed;
  patching only .re would leave the fix inert in a typical build.

## Applying

    git checkout php-5.6.40   # or 5.4.45 / 5.5.38
    git apply php-5.6.40-serialize-lock.patch
