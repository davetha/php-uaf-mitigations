# Patches

All patches are for php-8.5.4 unless noted; apply in numerical order.
Generate/verify against your exact tree before production use.

## What each patch does

| # | File | Effect |
|---|------|--------|
| 0001 | serialize-lock-in-zend_user_unserialize | Locks the unserialize context across userland `Serializable::unserialize` dispatch, so a re-entrant `unserialize()` gets its own context instead of sharing (the use-after-free primitive of the unserialize-reentrancy family). Gated to skip internal handlers. |
| 0002 | EXPERIMENTAL serialize-lock-in-serialize-dispatch | Same lock on the serialize side (custom `serialize()` handlers). Optional; see notes in the repo research docs. |
| 0003 | unserialize-context-enum-autoload-lock | Verbatim upstream fix b4a63ec: enum autoloader no longer shares the unserialize context. Public upstream commit; safe. |
| 0004 | session-upload-progress-lifetime-hardening | Defense-in-depth for the rfc1867 upload-progress struct lifetimes. Not a vulnerability fix; makes an entire dangling-pointer class structurally impossible. |
| 0005 | unserialize-context-object-init-lock | Closes the scope gap left by 0003: object instantiation during unserialize (constant-AST property defaults, property hooks) can autoload and run `unserialize()` — same sharing bug, different grammar site. Unfixed upstream at time of writing. |

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

## Known test-suite effects (fail-by-design)

Six phpt tests assert the OLD (pre-fix) cross-dispatch sharing behavior and
will fail with the patches applied; the failure output is a graceful
`unserialize() === false` or changed back-reference semantics, never memory
unsafety: bug36424, bug70172, bug70172_2, bug71940, bug70219_1, max_depth.

## Older branches

- 8.3/8.4: 0001/0003/0005 apply with small context offsets; 0003 is already
  upstream there via b4a63ec-era picks on some builds — check before applying.
- 7.x/5.x: the var_unserializer grammar differs substantially; only 0003's
  upstream equivalent may exist for your branch. For EOL branches prefer the
  detection/block stack (DETECTION.md) and upgrade planning.
