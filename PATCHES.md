# Patches

All patches are for php-8.5.4 unless noted; apply in numerical order.
Generate/verify against your exact tree before production use.

## What each patch does

| # | File | Effect |
|---|------|--------|
| 0001 | serialize-lock-in-zend_user_unserialize | Locks the unserialize context across userland `Serializable::unserialize` dispatch, so a re-entrant `unserialize()` gets its own context instead of sharing (the use-after-free primitive of the unserialize-reentrancy family). Gated to skip internal handlers. |
| 0002 | EXPERIMENTAL serialize-lock-in-serialize-dispatch | Same lock on the serialize side (custom `serialize()` handlers). Optional; see notes in the repo research docs. |
| 0003 | unserialize-context-enum-autoload-lock | Verbatim upstream fix b4a63ec: enum autoloader no longer shares the unserialize context. Public upstream commit (master-only - in no release tag yet); safe. |
| 0004 | session-upload-progress-lifetime-hardening | Defense-in-depth for the rfc1867 upload-progress struct lifetimes. Not a vulnerability fix; makes an entire dangling-pointer class structurally impossible. |
| 0005 | unserialize-context-object-init-lock | Closes the scope gap left by 0003: object instantiation during unserialize (constant-AST property defaults, property hooks) can autoload and run `unserialize()` - same sharing bug, different grammar site. Unfixed upstream at time of writing. |
| 0006 | unserialize-destroy-window-detach | Port of upstream PR #21828 (unmerged): detaches the unserialize state before teardown so a destructor re-entering unserialize() during cleanup gets a fresh context (GH #21824). Applies verbatim to 7.4 through 8.5.12. |

## Apply + build

```
git clone --depth 1 -b php-8.5.4 https://github.com/php/php-src && cd php-src
git apply ../patches/0001-serialize-lock-in-zend_user_unserialize.patch
git apply ../patches/0003-unserialize-context-enum-autoload-lock.patch
git apply ../patches/0005-unserialize-context-object-init-lock.patch
# optional: 0002, 0004
./buildconf --force && ./configure --disable-all --enable-cli --enable-session && make -j
```

For a production build, mirror your distro's configure flags instead of
`--disable-all`.

## Related unmerged upstream fixes (not included here)

Two upstream fixes sit in open PRs and are in NO release tag as of
2026-10-21, so the newest releases remain exposed to both shapes:

- enum-autoload context lock (the basis of our 0003, commit b4a63ec) -
  still unmerged on master.
- var_destroy cleanup reentry (destructor calling unserialize() inside
  the teardown window): issue
  https://github.com/php/php-src/issues/21824, fix PR
  https://github.com/php/php-src/pull/21828 ("Avoid unserialize context
  reuse during cleanup"). Our 0006 ports that fix (the destroy function
  is byte-identical from 7.4 through 8.5.12, so one patch covers all);
  the destroy-window probes in DETECTION.md cover it at runtime for hosts
  that cannot patch.

## Known test-suite effects (fail-by-design)

Six phpt tests assert the OLD (pre-fix) cross-dispatch sharing behavior and
will fail with the patches applied; the failure output is a graceful
`unserialize() === false` or changed back-reference semantics, never memory
unsafety: bug36424, bug70172, bug70172_2, bug71940, bug70219_1, max_depth.

## Version ports

Per-tag ports live in `patches/php8/` and `patches/php7/` (generated as git
diffs against the exact tags, apply-check verified). Coverage:

| family | 8.0.30 | 8.1.31 | 8.2.x | 8.3.x | 8.4.x | 8.5.12 | 7.0-7.4 | 5.4-5.6 |
|---|---|---|---|---|---|---|---|---|
| 0001 | port | port | port (29/35) | port (25/36) | port (26/27) | port | port | port |
| 0002 | port | port | port (35) | port (36) | verbatim | verbatim | 7.4.33 | - |
| 0003 | N/A | verbatim | port (35/36) | port (36) | port (27) | port | N/A | N/A |
| 0004 | port | port | port (35/36) | port (36) | port (27) | verbatim | 7.4.33 | - |
| 0005 | - | - | regenerate per tag (anchor survey) | | | - | - | - |

0003 8.0.30 is N/A (pre-enum grammar); 0005 has no verbatim port for any tag
because the wrapped regions differ per era - regenerate with the documented
anchors. On 7.x and 5.x, prefer the detection/block stack plus 0001/0003-where-
available; those branches will never receive the official fix.

## Relation to the official security releases

php 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 (2026-10-21) contain the official
fixes for the 2026 unserialize-related CVEs (OOM-bailout state corruption,
commit 31c0ea7d7f and its backports). These patches are complementary
serialize-reentrancy hardening, NOT the official CVE fix: **upgrade to one
of those releases for the CVEs themselves.** Note upstream's own enum fix
(b4a63ec, the basis of patch 0003) is still in no release tag, so 0003/0005
still apply on the newest releases. The patches are most useful on EOL
branches that will never receive the official fix, or stacked on top of
current releases for defense in depth. The detection and blocking stack
remains relevant in all cases (but see DETECTION.md: the reentry probes do
not detect the bailout CVE).
