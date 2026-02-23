# Quorum CLI — SRE Runbook & Incident Response Playbook

> **Audience:** On-call engineers  
> **Scope:** All operational failures handled by Quorum CLI  
> **Last reviewed:** 2026-02-22

---

## Quick Reference

| Symptom | First Command | See Section |
|---------|--------------|-------------|
| Cluster shows DEGRADED | `cluster-manager.sh status --cluster-id <id> --verbose` | [Degraded Cluster](#2-degraded-cluster) |
| Node not responding | `chaos-engineering.sh kill-node --dry-run` | [Node Failure](#3-node-failure) |
| SSH ping fails | `lib/network_checks.sh` pre-flight | [SSH Failures](#5-ssh-connection-failures) |
| Quorum lost | `cluster-manager.sh status` + node math | [Quorum Loss](#4-quorum-loss) |
| Script ran wrong thing | Check `--dry-run` first | [Dry-Run](#blast-radius) |
| Disk full on node | `storage-ops.sh stats` | [Disk Failure](#6-disk-failure-on-node) |
| Network partition | `chaos-engineering.sh heal-partition` | [Partition](#7-network-partition-detected) |

---

## Operational Context

This CLI manages a distributed storage cluster.  
Three core invariants must always hold:

1. **Quorum invariant:** A strict majority of nodes (`floor(N/2)+1`) must be reachable for writes.
2. **Replication invariant:** Every volume must have `replication_factor` synced replicas.
3. **Leader invariant:** Exactly one node must hold the `LEADER` role at any time.

A violation of any invariant is an incident.

---

## Incident Scenarios

### 1. Cluster Shows UNHEALTHY

**Definition:** Fewer than `floor(N/2)+1` nodes are UP. Writes are blocked.

**Detection:**
```bash
./bin/cluster-manager.sh status --cluster-id <id> --verbose
# Look for: Status: UNHEALTHY
# Look for: N/M nodes UP (where N < quorum threshold)
```

**Immediate Actions:**
```bash
# Step 1: Identify which nodes are down
./bin/cluster-manager.sh status --cluster-id <id> | grep "DOWN"

# Step 2: Check if it's a network partition (nodes running but unreachable)
./scripts/chaos-engineering.sh partition --target-node <ip> --dry-run
# (checks iptables rules without changing anything)

# Step 3: Attempt node recovery
./scripts/chaos-engineering.sh kill-node --cluster-id <id> --node-id <node> --auto-recover

# Step 4: If recovery fails, check logs
tail -100 logs/cluster/cluster-manager.log
tail -100 logs/cluster/cluster-manager.json.log | python3 -m json.tool
```

**Escalation Criteria:** Escalate to Tier 2 if UNHEALTHY persists >10 minutes or if 2+ nodes are permanently down.

---

### 2. Degraded Cluster

**Definition:** Some nodes are DOWN but quorum is still held. Reads work; writes degrade.

**Risk:** One more failure pushes to UNHEALTHY. **Do not ignore this.**

**Resolution:**
```bash
# Identify the degraded node
./bin/cluster-manager.sh status --cluster-id <id>

# Check if the node is truly dead or just partitioned
ping <node-ip>                          # Basic connectivity
nc -zv <node-ip> 22                    # SSH port open?
nc -zv <node-ip> 7001                  # Cluster port open?

# If partitioned: heal the partition
./scripts/chaos-engineering.sh heal-partition --target-node <node-ip>

# If genuinely failed: recover via chaos script
./scripts/chaos-engineering.sh kill-node \
    --cluster-id <id> \
    --node-id <node-id> \
    --auto-recover

# Verify recovery
./bin/cluster-manager.sh status --cluster-id <id>
# Expect: Status: HEALTHY
```

---

### 3. Node Failure

**Definition:** A single cluster node becomes unresponsive.

**Playbook:**

```bash
# --- ALWAYS DRY-RUN FIRST ---
./scripts/chaos-engineering.sh kill-node \
    --cluster-id <id> \
    --node-id <failing-node> \
    --dry-run
# Review output. Confirm the right node and cluster ID.

# --- Execute if dry-run looks correct ---
./scripts/chaos-engineering.sh kill-node \
    --cluster-id <id> \
    --node-id <failing-node> \
    --auto-recover
```

**Post-recovery verification:**
```bash
./bin/cluster-manager.sh status --cluster-id <id> --verbose
./bin/storage-ops.sh verify --volume-id <vol-id>
# All replicas should show: SYNCED
```

---

### 4. Quorum Loss

**Definition:** write operations fail because `<= N/2` nodes are reachable.

**Formula:** `quorum = floor(total_nodes / 2) + 1`

| Total Nodes | Quorum Needed | Max Failures |
|-------------|---------------|--------------|
| 3           | 2             | 1            |
| 5           | 3             | 2            |
| 7           | 4             | 3            |

**Emergency: Restore Quorum**

Option A — Recover failed nodes (preferred):
```bash
./scripts/chaos-engineering.sh kill-node --cluster-id <id> --node-id <node> --auto-recover
```

Option B — Add emergency nodes to raise total (last resort):
```bash
# Preview first
./bin/cluster-manager.sh add-node --cluster-id <id> --dry-run

# Execute
./bin/cluster-manager.sh add-node --cluster-id <id>
```

Option C — Deploy Witness node for even-sized clusters:
```bash
# If you have exactly 2 or 4 nodes and 50/50 split is possible:
./bin/cluster-manager.sh create --name <name> --nodes 2 --force-quorum
# This adds a Witness (+1 vote, no data) to prevent 50/50 split
```

---

### 5. SSH Connection Failures

**Symptom:** `ERROR: X is UNREACHABLE (SSH port closed or host down)`

**Triage:**
```bash
# From the network_checks library — runs pre-flight checks
bash -c "
  source lib/logger.sh
  source lib/network_checks.sh
  pre_flight_checks 192.168.1.101 192.168.1.102 192.168.1.103
"

# Manual checks
ping <node>                        # Layer 3 reachability
nc -zv <node> 22                  # Layer 4 SSH port
ssh -vvv -o BatchMode=yes <node>  # SSH auth debug
```

**Common Causes & Fixes:**

| Cause | Fix |
|-------|-----|
| SSH key not trusted | `ssh-copy-id <user>@<node>` |
| Firewall blocking port 22 | `ufw allow 22/tcp` or check `iptables -L` |
| Node is rebooting | Wait 2 minutes, retry |
| iptables DROP rule active | `chaos-engineering.sh heal-partition --target-node <ip>` |
| Node OOMKilled sshd | `systemctl restart sshd` on node |

**Use `--dry-run` while SSH is down:**
```bash
# You can still preview what WOULD happen
./scripts/chaos-engineering.sh partition --target-node <ip> --dry-run
# Output shows the iptables commands without connecting
```

---

### 6. Disk Failure on Node

**Symptom:** Write operations fail; node shows read-only filesystem errors.

**Detection:**
```bash
./bin/storage-ops.sh stats
# Look for: Usage near 100%, or IOPS suddenly drops to 0

./bin/storage-ops.sh verify --volume-id <vol-id>
# Look for: replica-N: ✗ OUT OF SYNC
```

**Response:**
```bash
# Preview chaos disk-failure scenario to understand impact
./scripts/chaos-engineering.sh disk-failure \
    --cluster-id <id> \
    --node-id <node> \
    --dry-run

# Create immediate snapshot for safety (disaster recovery)
./bin/storage-ops.sh snapshot \
    --volume-id <vol-id> \
    --retention 30d

# Restore node data directory permissions
ssh <node> "sudo chmod +w /path/to/data && sudo systemctl restart cluster-node"

# Verify repair
./bin/storage-ops.sh verify --volume-id <vol-id>
```

---

### 7. Network Partition Detected

**Symptom:** Some nodes are HEALTHY from one vantage point and DOWN from another.
Split-brain warning appears in logs.

**Detection:**
```bash
# Check for active iptables DROP rules
bash -c "
  source lib/logger.sh
  source lib/network_checks.sh
  list_active_partition_rules 192.168.1.0/24
"
# If rules are listed, a partition was deliberately or accidentally created.
```

**Resolution:**
```bash
# Preview heal operation
./scripts/chaos-engineering.sh heal-partition \
    --target-node <partitioned-node-ip> \
    --dry-run

# Heal the partition
./scripts/chaos-engineering.sh heal-partition \
    --target-node <partitioned-node-ip>

# Re-elect leader after heal (may take up to 30s automatically)
./bin/cluster-manager.sh status --cluster-id <id>
# Verify: HEALTHY, single LEADER
```

---

## Blast Radius

> *How does this CLI limit the damage it can cause if something goes wrong?*

### Layer 1: `--dry-run` (Safest)

Every script with side effects supports `--dry-run`. This mode:
- Prints exactly which commands would execute
- Does NOT make any SSH connections
- Does NOT modify any files or directories
- Does NOT execute any iptables rules

**Standard operating procedure:** Always run `--dry-run` before any command
on a production cluster.

```bash
# WRONG (runs immediately)
./scripts/chaos-engineering.sh partition --target-node 192.168.1.102

# RIGHT (preview first)
./scripts/chaos-engineering.sh partition --target-node 192.168.1.102 --dry-run
# Read the output, confirm correct node/CIDR
./scripts/chaos-engineering.sh partition --target-node 192.168.1.102
```

### Layer 2: Strict Mode (`set -euo pipefail`)

All scripts use `set -euo pipefail`. If any command in a pipeline fails:
- The script stops immediately
- No "half-done" cluster state
- Exit code is non-zero (detectable by CI/CD)

Without strict mode, a failed `ssh node2` in a loop would silently continue
to node3, creating asymmetric state that is hard to debug.

### Layer 3: Pre-Flight Checks (`lib/network_checks.sh`)

Before any remote operation, `pre_flight_checks()` verifies that all target
nodes are SSH-reachable. If even one node fails:
- The operation is aborted entirely
- An actionable error message is printed
- `--dry-run` guidance is provided

### Layer 4: JSON Audit Log

Every operation emits a JSON log line:
```json
{"timestamp":"2026-02-22T10:00:01Z","level":"INFO ","message":"Partitioning 192.168.1.102 from cluster..."}
```

Logs accumulate in `logs/cluster/cluster-manager.json.log`. In an incident,
you can reconstruct exactly what happened and when:
```bash
cat logs/cluster/cluster-manager.json.log | python3 -m json.tool | grep ERROR
```

### Layer 5: Snapshot Before Destructive Ops

The `demo.sh` script and recommended workflows always snapshot volumes before
running chaos scenarios:
```bash
./bin/storage-ops.sh snapshot --volume-id <vol-id> --retention 7d
# Only then:
./scripts/chaos-engineering.sh data-corruption --cluster-id <id> --volume-id <vol-id>
```

---

## Monitoring Cheatsheet

```bash
# Real-time dashboard
./bin/perf-monitor.sh dashboard --cluster-id <id> --interval 5

# Performance report (last 24h)
./bin/perf-monitor.sh report --cluster-id <id> --output /tmp/report-$(date +%Y%m%d).txt

# Analysis + recommendations
./bin/perf-monitor.sh analyze --cluster-id <id>

# Tail JSON logs (pipe to jq for pretty)
tail -f logs/cluster/cluster-manager.json.log | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        obj = json.loads(line)
        print(f\"[{obj['timestamp']}] {obj['level']}: {obj['message']}\")
    except:
        print(line, end='')
"
```

---

## Runbook Health Check

Run this command to verify the CLI itself is healthy before using it in an incident:

```bash
./tests/run_tests.sh
# Expect: 71/71 tests passed, 100% pass rate

./tests/bats-vendor/bin/bats tests/
# Expect: All BATS tests pass
```

If tests fail, **do not use the CLI on production** until failures are investigated.
