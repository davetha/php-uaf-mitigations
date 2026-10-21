# phpguard mitigation-kit

Defensive distribution: source patches, live detection, and a runtime blocker
for the PHP unserialize vulnerability family (unserialize-reentrancy family). This kit
contains NO proof-of-concept or exploit code — the accompanying repository
research documents stay out of this directory by design.

## Contents

- `patches/` — source patches 0001–0005 (see PATCHES.md)
- `stap/` — systemtap scripts for el7/el8/CloudLinux/cPanel hosts
- `bpftrace/` — bpftrace equivalents for modern kernels
- PATCHES.md — what each patch fixes, how to apply and build
- DETECTION.md — how to run the monitoring/blocking stack, per platform

## Quick guidance

1. If you can rebuild PHP: apply the patches (PATCHES.md). That is the real
   fix — the detection stack exists for hosts that cannot be patched today.
2. If you cannot rebuild: deploy DETECTION.md tier 1 immediately (cheap,
   safe), watch tier 2 in alert mode for a day, then arm the blocker.
3. EOL PHP (7.x/5.x): only some patches port cleanly — see PATCHES.md notes;
   rely on the detection/block stack and plan the upgrade.

## Disclaimer — read before deploying

USE AT YOUR OWN RISK. This kit was developed and validated in small
environments only: single-host labs, small test machines (including one
cPanel/CloudLinux host), and local ASAN builds of PHP 8.4/8.5. It has NOT
been exercised on large hosting stacks, high-traffic fleets, or diverse
production configurations. The kernel-level probes (systemtap/bpftrace) run
with root privileges and the blocking mode kills worker processes by design;
measure the overhead and alert-noise on a canary host first. The patches
change unserialize() isolation semantics — run your application test suite
before shipping them. No warranty, express or implied.
