# PHP 8.x patch ports

0001: wrap the ce->unserialize dispatch in object_custom() with
BG(serialize_lock)++/-- (same fix as master 0001, validated on 8.5.4 with
exploit A/B + semantics A/B). 0002/0003/0004 ports follow their master
semantics; all apply-checked against pristine tag checkouts.

| tag | 0001 | 0002 | 0003 | 0004 |
|---|---|---|---|---|
| php-8.0.30 | line 680 | PASS | N/A (enum grammar era) | PASS |
| php-8.1.31 | line 749 | PASS | verbatim (master applies) | PASS |
| php-8.2.29 | line 777 | - | - | - |
| php-8.2.35 | line 827 | PASS | PASS | PASS |
| php-8.3.25 | line 777 | - | - | - |
| php-8.3.36 | line 827 | PASS | PASS | PASS |
| php-8.4.26 | line 776 | - | - | - |
| php-8.4.27 | line 826 | verbatim | PASS | PASS |
| php-8.5.12 | line 826 | verbatim | PASS | verbatim |

0005: no verbatim port exists for any 8.x tag - the object_custom/object_common
regions differ per era (see 0005-object-init-anchor-survey.md in the private
research notes); regenerate with /tmp/gen0005.py-style anchors per tag instead.

Defect notice (2026-10-21): the original 8.0.30-8.4.26 0001 ports were
compile-broken (orphaned `return 0; }` tail from a partial anchor replace);
all five were regenerated with the correct master shape and re-verified.
The 8.5.4 master 0005 was reissued the same day: the HT_MAX_SIZE capacity
guard returned with the lock raised (request-lifetime leak) - the release now
decrements on that path; ASAN 8.5.4 rebuild + behavioral gate passed.

Release note (2026-10-21): the official CVE-2026-109618/619 fix (OOM
bailout, different mechanism) shipped in 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 -
for those CVEs simply upgrade. These ports address the reentrancy family
the official fix does not touch.

Build/behavioral verification: see 0001 (php-8.5.4) - full A/B done there
(exploit killed at leak stage; benign nested-Serializable semantics identical).
The other 8.x tags share the same code shape; verified by apply-check +
region inspection, builds skipped per scope.
Reference: patches/0001-serialize-lock-in-zend_user_unserialize.patch
