#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  THE NIGHT THE CLUSTER ALMOST DIED — CINEMATIC EDITION
#  (No audio - pure visual storytelling)
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# --- Automation ---
AUTO=1
DELAY=4
SPD=0.012

# --- Graceful Shutdown ---
# Track which scene is running so the shutdown message is context-aware.
CURRENT_SCENE="startup"
SHUTDOWN_REQUESTED=0

graceful_shutdown() {
    SHUTDOWN_REQUESTED=1
    # Restore cursor visibility unconditionally (tput civis hides it in scenes)
    tput cnorm 2>/dev/null || true
    echo ""
    echo ""
    printf "  \033[93m⚡ Interrupt received during scene: %s\033[0m\n" "$CURRENT_SCENE"
    printf "  \033[97mFinishing current operation, then exiting cleanly...\033[0m\n"
    echo ""
    # Allow the currently-executing scene function to finish its work, then
    # the main loop checks SHUTDOWN_REQUESTED and exits after the scene returns.
    # If we're in a sleep, wake it by doing nothing — the trap returns to the
    # sleep's caller which will hit the SHUTDOWN_REQUESTED check on next loop.
}

# Trap both Ctrl-C and SIGTERM; finish the current scene then exit.
trap 'graceful_shutdown' INT TERM

# --- Visual Core ---
R=$'\033[0m' B=$'\033[1m' RD=$'\033[91m' GN=$'\033[92m' YL=$'\033[93m'
CY=$'\033[96m' WH=$'\033[97m' DK=$'\033[90m' MG=$'\033[95m' BL=$'\033[94m'
COLS=$(tput cols)

scene() { tput clear; tput civis; }

pause() {
    local msg="${1:-Advancing Simulation}"
    printf "\n  ${DK}┄ ${msg} ... ${DK}┄${R}\n"
    sleep "$DELAY"
}

tw() {
    local txt="$1"
    for ((i=0; i<${#txt}; i++)); do 
        printf '%s' "${txt:$i:1}"
        sleep "${2:-$SPD}"
    done
    printf '\n'
}

hr() { printf "   ${DK}%$((COLS-6))s${R}\n" "" | tr ' ' "${1:-─}"; }

glitch_fx() { 
    for i in {1..15}; do 
        printf "\e[$((31 + RANDOM%7))m%X\e[0m" $((RANDOM%16))
        sleep 0.01
    done
}

progress_bar() {
    local label="$1"
    local current="$2"
    local total="$3"
    local width=20
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    local bar="["
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    bar+="]"
    
    printf "\r  %-20s %s %3d%%" "$label" "$bar" "$percent"
}

# ══════════════════════════════════════════════════════════════════════════════
#  SCENE 0: OPENING
# ══════════════════════════════════════════════════════════════════════════════
scene_0() {
    scene
    glitch_fx
    printf "\n\n"
    
    printf "${CY}${B}"
    cat << "EOF"
    ██████╗ ██╗   ██╗ ██████╗ ██████╗ ██╗   ██╗███╗   ███╗  ██████╗██╗     ██╗
   ██╔═══██╗██║   ██║██╔═══██╗██╔══██╗██║   ██║████╗ ████║ ██╔════╝██║     ██║
   ██║   ██║██║   ██║██║   ██║██████╔╝██║   ██║██╔████╔██║ ██║     ██║     ██║
   ██║▄▄ ██║██║   ██║██║   ██║██╔══██╗██║   ██║██║╚██╔╝██║ ██║     ██║     ██║
   ╚██████╔╝╚██████╔╝╚██████╔╝██║  ██║╚██████╔╝██║ ╚═╝ ██║ ╚██████╗███████╗██║
EOF
    printf "${R}\n\n"
    
    tw "  ${B}${WH}\"THE NIGHT THE CLUSTER ALMOST DIED\"${R}" 0.05
    echo ""
    tw "  January 15th, 2026. 14:00 UTC."
    tw "  A routine maintenance task. A hidden bug. 23 minutes of downtime."
    
    pause "Act I: The Calm Before the Storm"
}

# ══════════════════════════════════════════════════════════════════════════════
#  SCENE 1: HEALTHY STATE
# ══════════════════════════════════════════════════════════════════════════════
scene_1() {
    scene
    printf "\n  ${B}${GN}ACT I: NORMAL OPERATIONS${R}\n"
    hr '═'
    tw "  The cluster has been humming for 47 days straight."
    tw "  3 Nodes. 100% Health. Quorum threshold: 2."
    echo ""
    printf "  ${GN}● node-1  [UP]  LEADER    192.168.1.101  [█████░░░░░] 35%%${R}\n"
    printf "  ${GN}● node-2  [UP]  FOLLOWER  192.168.1.102  [████░░░░░░] 28%%${R}\n"
    printf "  ${GN}● node-3  [UP]  FOLLOWER  192.168.1.103  [█████░░░░░] 31%%${R}\n"
    echo ""
    tw "  Everything is green. The on-call engineer is getting coffee."
    
    pause "Maintenance ticket #842 arrives..."
}

# ══════════════════════════════════════════════════════════════════════════════
#  SCENE 2: THE BUGGY RESTART
# ══════════════════════════════════════════════════════════════════════════════
scene_2() {
    scene
    printf "\n  ${B}${YL}ACT II: THE MAINTENANCE RACE${R}\n"
    hr '═'
    tw "  An engineer runs the rolling restart script."
    tw "  The script contains a deadly assumption:"
    echo ""
    printf "  ${DK}╭── cluster-manager.sh${R}\n"
    printf "  ${DK}│${R}  for node in \"\${nodes[@]}\"; do\n"
    printf "  ${DK}│${R}      mark_node_down \"\$node\"\n"
    printf "  ${RD}│  -   sleep 10  # ← THE DEADLY GUESS${R}\n"
    printf "  ${DK}│${R}      mark_node_up \"\$node\"\n"
    printf "  ${DK}│${R}  done\n"
    printf "  ${DK}╰─────────────────────${R}\n"
    
    sleep 2
    tw "  [14:02:10] Node-1 took 14 seconds to boot. Script only waited 10."
    tw "  [14:02:11] Script moves to Node-2 while Node-1 is still offline..."
    
    pause "CRITICAL: QUORUM LOST"
}

# ══════════════════════════════════════════════════════════════════════════════
#  SCENE 3: THE INCIDENT
# ══════════════════════════════════════════════════════════════════════════════
scene_3() {
    scene
    printf "\n  ${RD}${B}╔════════════════════════════════════════════╗${R}\n"
    printf "  ${RD}${B}║  !!! QUORUM LOST — WRITES BLOCKED !!!      ║${R}\n"
    printf "  ${RD}${B}╚════════════════════════════════════════════╝${R}\n\n"
    
    tw "  With 2 nodes down, Cassandra refuses all writes to protect data."
    echo ""
    
    # Error stream
    for i in {1..6}; do
        printf "  ${RD}[%s] ERROR: WriteTimeoutException - 0/2 replicas${R}\n" "$(date +%H:%M:%S)"
        sleep 0.3
    done
    echo ""
    
    printf "  ${RD}○ node-1  [RECOVERING]${R}\n"
    printf "  ${RD}○ node-2  [DOWN]${R}\n"
    printf "  ${GN}● node-3  [UP]${R}\n"
    
    pause "14 minutes of silence from the monitors..."
}

# ══════════════════════════════════════════════════════════════════════════════
#  SCENE 4: THE INVESTIGATION
# ══════════════════════════════════════════════════════════════════════════════
scene_4() {
    scene
    printf "\n  ${B}${CY}ACT III: THE INVESTIGATION${R}\n"
    hr '═'
    tw "  14:17 UTC — Engineer finally notices the Grafana spike."
    tw "  Runs status... it says HEALTHY. Something's wrong."
    echo ""
    printf "  ${RD}[WARN]${R} Cluster status: HEALTHY (but 2/3 nodes are down?!)${R}\n"
    tw "  Adds --verbose flag. The truth emerges."
    echo ""
    printf "  ${RD}● node-1  [DOWN]  Last seen: 14:02${R}\n"
    printf "  ${RD}● node-2  [DOWN]  Last seen: 14:03${R}\n"
    printf "  ${GN}● node-3  [UP]   Load: 72%%${R}\n"
    echo ""
    tw "  The status command has been lying for 14 minutes."
    
    pause "Root cause analysis begins..."
}

# ══════════════════════════════════════════════════════════════════════════════
#  SCENE 5: THE RECOVERY
# ══════════════════════════════════════════════════════════════════════════════
scene_5() {
    scene
    printf "\n  ${B}${CY}ACT IV: THE RECOVERY${R}\n"
    hr '═'
    tw "  Engineer connects. Realizes the status command lied."
    tw "  Manual recovery of node-1 initiated."
    echo ""
    
    # Recovery Progress Bar for Node-1
    printf "  Recovering node-1: "
    for ((p=0; p<=100; p+=5)); do
        progress_bar "node-1" "$p" "100"
        sleep 0.1
    done
    printf "\n  ${GN}✓ node-1 recovered${R}\n"
    
    # Recovery Progress Bar for Node-2
    printf "  Recovering node-2: "
    for ((p=0; p<=100; p+=5)); do
        progress_bar "node-2" "$p" "100"
        sleep 0.1
    done
    printf "\n  ${GN}✓ node-2 recovered${R}\n"
    
    echo ""
    tw "  [14:25] Quorum Restored. Cluster Healthy."
    
    echo ""
    printf "  ${GN}● node-1  [UP]  LEADER    192.168.1.101  [█████░░░░░] 28%%${R}\n"
    printf "  ${GN}● node-2  [UP]  FOLLOWER  192.168.1.102  [████░░░░░░] 25%%${R}\n"
    printf "  ${GN}● node-3  [UP]  FOLLOWER  192.168.1.103  [██████░░░░] 31%%${R}\n"
    
    pause "Post-Mortem: Why did we fail?"
}

# ══════════════════════════════════════════════════════════════════════════════
#  SCENE 6: THE FIX
# ══════════════════════════════════════════════════════════════════════════════
scene_6() {
    scene
    printf "\n  ${B}${MG}ACT V: THE POST-MORTEM FIXES${R}\n"
    hr '═'
    
    tw "  Fix #1: Replace sleep with health polling"
    echo ""
    printf "  ${DK}╭── BEFORE${R}\n"
    printf "  ${RD}│  sleep 10${R}\n"
    printf "  ${DK}│${R}\n"
    printf "  ${DK}╰── AFTER${R}\n"
    printf "  ${GN}│  until check_node_port \"\$node\" 7001; do${R}\n"
    printf "  ${GN}│      sleep 2${R}\n"
    printf "  ${GN}│  done${R}\n"
    echo ""
    
    tw "  Fix #2: Proper JSON parsing"
    echo ""
    printf "  ${DK}╭── BEFORE${R}\n"
    printf "  ${RD}│  grep '\"status\"' | cut -d'\"' -f4${R}\n"
    printf "  ${DK}│${R}\n"
    printf "  ${DK}╰── AFTER${R}\n"
    printf "  ${GN}│  jq -r '.status' metadata.json${R}\n"
    echo ""
    
    tw "  Fix #3: Add quorum gate"
    echo ""
    printf "  ${DK}╭── NEW SAFETY CHECK${R}\n"
    printf "  ${GN}│  if ! check_quorum \"\$up_count\" \"\$total\"; then${R}\n"
    printf "  ${GN}│      log_error \"Aborting: would lose quorum\"${R}\n"
    printf "  ${GN}│      return 1${R}\n"
    printf "  ${GN}│  fi${R}\n"
    
    pause "Engineering safeguards deployed"
}

# ══════════════════════════════════════════════════════════════════════════════
#  SCENE 7: WITNESS NODE
# ══════════════════════════════════════════════════════════════════════════════
scene_7() {
    scene
    printf "\n  ${B}${BL}BONUS: THE WITNESS PROTECTION PROGRAM${R}\n"
    hr '═'
    
    tw "  Even-numbered clusters are dangerous. Here's the fix:"
    echo ""
    printf "  ${YL}⚠ 2-node cluster: 1/1 split = NO QUORUM${R}\n"
    printf "  ${GN}✓ 2 nodes + 1 Witness = 3 votes${R}\n"
    printf "  ${GN}✓ Quorum threshold: 2 votes${R}\n"
    echo ""
    
    tw "  The --force-quorum flag automatically adds a witness:"
    echo ""
    printf "  ${DK}\$ ./bin/cluster-manager.sh create --nodes 2 --force-quorum${R}\n"
    printf "  ${DK}[INFO] Spinning up witness node (vote-only, no data)${R}\n"
    
    pause "Never get split-brained again"
}

# ══════════════════════════════════════════════════════════════════════════════
#  SCENE 8: FINALE
# ══════════════════════════════════════════════════════════════════════════════
scene_8() {
    scene
    printf "\n  ${B}${WH}EPILOGUE: WHAT WE LEARNED${R}\n"
    hr '═'
    
    echo ""
    printf "  ${GN}✓${R}  ${B}Zero data loss${R} — Cassandra protected integrity\n"
    printf "  ${GN}✓${R}  ${B}23 minutes of downtime${R} — but could have been worse\n"
    printf "  ${GN}✓${R}  ${B}3 critical fixes${R} — merged to main\n"
    echo ""
    
    tw "  The five lessons:"
    echo ""
    printf "  ${YL}1.${R} sleep N is not a health check. ${DK}Never.${R}\n"
    printf "  ${YL}2.${R} Test with realistic fixtures. ${DK}Single-line JSON hid a bug.${R}\n"
    printf "  ${YL}3.${R} Alert on symptoms, not just status. ${DK}Client errors don't lie.${R}\n"
    printf "  ${YL}4.${R} Quorum gates save clusters. ${DK}Check before you break.${R}\n"
    printf "  ${YL}5.${R} JSON logs are forensic gold. ${DK}We reconstructed this in 5 minutes.${R}\n"
    echo ""
    
    hr '═'
    echo ""
    
    # Cinematic Ending
    printf "${CY}${B}"
    cat << "EOF"
    ╔════════════════════════════════════════════════════════════╗
    ║                                                            ║
    ║     THE CLUSTER SURVIVED. THE TEAM GOT SMARTER.           ║
    ║     THE CODE GOT SAFER.                                    ║
    ║                                                            ║
    ║     UNTIL NEXT TIME...                                     ║
    ║                                                            ║
    ╚════════════════════════════════════════════════════════════╝
EOF
    printf "${R}\n"
    sleep 2 
    
    echo ""
    printf "  ${DK}Simulation complete. Run ./tests/run_tests.sh to verify fixes.${R}\n"
    echo ""
    sleep 3
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
    tput smcup 2>/dev/null || true

    # run_scene: sets CURRENT_SCENE, runs the scene, then checks for a pending
    # shutdown request.  If one arrived during the scene, we exit cleanly here
    # rather than starting the next scene.
    run_scene() {
        local name="$1"
        CURRENT_SCENE="$name"
        "$name"
        if [[ "$SHUTDOWN_REQUESTED" -eq 1 ]]; then
            tput rmcup 2>/dev/null || true
            tput cnorm 2>/dev/null || true
            printf "  \033[92m✓ Demo exited cleanly after completing scene: %s\033[0m\n\n" "$CURRENT_SCENE"
            exit 0
        fi
    }

    run_scene scene_0
    run_scene scene_1
    run_scene scene_2
    run_scene scene_3
    run_scene scene_4
    run_scene scene_5
    run_scene scene_6
    run_scene scene_7
    run_scene scene_8

    tput rmcup 2>/dev/null || true
    tput cnorm
}

# ⚡ RUN IT ⚡
main "$@"