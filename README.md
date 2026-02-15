# Quorum CLI

A production-grade command-line tool suite for managing distributed storage (systems, data replication, and cluster operations - built entirely with Linux CLI tools

## 🎯 Project Overview

This project simulates a distributed storage platform with:
- **Multi-node cluster management** simulated Cassandra/Kafka-like clusters)
- **Data replication and consistency checking**
- **Storage performance monitoring and optimization**
- **Automated backup and disaster recovery**
- **Cluster health monitoring and auto-remediation**
- **Network partition detection and handling**


This project demonstrates **ALL these competencies** using CLI tools.

## 🚀 Key Features

### 1. Cluster Management
```bash
./cluster-manager.sh create --nodes 5 --type cassandra
./cluster-manager.sh status --verbose
./cluster-manager.sh add-node --cluster-id c1
./cluster-manager.sh remove-node --node-id n3 --decommission
```

### 2. Storage Operations
```bash
./storage-ops.sh provision --size 10GB --replication 3
./storage-ops.sh snapshot --volume vol-1 --retention 7d
./storage-ops.sh replicate --source vol-1 --target vol-2 --async
./storage-ops.sh verify-integrity --volume vol-1
```

### 3. Performance Monitoring
```bash
./perf-monitor.sh --metrics iops,latency,throughput
./perf-monitor.sh analyze --timerange 1h --report
./perf-monitor.sh bottleneck-detection --auto-tune
```

### 4. Data Replication
```bash
./replication-manager.sh setup --topology multi-dc
./replication-manager.sh sync-check --repair
./replication-manager.sh failover --from dc1 --to dc2
```

### 5. Backup & Recovery
```bash
./backup-manager.sh full --destination /backup/cluster-1
./backup-manager.sh incremental --since yesterday
./backup-manager.sh restore --snapshot snap-20240131
```

## 🛠️ Technical Skills Demonstrated

### System Administration
- Process management, resource monitoring
- Disk operations, filesystem management
- Network diagnostics, performance tuning

### Storage & Filesystems
- File operations, LVM simulation
- RAID concepts, data integrity

### Data Processing
- Stream processing, log analysis
- JSON/CSV parsing, time-series data

### Networking
- Socket operations, HTTP testing
- Network diagnostics, port management

### Scripting & Automation
- Advanced bash, error handling
- Signal handling, service management

### Distributed Systems
- Consensus algorithms, replication
- CAP theorem, quorum operations

## 📁 Project Structure

```
distributed-storage-platform/
├── bin/
│   ├── cluster-manager.sh
│   ├── storage-ops.sh
│   ├── replication-manager.sh
│   ├── backup-manager.sh
│   ├── perf-monitor.sh
│   ├── health-checker.sh
│   └── disaster-recovery.sh
├── lib/
│   ├── cluster-lib.sh
│   ├── storage-lib.sh
│   ├── network-lib.sh
│   ├── metrics-lib.sh
│   └── logger.sh
├── config/
│   ├── cluster.conf
│   ├── storage.conf
│   └── replication.conf
├── data/
│   ├── clusters/
│   ├── volumes/
│   ├── replicas/
│   └── snapshots/
├── logs/
├── scripts/
│   ├── simulate-load.sh
│   ├── chaos-engineering.sh
│   └── benchmark.sh
└── tests/
```

## 🚀 Quick Start (M1 Mac)

```bash
# Clone and setup
git clone <repo>
cd distributed-storage-platform
chmod +x bin/*.sh scripts/*.sh tests/*.sh

# Initialize
./bin/cluster-manager.sh init

# Create cluster
./bin/cluster-manager.sh create --name prod --nodes 3

# Check status
./bin/cluster-manager.sh status
```

## 📊 Sample Output

```
=== Cluster Status: production-cluster ===
Cluster ID: cls-prod-001
Type: Cassandra (simulated)
Status: HEALTHY

Nodes:
  node-1 [LEADER]    UP   Load: 35%   Data: 1.2GB   Uptime: 2h 15m
  node-2 [FOLLOWER]  UP   Load: 32%   Data: 1.2GB   Uptime: 2h 15m
  node-3 [FOLLOWER]  UP   Load: 38%   Data: 1.2GB   Uptime: 2h 14m

Replication: Factor=3, Consistency=QUORUM, Synchronized=YES
Performance (5min): Read p99=12ms, Write p99=18ms, Ops=5.4K/s
Storage: 3.6GB/15GB (24%), IOPS: 1,200
```

## 🚀 Installation (M1 Mac)

### Prerequisites Check
```bash
# Verify you have the required tools (all pre-installed on macOS)
which bash    # Should show /bin/bash
which awk     # Should show /usr/bin/awk
which sed     # Should show /usr/bin/sed
which grep    # Should show /usr/bin/grep

# Optional but recommended
brew install jq      # JSON processing
brew install htop    # Better process viewer
```

### Setup
```bash
# 1. Clone or download this project
cd distributed-storage-platform

# 2. Verify scripts are executable
ls -la bin/    # Should show -rwxr-xr-x

# If not executable, run:
chmod +x bin/*.sh scripts/*.sh tests/*.sh

# 3. Initialize the system
./bin/cluster-manager.sh init
```

## 🎯 Quick Demo (Recommended)

Run the automated demo to see all features:
```bash
./scripts/demo.sh
```

This will automatically:
- Create a 3-node cluster
- Provision storage with replication
- Create snapshots
- Run integrity checks
- Generate performance reports
- Simulate failures
- Demonstrate auto-recovery

## 📚 Manual Usage Examples

### 1. Cluster Management

**Create a cluster:**
```bash
./bin/cluster-manager.sh create \
  --name my-cluster \
  --nodes 5 \
  --type cassandra \
  --replication-factor 3
```

**List all clusters:**
```bash
./bin/cluster-manager.sh list
```

**View cluster status:**
```bash
# You'll get the cluster ID from the create command
./bin/cluster-manager.sh status --cluster-id cls-XXXXXXXXXX --verbose
```

**Add a node (scale up):**
```bash
./bin/cluster-manager.sh add-node --cluster-id cls-XXXXXXXXXX
```

### 2. Storage Operations

**Provision a volume:**
```bash
./bin/storage-ops.sh provision \
  --cluster-id cls-XXXXXXXXXX \
  --size 10GB \
  --replication 3
```

**List all volumes:**
```bash
./bin/storage-ops.sh list
```

**Create a snapshot:**
```bash
./bin/storage-ops.sh snapshot \
  --volume-id vol-XXXXXXXXXX \
  --retention 30d
```

**Verify data integrity:**
```bash
./bin/storage-ops.sh verify --volume-id vol-XXXXXXXXXX
```

**View storage statistics:**
```bash
./bin/storage-ops.sh stats
```

### 3. Performance Monitoring

**Real-time dashboard:**
```bash
# Press Ctrl+C to stop
./bin/perf-monitor.sh dashboard \
  --cluster-id cls-XXXXXXXXXX \
  --interval 5
```

**Generate performance report:**
```bash
./bin/perf-monitor.sh report \
  --cluster-id cls-XXXXXXXXXX \
  --output my-report.txt
```

**Analyze performance:**
```bash
./bin/perf-monitor.sh analyze --cluster-id cls-XXXXXXXXXX
```

### 4. Chaos Engineering (Testing Resilience)

**Simulate node failure:**
```bash
./scripts/chaos-engineering.sh kill-node \
  --cluster-id cls-XXXXXXXXXX \
  --node-id node-2 \
  --auto-recover
```

**Simulate network partition:**
```bash
./scripts/chaos-engineering.sh network-partition \
  --cluster-id cls-XXXXXXXXXX \
  --partition "node-1,node-2" "node-3"
```

**Simulate high load:**
```bash
./scripts/chaos-engineering.sh high-load \
  --cluster-id cls-XXXXXXXXXX \
  --duration 60
```

**Simulate disk failure:**
```bash
./scripts/chaos-engineering.sh disk-failure \
  --cluster-id cls-XXXXXXXXXX \
  --node-id node-2
```

### 5. Testing

**Run integration tests:**
```bash
./tests/integration-tests.sh
```


## 🎓 Key Concepts

1. **CAP Theorem**: Consistency, partition tolerance, availability trade-offs
2. **Replication**: Master-slave, multi-master, sync/async
3. **Consensus**: Raft simulation, leader election, quorum
4. **Storage**: Compaction, caching, optimization
5. **Monitoring**: Real-time metrics, anomaly detection