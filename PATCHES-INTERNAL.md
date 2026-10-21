# patches/

Our own fixes for the `Serializable` reference-table bugs, generated as
`git diff` against the official php-src tags. Every file applies with
`git apply --check` to a pristine clone of its tag.

## 0001 — unserialize direction (the October CVE class) — SHIP THIS

`object_custom()` dispatches `Serializable::unserialize()` without
incrementing `BG(serialize_lock)`, so a nested `unserialize()` inside user
code shares the outer `var_hash`. Inner property zvals dangle after the
property table resizes; `R:N` then reads freed memory (the Calif MAD Bugs
primitive, and almost certainly CVE-2026-109618/-109619). [Advisory-day
note: wrong on that last clause — the CVEs turned out to be the OOM-bailout
mechanism, see "Advisory-day verdict" below; this lock still fixes the real
reentrancy family it was written for.]

The lock is applied **only for userland classes**
(`!(ce->type & ZEND_INTERNAL_CLASS)`). Internal handlers (SPL coding
wrappers) re-enter `php_var_unserialize()` intentionally and depend on the
shared var_hash for outer `R:`/`r:` numbering; locking them shifted slot
indices and broke 7 core phpts — see
`research/gate-regression-triage.md`.

- `0001-serialize-lock-in-zend_user_unserialize.patch` — php-8.5.4 reference.
  Verified on php-8.5.4: `tests/local_exploit.php` full RCE on stock, dies at
  Phase 1 patched; container A/B vs distro stock (944 tests across
  `ext/standard/tests/serialize` + `ext/spl/tests`): stock 0 failures,
  patched 5 — all five intentionally change behavior (below).
- `php5/` — 5.4.45 / 5.5.38 / 5.6.40 (both `.re` and `.c`; ≤ 5.3 is immune by
  mechanism: no shared `var_hash` before 5.4).
- `php7/` — 7.0.33 … 7.4.33 (7.4.33 behaviorally A/B verified).
- `php8/` — 8.0.30 / 8.1.31 / 8.2.29 / 8.3.25 / 8.4.26 (each apply-checked
  against a pristine tag clone).

### Known semantic changes (intended — these tests assert the old sharing)

`bug70172`, `bug70172_2`, `bug71940`, `bug36424`, `max_depth`: each performs
nested `unserialize()` inside a userland `Serializable::unserialize()` and
expects the inner parse to see the outer `R:` table. Post-fix the inner parse
gets its own table (that *is* the CVE mitigation), so their expectations no
longer match. The official fix took a different route (bailout handling,
see Advisory-day verdict below), so this expectation shift stays specific
to our approach — keep it in mind when stacking both.

## 0002 — serialize direction — EXPERIMENTAL, DO NOT BUNDLE BY DEFAULT

`ext/standard/var.c` dispatches `ce->serialize` (userland
`Serializable::serialize()`) also without the lock. A nested `serialize()`
from inside it numbers references into the *outer* stream's table, producing
streams that `@unserialize()` rejects — [bugs.php.net#66052](https://bugs.php.net/bug.php?id=66052)
(also #76631/#76632), unfixed in 8.5.4.

Locking it fixes `tests/nested-serialize-corruption.php` (`RT_FAIL` stock →
`RT_OK`) but breaks behavior core tests rely on: nested `serialize()`
payloads legitimately embed `r:` references into the outer table, so
isolating the numbering makes **cyclic `Serializable` graphs recurse
infinitely** (`bug36424.phpt` overflows at 4200+ frames). Keep as opt-in for
apps that never cross-reference cycles; revisit when upstream ships.

- `0002-serialize-lock-in-serialize-dispatch.patch` — php-8.5.4; gated on
  `ce->serialize == zend_user_serialize` so internal handlers keep shared
  numbering.

## 0003 — upstream enum-autoloader fix (cherry-pick)

`0003-unserialize-context-enum-autoload-lock.patch` — verbatim upstream
b4a63ec ("Don't share the unserialize() context with enum autoloaders",
2026-09-29, GH-23981): the `E:` branch of the grammar lacked the lock the
`O:` branch has. Same family, already public — apply on top of 0001
(applies clean to php-8.5.4 + 0001).

## 0004 — session.upload_progress lifetime hardening (defense-in-depth)

`0004-session-upload-progress-lifetime-hardening.patch` — ext/session only.
The rfc1867 progress struct keeps alias zvals (`progress->files`,
`progress->current_file`) for arrays it inserts into other arrays via
ownership-transferring no-addref moves (`add_assoc_zval_ex` /
`add_next_index_zval`), and raw `zval*` bucket pointers cached across the
upload. 0004 makes the struct's references explicit: `Z_TRY_ADDREF` at both
inserts, `zval_ptr_dtor` on per-file re-init and at MULTIPART_EVENT_END, so
the arrays cannot be freed while the cached pointers target them.

**Status: hardening, not a vulnerability fix.** A viral writeup
(jackalsyn.com, 2026-10-21) claimed two heap UAFs here
(“CVE-2026-109618/619”); verified against real source on 8.4.4 and 8.5.4,
including the author's own trigger harness under ASAN builds of both —
**no use-after-free occurs** (`Z_TRY_ADDREF(progress->data)`, present since
bug #73273/2016, balances the tree teardown the writeup relies on).
Full log: `research/session-upload-progress-claim.md`. Apply on top of
0001 if you want the class made structurally impossible anyway.

## Applying

```
git clone --depth 1 -b php-8.5.4 https://github.com/php/php-src && cd php-src
git apply ../patches/0001-serialize-lock-in-zend_user_unserialize.patch
git apply ../patches/0003-unserialize-context-enum-autoload-lock.patch   # upstream b4a63ec; in NO release tag yet
# optional/opt-in:
git apply ../patches/0002-serialize-lock-in-serialize-dispatch.patch
./buildconf --force && ./configure --disable-all --enable-cli && make -j
```

On patch day, diff the official fix against these; if upstream fixes more
call sites than we do, adopt upstream's.

## 0006 — var_destroy reentry (GH #21824) — upstream PR #21828 port

`0006-unserialize-destroy-window-detach.patch` — ports upstream PR #21828
("Avoid unserialize context reuse during cleanup",
https://github.com/php/php-src/pull/21828, unmerged, in NO release tag):
php_var_unserialize_destroy() detaches BG(unserialize) state BEFORE teardown,
so a destructor re-entering unserialize() during the var_destroy
loop gets a fresh context instead of the dying one (the public 2026-10-21
fediverse PoC "still works on 8.5.12"; upstream regression test gh21824.phpt
included verbatim). Applies VERBATIM to php-7.4.33 through 8.5.12 (the
destroy function is byte-identical across that whole range - no per-tag
ports needed).

Verified: stock ASAN 8.5.12 A/B - upstream phpt trigger + 8 in-house
variants + the wtfcves L1/L2 suite all crash stock (heap-use-after-free
var_unserializer.re:912) and all go clean with 0006; stacks cleanly on
0001+0003+0005-v2 (8.5.4 ASAN rebuild, all prior gates still pass).
Runtime counterpart: destroy-window probes (DETECTION.md).

## Advisory-day verdict (2026-10-21, php-8.2.35 / 8.3.36 / 8.4.27 / 8.5.12)

Related unmerged upstream: var_destroy context reuse -
destructor runs inside php_var_unserialize_destroy() teardown;
https://github.com/php/php-src/issues/21824, fix PR
https://github.com/php/php-src/pull/21828 ("Avoid unserialize context
reuse during cleanup", prateekbhujel). In NO release tag; public PoC on
8.5.12 (fediverse @elise, 2026-10-21) and in-house repro (wtfcves
l1b_crashctrl, stock ASAN 8.5.12 heap-use-after-free var_unserializer.re:912).
Covered by our 0006 port (this file) + destroy-window probes at runtime.

The official CVE-2026-109618 / CVE-2026-109619 fix is upstream commit
`31c0ea7d7f` "Avoid state corruption via bailout" (GHSA-w8hw-w9fx-j79w /
GHSA-6wmf-4rv5-p3rp; "Replace bailout on OOM with UnwindExit; properly
reset various globals that may be accessed during startup"), a 423-file
core rework with OOM tests across the rfc1867/session surface. Backports:
8.2.35 = `01a40e89fb`, 8.3.36 = `3584a98bda`, plus 8.4.27, 8.5.12.

Mechanism: **OOM-bailout state corruption** (bailout during unserialize /
session startup unwinds without resetting serialize/session globals) — NOT
var_hash context sharing. Our pre-advisory attributions (109618 =
object_custom UAF, 109619 = GH-24373) were both wrong; GH-24373's
serialize-destroy issue remains unmerged on master as of this tag set.

Consequences for this kit:

- **Upgrade to 8.2.35+ / 8.3.36+ / 8.4.27+ / 8.5.12+ = the primary CVE
  mitigation.** 8.2 got the fix too — better than the "8.x-current only"
  assumption; 8.2 security window runs to Dec 2026.
- 0001/0003/0005 remain valid hardening for a DIFFERENT real bug family
  (serialize-context reentrancy: bug #70172-class UAF, enum/AST-default
  autoload sharing). The bailout fix does not touch the sharing gate —
  `BG(serialize_lock) || !BG(unserialize).level` is unchanged in the fixed
  tags.
- **b4a63ecd70 (== 0003) is in NO release tag** — enum-autoload sharing is
  live even in 8.5.12; 0003/0005 still apply on the newest releases.
- Branches that will never receive the official fix (7.x, 8.0, 8.1): the
  patches + detection/interposer stack remain the only option there.
- On current releases, stack 0001+0003+0005 on top of 8.5.12+ for defense
  in depth. The detection/block stack stays relevant in all cases — but
  see DETECTION.md: the reentry probes do NOT see the bailout CVE.

## 0005 — unserialize context isolation at object-init / property-default sites

**Reissued 2026-10-21 (v2):** the original release leaked `BG(serialize_lock)`
when `object_common()`'s HT_MAX_SIZE capacity guard returned between the
wrap's ++ and -- (found during the tag port survey; a tiny `O:"X":4294967290`
payload leaves the lock raised for the rest of the request). v2 decrements on
that path; rebuilt and behaviorally gated on the 8.5.4 ASAN tree (guard fires
clean, subsequent unserialize/roundtrips/nesting intact). No 8.x tag takes a
verbatim 0005 port (anchor survey: era-different object_custom/object_common
shapes; regenerate per tag if needed).

`0005-unserialize-context-object-init-lock.patch` — closes the scope gap in the
upstream enum fix (b4a63ec = our 0003): the same context-sharing exists whenever
an object is instantiated during unserialize and its constant-AST property
defaults are evaluated — the autoloader (or a property hook) then runs with
`BG(serialize_lock) == 0`, so its `unserialize()` calls share the outer var_hash
(delayed `__unserialize`, mis-resolved `r:`/`R:` back-references; the
CVE-2026-109618 family). Discovered via wtfcves uaf-sweep-v2 t3 (deterministic
on stock 8.4.26/8.5.11, unfixed at master tip as of 2026-10-21).

Wraps the same serialize_lock idiom b4a63ec used at the three remaining sites:
`object_custom()`'s object_init_ex, the O: grammar rule's object_init_ex, and
`object_common()`'s property-table access + nested write loop (hooks).

Verified on 8.5.4 ASAN (stacked with 0001 + 0003): all three t3 oracles flip to
isolated-context semantics; serialize phpt suite shows no new regressions
(6 fail-by-design residuals, all asserting pre-fix cross-dispatch sharing —
incl. bug70219_1, previously never exercised because the earlier builds lacked
the session extension).
