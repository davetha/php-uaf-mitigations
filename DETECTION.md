# Detection & blocking

Two engines: **bpftrace** (modern kernels, 4.9+) and **systemtap**
(el7/el8/CloudLinux — the cPanel world). Same three-tier design.

| Tier | Signal | Catches | Cost |
|------|--------|---------|------|
| 1 | worker deaths: SIGSEGV/SIGABRT bursts + page-fault bursts + payoff `execve(/bin/sh*)` | post-facto exploitation, heap corruption | negligible |
| 2 | nested `unserialize()` reentrancy (uprobe on `php_var_unserialize`) | the exploit chain BEFORE any corruption or shell | low |
| 3 | blocking (kill the worker at first reentrancy) | stops the chain outright | request dies (by design) |

## bpftrace (root)

```
sudo bpftrace bpftrace/php-uaf-chain-detect.bt        # tier 1
sudo bpftrace bpftrace/php-suspicious-activity.bt     # generic suspicious exec/opens
```

## systemtap

Prereqs on el8/CloudLinux: `yum install systemtap systemtap-runtime` plus
matching `kernel-debuginfo`/`kernel-devel` (on CloudLinux these usually ship
with the lve kernel packages).

Tier 1 (always-on, alert-only):

```
stap stap/php-uaf-chain-detect.stp
stap stap/php-suspicious-activity.stp
```

Tier 2 (reentrancy oracle — needs the PHP binary path; works on stripped
binaries because ZEND_API symbols live in the dynsym):

```
stap stap/php-unserialize-reentry-detect.stp /opt/alt/php74/usr/bin/php
```

Tier 3 (blocker). Run tier 2 in alert mode for a day first — a few frameworks
legitimately nest unserialize() once:

```
stap -g stap/php-unserialize-reentry-block.stp /opt/alt/php74/usr/bin/php -G MODE=2
```

MODE=1 alerts; MODE=2 SIGKILLs the worker the moment nesting starts, so the
request dies before the use-after-free stage; php-fpm/prefork respawns the
worker automatically. A graceful "return false instead of killing" mode was
evaluated and rejected (ABI-unsafe on uprobes); the graceful fix is the patch
kit.

First stap run of a script compiles a kernel module (~30–60 s warmup); plan
your warmup before expecting hits. Syntax-check without loading:
`stap -p2 script.stp [args]` (add `-g` for scripts that raise signals).

## Worker-name coverage

Filters match: `php`, `php-fpm`, `php-cgi`, `php8x`-style names,
`lsphp`/`lsphpXX` (LiteSpeed), `httpd`/`apache2` (mod_php),
`cpanel_php_fpm` (cPanel UI), `imunify360-php*` (Imunify360). Add your own
comm names to the `is_php()`-style filters if your stack names workers
differently.

## Find your PHP binary path

```
ps -eo comm | grep -iE 'php|lsphp' | sort | uniq -c
readlink -f /proc/$(pgrep -f 'php-fpm: master' | head -1)/exe
ls /opt/alt/php*/usr/bin/php /opt/cpanel/ea-php*/root/usr/bin/php \
   /usr/local/lsws/lsphp*/bin/lsphp 2>/dev/null
```

Each binary/version you serve from needs its own tier-2/3 probe instance
(uprobes attach per-binary). Tier 1 is process-name based and covers all
binaries at once.
