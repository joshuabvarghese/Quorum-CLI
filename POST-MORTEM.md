# Post-Mortem: Silent Quorum Loss During Rolling Restart

**Date:** 2026-01-15  
**Severity:** SEV-2 (writes unavailable for 23 minutes)  
**Status:** ✅ Resolved — Safety check added, regression test committed

---

## Summary

During a routine rolling restart of a 3-node Cassandra cluster, the Quorum CLI's
`cluster-manager.sh restart` command silently marked all three nodes as DOWN
before any had fully restarted. The cluster's `status` command reported `HEALTHY`
throughout the incident, masking the true state. Client write operations failed
with `NoHostAvailable` errors for 23 minutes before an engineer noticed the
discrepancy between the status display and the actual error logs.

---

## Timeline

| Time     | Event |
|----------|-------|
| 14:02    | Rolling restart initiated: `./bin/cluster-manager.sh restart --cluster-id cls-prod-01` |
| 14:02    | node-1 marked DOWN, restart begins |
| 14:03    | node-2 marked DOWN before node-1 finishes restarting ← **bug triggered here** |
| 14:03    | node-3 marked DOWN while 0 nodes are up |
| 14:03    | Writes begin failing: `NoHostAvailable` from client applications |
| 14:04    | `status` command still shows `HEALTHY` ← **masked by a stale metadata cache** |
| 14:17    | On-call engineer notices error spike in Grafana |
| 14:19    | `--verbose` flag on `status` shows all nodes DOWN |
| 14:23    | Engineer manually restarts nodes; cluster recovers |
| 14:25    | Post-incident investigation begins |

---

## Root Cause Analysis

Two bugs combined to cause and mask the incident:

### Bug 1: No quorum check before proceeding to next node in a rolling restart

The `restart` logic at the time was:

```bash
# BEFORE (dangerous):
for node in "${all_nodes[@]}"; do
    mark_node_down "$node"     # Set status = down
    ssh "$node" systemctl restart cassandra
    sleep 10                   # Fixed delay — not a real health check!
    mark_node_up "$node"       # Set status = up (assumed success)
done
```

The `sleep 10` was supposed to be long enough for the node to restart.
On 2026-01-15 the node took 14 seconds to restart (disk I/O spike), meaning
node-2 was taken down while node-1 was still recovering.

With 0/3 nodes UP, quorum was lost. The script continued to node-3.

### Bug 2: `check_cluster_health` used a stale metadata grep

At the time, `check_cluster_health` read the node status from `metadata.json`
immediately after the in-memory write, but the write used a pattern equivalent to:

```bash
# BEFORE (SC-class bug — status greps could match wrong field):
status=$(grep '"status"' "$node_dir/metadata.json" | cut -d'"' -f4)
```

When the metadata was written as single-line JSON (as in unit tests), this
extracted the **wrong field** (the node ID, not the status value), causing
`check_cluster_health` to compute the wrong UP count.

In production the metadata was multi-line, so this never surfaced there — but
it meant the unit tests were not actually validating health logic correctly.

---

## Impact

- **Duration:** 23 minutes
- **Scope:** All write operations to `cls-prod-01` cluster
- **Data loss:** None (writes buffered at the client layer; replayed on recovery)
- **Users affected:** ~3,400 background sync operations queued

---

## What Went Well

1. **JSON logs captured everything.** The `log_json` audit trail let us reconstruct
   the exact sequence of events within 5 minutes of starting the investigation.
2. **DEGRADED state was eventually visible.** The `--verbose` flag showed
   individual node states even when the summary said `HEALTHY`.
3. **No data corruption.** Cassandra's own consistency checks prevented any
   partial writes from being committed without quorum.

---

## What Went Wrong

1. **No quorum gate before advancing to the next node.** A rolling restart must
   verify quorum is held before taking the next node down.
2. **Health check was showing stale/incorrect data** due to a single-line JSON
   parsing bug that bypassed unit test coverage.
3. **`status` summary masked the truth.** A DEGRADED cluster (2/3 down) was
   being reported as HEALTHY because the health metric was wrong.
4. **`sleep N` is not a health check.** Fixed delays are fragile. The correct
   pattern is a polling loop with a timeout.

---

## Action Items

| # | Action | Owner | Status |
|---|--------|-------|--------|
| 1 | Add `check_quorum` guard before advancing in rolling restart | SRE | ✅ Done |
| 2 | Fix `check_cluster_health` to use robust JSON parsing (both single-line and multi-line) | SRE | ✅ Done |
| 3 | Replace `sleep N` with a health-polling loop (max 60s, check every 2s) | SRE | ✅ Done |
| 4 | Add regression BATS test: restart must not proceed when quorum is broken | SRE | ✅ Done |
| 5 | Add BATS test: `check_cluster_health` correctly handles single-line JSON fixtures | SRE | ✅ Done |
| 6 | Require `--dry-run` review for all `restart` operations on production clusters | Process | ✅ Policy updated |
| 7 | Add `--force-quorum` Witness node support for even-sized clusters | SRE | ✅ Done |

---

## Code Changes

### Fix 1: Quorum gate in rolling restart

```bash
# AFTER (safe):
for node in "${all_nodes[@]}"; do
    # Check quorum is held BEFORE taking next node down
    local up_count down_count total
    up_count=$(count_up_nodes "$cluster_id")
    total=$(count_total_nodes "$cluster_id")

    if ! check_quorum "$up_count" "$total"; then
        log_error "ABORT: Quorum would be lost if we take $node down ($up_count/$total up)."
        log_error "Wait for the previous node to recover before continuing."
        return 1
    fi

    mark_node_down "$node"
    ssh "$node" systemctl restart cassandra

    # Poll for health — don't use sleep
    local attempts=0
    until check_node_port "$node" 7001 || [[ $attempts -ge 30 ]]; do
        sleep 2
        attempts=$(( attempts + 1 ))
    done

    if ! check_node_port "$node" 7001; then
        log_error "Node $node did not recover within 60s — aborting restart"
        return 1
    fi

    mark_node_up "$node"
    log_success "Node $node restarted and healthy"
done
```

### Fix 2: Robust JSON parsing in check_cluster_health

```bash
# BEFORE (broken for single-line JSON):
status=$(grep '"status"' "$node_dir/metadata.json" | cut -d'"' -f4)

# AFTER (works for both single-line and multi-line JSON):
status=$(grep -o '"status"[: ]*"[^"]*"' "$node_dir/metadata.json" \
         | grep -o '"[^"]*"$' | tr -d '"')
```

### Fix 3: Regression BATS test

```bash
@test "check_cluster_health: 1 of 3 nodes down = DEGRADED (quorum retained)" {
    # Previously: this test PASSED but check_cluster_health was silently wrong
    # because single-line JSON parsing extracted the wrong field.
    # Now: the fix makes this test correctly validate the actual logic.
    ...
    run bash -c "
        export DATA_DIR='$DATA_DIR'
        source '$PROJECT_ROOT/lib/cluster-lib.sh'
        check_cluster_health '$cluster_id'
    "
    assert_success
    assert_output "degraded"    # Was: incorrectly "unhealthy"
}
```

---

## Lessons Learned

> *"A unit test that passes but doesn't actually validate the code it claims to
> test is worse than no test — it creates false confidence."*

1. **Test with realistic fixtures.** Our BATS tests used single-line JSON for
   speed. The production code used multi-line JSON. The mismatch hid a parsing
   bug for months. Now: test fixtures must match production JSON format exactly.

2. **A rolling restart without quorum gates is a DDoS against yourself.**
   Any operation that takes nodes offline must verify quorum is preserved at
   every step.

3. **The `--dry-run` flag would have exposed this in staging.**
   The rolling restart procedure was not run with `--dry-run` in the staging
   environment before production. New policy: all cluster-level operations
   require a documented dry-run review.

4. **JSON logs saved the investigation.** We reconstructed the full incident
   timeline in under 5 minutes because every operation had a timestamped JSON
   log entry. If we had been using `echo "node going down"` instead of
   `log_json`, the investigation would have taken hours.

---

## How to reproduce (in test environment only)

```bash
# Simulate the quorum-loss scenario safely
./scripts/chaos-engineering.sh kill-node \
    --cluster-id <test-cluster> \
    --node-id node-1 &
./scripts/chaos-engineering.sh kill-node \
    --cluster-id <test-cluster> \
    --node-id node-2

# Verify quorum is detected as lost
./bin/cluster-manager.sh status --cluster-id <test-cluster>
# Expect: Status: UNHEALTHY

# Recover
./scripts/chaos-engineering.sh kill-node \
    --cluster-id <test-cluster> \
    --node-id node-1 \
    --auto-recover
./scripts/chaos-engineering.sh kill-node \
    --cluster-id <test-cluster> \
    --node-id node-2 \
    --auto-recover
```

---
