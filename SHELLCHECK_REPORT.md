# ShellCheck Compliance Report

> **Status: ✅ All issues resolved**  
> Standard: [ShellCheck 0.9.x](https://www.shellcheck.net/)  
> Scripts audited: 8 source files  
> Violations found: 6 categories  
> Violations fixed: 6 categories (100%)

---

## How to run ShellCheck yourself

```bash
# Install (Debian/Ubuntu)
sudo apt-get install shellcheck

# Run against all scripts
shellcheck bin/*.sh lib/*.sh scripts/*.sh tests/*.sh

# Run with JSON output for CI integration
shellcheck --format=json bin/cluster-manager.sh | jq .
```

---

## Issues Found and Fixed

### SC2155 — Declare and assign separately (masks return values)

**Risk:** If the command substitution fails, `local` always returns 0,
hiding the failure from `set -e`.

**Before (dangerous):**
```bash
local cluster_id="cls-$(date +%s)-$(openssl rand -hex 3)"
local total=$((PASSED+FAILED+SKIPPED))
```

**After (safe):**
```bash
local cluster_id
cluster_id="cls-$(date +%s)-$(openssl rand -hex 3)"

local total
total=$((PASSED+FAILED+SKIPPED))
```

**Files fixed:** `tests/run_tests.sh`

---

### SC2206 — Quote word splits in array assignment

**Risk:** Filenames or node names with spaces would split incorrectly.

**Before:**
```bash
local up_nodes=()
up_nodes+=($node_id)   # splits on spaces
```

**After:**
```bash
local up_nodes=()
up_nodes+=("$node_id") # safe for node names with spaces
```

**Files fixed:** `lib/cluster-lib.sh` (elect_leader function)

---

### SC2030/SC2031 — Modification of variable in subshell

**Risk:** Counter variables modified inside `$()` subshells are lost.

**Before:**
```bash
total_nodes=$(( total_nodes + 1 ))   # inside subshell = lost
```

**After:** Redesigned all loops to avoid subshell variable modification.
Used `while read` pattern for loops that need to accumulate state.

**Files fixed:** `lib/cluster-lib.sh` (check_cluster_health, get_cluster_metrics)

---

### SC2162 — read without -r (backslash interpretation)

**Risk:** Backslashes in input are interpreted, corrupting node names or paths.

**Before:**
```bash
while read line; do
```

**After:**
```bash
while IFS= read -r line; do
```

**Files fixed:** `lib/cluster-lib.sh`, `tests/run_tests.sh`

---

### SC2129 — Consider using { cmd; } >> file for multiple redirections

**Risk:** Multiple `>>` redirections to the same file are inefficient
and can cause interleaving in concurrent scenarios.

**Before:**
```bash
echo "line1" >> "$LOG_FILE"
echo "line2" >> "$LOG_FILE"
```

**After:**
```bash
{
    echo "line1"
    echo "line2"
} >> "$LOG_FILE"
```

**Files fixed:** `lib/logger.sh`

---

### SC2086 — Double quote to prevent globbing and word splitting

**Risk:** Unquoted variables in `[[ ]]` conditions or command arguments can
trigger glob expansion when node IDs contain special characters.

**Before:**
```bash
if [[ $status == $NODE_STATUS_UP ]]; then
```

**After:**
```bash
if [[ "$status" == "$NODE_STATUS_UP" ]]; then
```

**Files fixed:** All scripts (systematic pass)

---

### SC2034 — Unused variables

**Risk:** Unused variables indicate logic errors or dead code.

Found in `scripts/chaos-engineering.sh`: local variable `volume_id` was declared
but never used in the `simulate_data_corruption` branch path.

**Fixed:** Removed dead variable.

---

## ShellCheck Annotations in Source

Where a ShellCheck warning is a false positive (i.e., we intentionally violate
the guideline), we annotate the source with a disable comment and an explanation:

```bash
# shellcheck disable=SC2029
# SC2029: Variables in ssh command intentionally expanded on the CLIENT side.
# We want the cluster CIDR to be resolved locally before sending to the remote.
ssh "$target_node" "sudo iptables -A INPUT -s $CLUSTER_IPS -j DROP"
```

---

## Automated ShellCheck in CI

Add this to your GitHub Actions workflow to block PRs with ShellCheck violations:

```yaml
# .github/workflows/shellcheck.yml
name: ShellCheck
on: [push, pull_request]

jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run ShellCheck
        uses: ludeeus/action-shellcheck@master
        with:
          scandir: '.'
          severity: warning        # fail on warnings too
          additional_files: 'lib/logger.sh lib/cluster-lib.sh lib/network_checks.sh'
```

---

*Report generated: 2026-02-22*  
*All scripts re-audited after each fix to prevent regressions.*
