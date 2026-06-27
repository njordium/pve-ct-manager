#!/usr/bin/env bash
# =============================================================================
# pct-renumber.sh — PVE LXC Container Management v1.1.0
# Interactive renumber, VLAN/IP change, migration for Proxmox VE clusters
# No external deps | Team Njordium
# Script Author: Kim Haverblad
# =============================================================================
#
# Usage:  ./pct-renumber.sh [--dry-run] [--color|--no-color]
#
# Requires: root on a PVE cluster node, pct, pvesh, lvm tools
# =============================================================================
#
# Changelog:
#   v1.1.0  2026-06-27
#     - Cluster overview now shows Public IP and Egress IF as dedicated columns
#       (populated automatically at startup via egress_probe_all_nodes)
#     - Removed standalone "Show egress public IPs" menu option (data now
#       always visible on the overview)
#     - Configure flow: explicit Move vs Copy mode prompt whenever a CT ID
#       change or target-node change is selected
#         * Copy with new ID         -> pct clone source -> NEW_ID, source kept
#         * Copy with same ID + node -> pct clone source -> BACKUP_ID on
#           source (suggested 9XXXX prefix), then migrate original to target
#         * Copy with same node + new ID -> local clone (duplicate in place)
#     - MAC address handling: explicit prompt to regenerate or preserve.
#       Default is preserve (critical for DHCP-assigned IPs). New MAC, when
#       requested, uses /dev/urandom and the Proxmox BC:24:11 OUI prefix
#     - update_net0_in_config() gains optional MAC parameter
#     - New helpers: generate_mac(), get_current_mac(), egress_probe_all_nodes()
#     - Operation Summary expanded with Mode, MAC, and backup ID rows
#     - Start vs Restart prompt at completion now correctly says Start in
#       Copy mode (clone never ran before)
#
# =============================================================================

set -euo pipefail

SCRIPT_VERSION="1.1.0"

# ---------- Configuration ----------
LOGFILE="/var/log/pct-renumber.log"
ROLLBACK_DIR="/var/log/pct-renumber-rollback"
JOBS_CFG="/etc/pve/jobs.cfg"
DRY_RUN=0

# ---------- Colour decision ----------
# Default: ON. Use --no-color to disable if your terminal mangles SGR resets
# (some terminals leak input characters at reset boundaries).
COLOR_MODE="always"   # always | never
for arg in "$@"; do
    case "$arg" in
        --no-color|--no-colour) COLOR_MODE="never"  ;;
        --color|--colour)       COLOR_MODE="always" ;;
    esac
done

USE_COLOR=0
[[ "$COLOR_MODE" == "always" ]] && USE_COLOR=1

# Cache the local hostname once — used throughout for local-vs-remote routing.
THIS_HOST="$(hostname)"

# ---------- ANSI colours ----------
# Use $'...' syntax so the variables hold actual ESC bytes. All output uses
# printf with these as separate arguments. When colour is disabled, all
# variables are empty strings.
if (( USE_COLOR == 1 )); then
    # Use bright ANSI variants (90-97 for fg) so dim terminal palettes
    # still show vivid colours. Bold added on the primary colours.
    RED=$'\033[1;91m';    GREEN=$'\033[1;92m';   YELLOW=$'\033[1;93m'
    CYAN=$'\033[1;96m';   BLUE=$'\033[1;94m';    MAGENTA=$'\033[1;95m'
    BOLD=$'\033[1m';      DIM=$'\033[2m';        NC=$'\033[m'
else
    RED='';    GREEN='';   YELLOW=''
    CYAN='';   BLUE='';    MAGENTA=''
    BOLD='';   DIM='';     NC=''
fi

# ---------- UTF-8 / ASCII glyph selection ----------
# Mirrors npm-native's locale-aware detection so the script renders cleanly
# on serial consoles, POSIX locales, or non-UTF-8 SSH sessions.
NPM_USE_UTF8="${NPM_USE_UTF8:-auto}"
if [[ "${NPM_USE_UTF8}" == "auto" ]]; then
    case "${LC_ALL:-${LANG:-}}" in
        *.UTF-8|*.utf-8|*.UTF8|*.utf8) NPM_USE_UTF8=true ;;
        *) NPM_USE_UTF8=false ;;
    esac
fi
if ${NPM_USE_UTF8}; then
    G_DASH="—";   G_DOT="·";     G_BULLET="•"
    G_OK_DOT="●"; G_NF_DOT="○"
    G_ARROW="→";  G_STEP="»";    G_ARROW_HEAVY="➜"
    G_CHECK="✓";  G_CROSS="✗";   G_WARN_SYM="⚠"
    G_HBAR="─";   G_HBAR_HEAVY="━"
else
    G_DASH="-";   G_DOT="|";     G_BULLET="*"
    G_OK_DOT="*"; G_NF_DOT="o"
    G_ARROW="->"; G_STEP=">";    G_ARROW_HEAVY=">"
    G_CHECK="OK"; G_CROSS="X";   G_WARN_SYM="!"
    G_HBAR="-";   G_HBAR_HEAVY="="
fi

# ---------- Logging ----------
TS() { date '+%Y-%m-%d %H:%M:%S'; }
log_file() {
    echo "[$(TS)] $1" >> "$LOGFILE"
}
log()   { printf '%s[%s]%s %s %s\n' "$GREEN" "$G_CHECK" "$NC" "$(TS)" "$*"; log_file "OK: $*"; }
info()  { printf '%s[%s]%s %s %s\n' "$CYAN"  "$G_ARROW" "$NC" "$(TS)" "$*"; log_file "INFO: $*"; }
step()  { printf '%s[%s]%s %s %s\n' "$CYAN"  "$G_STEP"  "$NC" "$(TS)" "$*"; log_file "STEP: $*"; }
warn()  { printf '%s[%s]%s %s %s\n' "$YELLOW" "$G_WARN_SYM" "$NC" "$(TS)" "$*"; log_file "WARN: $*"; }
err()   { printf '%s[%s]%s %s %s\n' "$RED"   "$G_CROSS" "$NC" "$(TS)" "$*" >&2; log_file "ERR: $*"; }
die()   { printf '\n%s[%s] FATAL:%s %s %s\n\n' "$RED" "$G_CROSS" "$NC" "$(TS)" "$*" >&2; exit 1; }
banner() { printf '\n%s%s%s%s %s %s%s%s%s\n\n' "$CYAN" "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" "$*" "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" "$NC"; }

# Keep legacy short aliases for existing call sites
ok() { log "$*"; }
# Consistent DRY-run line (used by config-mutating helpers)
dry() { printf '%s[%s DRY]%s %s\n' "$YELLOW" "$G_WARN_SYM" "$NC" "$*"; }
run() {
    log_file "EXEC: $*"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s[%s DRY]%s %s %s\n' "$YELLOW" "$G_WARN_SYM" "$NC" "$(TS)" "$*"
    else
        eval "$@"
    fi
}

# ---------- Splash ----------
show_splash() {
    clear
    printf '%s' "$CYAN"
    cat <<'SPLASH'
                __                                          __
    ____  _____/ /_      _________  ____  ____ _____ ___  / /_   ___  _____
   / __ \/ ___/ __/____ / ___/ __ \/ __ \/ __ `/ __ `__ \/ __ \ / _ \/ ___/
  / /_/ / /__/ /_/____// /  / /_/ / / / / /_/ / / / / / / /_/ //  __/ /
 / .___/\___/\__/      \/   \____/_/ /_/\__,_/_/ /_/ /_/_.___/ \___/_/
/_/
SPLASH
    printf '%s                                                              v%s%s\n' "$CYAN" "$SCRIPT_VERSION" "$NC"
    echo
    printf '  %sPVE LXC Container Manager%s %s Configure %s Migrate %s Network\n' "$GREEN" "$NC" "$G_DASH" "$G_DOT" "$G_DOT"
    printf '  No external deps %s Cluster-aware %s Team Njordium\n' "$G_DOT" "$G_DOT"
    echo   "  --------------------------------------------------"
    [[ $DRY_RUN -eq 1 ]] && printf '  %s[DRY RUN MODE — no changes will be made]%s\n' "$YELLOW" "$NC"
    if (( USE_COLOR == 0 )); then
        echo "  [colour disabled]"
    fi
    echo
}

# ---------- Args ----------
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --no-color|--no-colour) ;;  # handled in early scan above
        --color|--colour) ;;        # handled in early scan above
        -h|--help)
            cat <<EOF
Usage: $0 [--dry-run] [--no-color|--color]

Interactive LXC container management for PVE clusters.

Options:
  --dry-run    Show what would be done without making any changes
  --color      Enable ANSI colour output (default)
  --no-color   Disable ANSI colour output (useful for terminals with broken SGR)
  -h, --help   Show this help

Rollback snippets: $ROLLBACK_DIR
Logs:             $LOGFILE
EOF
            exit 0
            ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---------- Sanity ----------
[[ $EUID -eq 0 ]] || die "Must be run as root."
command -v pct >/dev/null  || die "pct not found — is this a PVE node?"
command -v pvesh >/dev/null || die "pvesh not found — is this a PVE node?"

touch "$LOGFILE" 2>/dev/null || die "Cannot write to logfile: $LOGFILE"
mkdir -p "$ROLLBACK_DIR" 2>/dev/null || die "Cannot create rollback dir: $ROLLBACK_DIR"

# ---------- Terminal setup ----------
# We deliberately use plain `read -rp` (NOT `read -e`/readline) for prompts.
# Readline manipulates terminal state in a way that some emulators (notably
# ZOC) mishandle — they echo the last input character at the next ANSI escape
# sequence, producing stray trailing characters after coloured output.
#
# Plain read doesn't do line-editing by itself, so we configure the terminal's
# erase character via stty to make Backspace work. We restore the original
# settings on exit.
if [[ -t 0 ]]; then
    _STTY_SAVE=$(stty -g 2>/dev/null || true)
    # erase=^? (DEL, 0x7f) is what most modern terminals send for Backspace.
    stty erase '^?' 2>/dev/null || true
    restore_tty() { [[ -n "${_STTY_SAVE:-}" ]] && stty "$_STTY_SAVE" 2>/dev/null || true; }
    trap restore_tty EXIT
fi

log_file "===== Session start (dry_run=$DRY_RUN) ====="

# ---------- Globals ----------
CLUSTER_NAME=""
CLUSTER_NODES=()
CLUSTER_RESOURCES_YAML=""
declare -A NODE_CT_COUNT
declare -A NODE_VM_COUNT
declare -A NODE_FREE_RAM_GB
declare -A NODE_FREE_DISK_GB
declare -A NODE_ONLINE
declare -A NODE_IP
declare -A NODE_PUBLIC_IP
declare -A NODE_EGRESS_IF

fmt_status() {
    local s="$1"
    case "$s" in
        running) printf '%s%s%s' "$GREEN"  "$s" "$NC" ;;
        stopped) printf '%s%s%s' "$YELLOW" "$s" "$NC" ;;
        *)       printf '%s' "$s" ;;
    esac
}

# ---------- YAML parsing helpers (replaces jq) ----------

# Extract scalar value from YAML by key (first match). Strips quotes.
# Usage: yaml_get_field "key" <<< "$yaml_text"
yaml_get_field() {
    local key="$1"
    awk -v k="$key" '
        $0 ~ "^[[:space:]]*"k":" {
            sub("^[[:space:]]*"k":[[:space:]]*", "")
            gsub(/^["'\'']|["'\'']$/, "")
            print
            exit
        }'
}

# Parse a YAML list of objects (from pvesh ... --output-format yaml) into
# pipe-separated rows. The yaml looks like:
#   ---
#   - field1: value1
#     field2: value2
#   - field1: value3
#     field2: value4
# Usage: yaml_list_to_rows "field1,field2" <<< "$yaml_text"
# Output: value1|value2 \n value3|value4
yaml_list_to_rows() {
    local fields="$1"
    awk -v fields="$fields" '
        BEGIN {
            n = split(fields, fld, ",")
        }
        /^- / {
            if (NR > 1 && started) {
                for (i=1; i<=n; i++) {
                    printf "%s%s", vals[fld[i]], (i<n ? "|" : "\n")
                    vals[fld[i]] = ""
                }
            }
            started = 1
            # First line of an object also has a field
            sub(/^- /, "  ")
        }
        started && /^[[:space:]]+[a-zA-Z_]+:/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            key = line
            sub(/:.*/, "", key)
            val = line
            sub(/^[^:]+:[[:space:]]*/, "", val)
            gsub(/^["'\'']|["'\'']$/, "", val)
            vals[key] = val
        }
        END {
            if (started) {
                for (i=1; i<=n; i++) {
                    printf "%s%s", vals[fld[i]], (i<n ? "|" : "\n")
                }
            }
        }'
}

extract_ct_info() {
    local id="$1" node="$2"
    local conf="/etc/pve/nodes/$node/lxc/$id.conf"
    local hn="" vlan="" ip="" mem="" disk_size="" storage="" volume=""
    if [[ -f "$conf" ]]; then
        hn=$(awk -F': *' '/^hostname:/ {print $2; exit}' "$conf")
        mem=$(awk -F': *' '/^memory:/ {print $2; exit}' "$conf")
        local net0
        net0=$(awk '/^net0:/ {sub(/^net0: */, ""); print; exit}' "$conf")
        if [[ -n "$net0" ]]; then
            vlan=$(echo "$net0" | grep -oP 'tag=\K[0-9]+' || true)
            ip=$(echo "$net0" | grep -oP 'ip=\K[^,]+' || true)
        fi
        local rootfs
        rootfs=$(awk '/^rootfs:/ {sub(/^rootfs: */, ""); print; exit}' "$conf")
        if [[ -n "$rootfs" ]]; then
            local volref="${rootfs%%,*}"
            storage="${volref%%:*}"
            volume="${volref#*:}"
            disk_size=$(echo "$rootfs" | grep -oP 'size=\K[^,]+' || true)
        fi
    fi
    echo "${hn}|${vlan}|${ip}|${mem}|${disk_size}|${storage}|${volume}"
}

ip_last_octet() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

compute_suggested_id() {
    local vlan="$1" ip="$2"
    local octet
    octet=$(ip_last_octet "$ip")
    if [[ -n "$vlan" && -n "$octet" ]]; then
        local padded
        if (( octet < 100 )); then
            padded=$(printf "%02d" "$octet")
        else
            padded="$octet"
        fi
        echo "${vlan}${padded}"
    fi
}

discover_cluster() {
    CLUSTER_NAME=$(pvecm status 2>/dev/null | awk -F': *' '/^Name:/ {print $2; exit}')
    [[ -n "$CLUSTER_NAME" ]] || CLUSTER_NAME="<standalone>"

    # ONE API call returns nodes, CTs, VMs and storage all at once
    local resources_yaml
    resources_yaml=$(pvesh get /cluster/resources --output-format yaml 2>/dev/null || echo "")
    [[ -n "$resources_yaml" ]] || die "Could not retrieve cluster resources."
    CLUSTER_RESOURCES_YAML="$resources_yaml"

    # Reset arrays
    CLUSTER_NODES=()
    NODE_CT_COUNT=()
    NODE_VM_COUNT=()
    NODE_FREE_RAM_GB=()
    NODE_FREE_DISK_GB=()
    NODE_ONLINE=()

    # Parse out node entries
    # type=node entries give us memory/maxmem and status
    while IFS='|' read -r type node status mem maxmem; do
        [[ "$type" != "node" ]] && continue
        [[ -z "$node" ]] && continue
        CLUSTER_NODES+=("$node")
        NODE_CT_COUNT[$node]=0
        NODE_VM_COUNT[$node]=0
        if [[ "$status" == "online" ]]; then
            NODE_ONLINE[$node]=1
            if [[ "$maxmem" =~ ^[0-9]+$ ]] && (( maxmem > 0 )); then
                NODE_FREE_RAM_GB[$node]=$(( (maxmem - mem) / 1024 / 1024 / 1024 ))
            else
                NODE_FREE_RAM_GB[$node]=0
            fi
        else
            NODE_ONLINE[$node]=0
            NODE_FREE_RAM_GB[$node]=0
        fi
        NODE_FREE_DISK_GB[$node]=0
    done < <(echo "$resources_yaml" | yaml_list_to_rows "type,node,status,mem,maxmem")

    # Sort node list
    if (( ${#CLUSTER_NODES[@]} > 0 )); then
        mapfile -t CLUSTER_NODES < <(printf '%s\n' "${CLUSTER_NODES[@]}" | sort)
    fi
    (( ${#CLUSTER_NODES[@]} > 0 )) || die "No nodes found in cluster."

    # Count CTs and VMs per node from the same response
    while IFS='|' read -r type node; do
        [[ -z "$node" ]] && continue
        case "$type" in
            lxc)   NODE_CT_COUNT[$node]=$(( ${NODE_CT_COUNT[$node]:-0} + 1 )) ;;
            qemu)  NODE_VM_COUNT[$node]=$(( ${NODE_VM_COUNT[$node]:-0} + 1 )) ;;
        esac
    done < <(echo "$resources_yaml" | yaml_list_to_rows "type,node")

    # Storage free space (local-lvm) per node — also from cluster/resources
    while IFS='|' read -r type node storage disk maxdisk; do
        [[ "$type" != "storage" ]] && continue
        [[ "$storage" != "local-lvm" ]] && continue
        if [[ "$maxdisk" =~ ^[0-9]+$ ]] && (( maxdisk > 0 )); then
            NODE_FREE_DISK_GB[$node]=$(( (maxdisk - disk) / 1024 / 1024 / 1024 ))
        fi
    done < <(echo "$resources_yaml" | yaml_list_to_rows "type,node,storage,disk,maxdisk")

    # Resolve each node's authoritative IP from /etc/pve/.members
    # File is JSON; we extract "node": "ip" pairs without jq.
    # Format excerpt:  "alatar": { "id": 3, "online": 1, "ip": "10.46.200.8" }
    NODE_IP=()
    if [[ -r /etc/pve/.members ]]; then
        local members_raw
        members_raw=$(tr -d '\n' < /etc/pve/.members)
        for n in "${CLUSTER_NODES[@]}"; do
            local ip
            # Match: "nodename": { ... "ip": "x.x.x.x" ... }
            ip=$(echo "$members_raw" | grep -oE "\"$n\"[^}]*\"ip\":\s*\"[0-9.]+\"" \
                | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
            NODE_IP[$n]="${ip:-}"
        done
    fi
    # Fallback: if /etc/pve/.members didn't yield, try /etc/hosts
    for n in "${CLUSTER_NODES[@]}"; do
        if [[ -z "${NODE_IP[$n]:-}" ]]; then
            local ip
            ip=$(getent hosts "$n" 2>/dev/null | awk '{print $1; exit}')
            NODE_IP[$n]="${ip:-$n}"  # last resort: use hostname itself
        fi
    done
}

# ---------- Consistency checks ----------

# Run a command either locally or via SSH to a given node.
_node_run() {
    local node="$1"; shift
    if [[ "$node" == "$THIS_HOST" ]]; then
        bash -c "$*"
    else
        local ip="${NODE_IP[$node]:-$node}"
        ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
            -o ConnectTimeout=5 "root@$ip" "$*"
    fi
}

# Build an SSH command prefix string for running commands on a remote node.
# Returns empty string if the node is the local host (so commands run locally).
# Usage:  PREFIX=$(ssh_prefix "$node");  run "${PREFIX:+$PREFIX }pct ..."
ssh_prefix() {
    local node="$1"
    [[ "$node" == "$THIS_HOST" ]] && { echo ""; return; }
    local ip="${NODE_IP[$node]:-$node}"
    echo "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 root@$ip"
}

# Sniff hostname from a (currently unused) LV by mounting RO.
# Returns the hostname string, "BUSY" if the LV is in use, or "" on error.
# Args: node, lv_name (e.g. vm-22513-disk-0)
lv_sniff_hostname() {
    local node="$1" lv="$2"
    local result
    result=$(_node_run "$node" "
        SNIFF=\$(mktemp -d /tmp/pct-renumber-sniff.XXXX)
        lvchange -ay pve/$lv >/dev/null 2>&1 || true
        if mount -o ro,noload /dev/pve/$lv \"\$SNIFF\" 2>/dev/null; then
            cat \"\$SNIFF/etc/hostname\" 2>/dev/null | tr -d '[:space:]'
            umount \"\$SNIFF\" 2>/dev/null
        else
            printf 'BUSY'
        fi
        rmdir \"\$SNIFF\" 2>/dev/null
    " 2>/dev/null) || result=""
    echo "$result"
}

# Pre-flight: scan each online node for orphan LVs and orphan /var/lib/lxc
# directories. An orphan is one where no /etc/pve/nodes/<node>/lxc/<id>.conf
# references it. Warn the user but do not auto-clean.
preflight_check() {
    info "Running pre-flight consistency check..."
    local issues=0
    local n

    # Build set of all configured CT IDs across the cluster
    declare -A configured_ids
    for n in "${CLUSTER_NODES[@]}"; do
        for f in /etc/pve/nodes/"$n"/lxc/*.conf; do
            [[ -f "$f" ]] || continue
            local id="${f##*/}"; id="${id%.conf}"
            configured_ids["$id"]="$n"
        done
    done

    for n in "${CLUSTER_NODES[@]}"; do
        [[ "${NODE_ONLINE[$n]:-0}" == "1" ]] || continue

        # Orphan LVs
        local lvs_raw
        lvs_raw=$(_node_run "$n" "lvs --noheadings -o lv_name pve 2>/dev/null" || true)
        while IFS= read -r lv; do
            lv=$(echo "$lv" | tr -d ' ')
            [[ "$lv" =~ ^vm-([0-9]+)-disk-[0-9]+$ ]] || continue
            local id="${BASH_REMATCH[1]}"
            if [[ -z "${configured_ids[$id]:-}" ]]; then
                warn "Orphan LV on $n: pve/$lv (no config references CT $id)"
                issues=$(( issues + 1 ))
            elif [[ "${configured_ids[$id]}" != "$n" ]]; then
                warn "Misplaced LV on $n: pve/$lv (CT $id is configured on ${configured_ids[$id]})"
                issues=$(( issues + 1 ))
            fi
        done <<< "$lvs_raw"

        # Orphan /var/lib/lxc dirs
        local dirs_raw
        dirs_raw=$(_node_run "$n" "ls /var/lib/lxc/ 2>/dev/null" || true)
        while IFS= read -r d; do
            [[ "$d" =~ ^[0-9]+$ ]] || continue
            if [[ ! -f "/etc/pve/nodes/$n/lxc/$d.conf" ]]; then
                warn "Orphan dir on $n: /var/lib/lxc/$d (no config for CT $d on this node)"
                issues=$(( issues + 1 ))
            fi
        done <<< "$dirs_raw"
    done

    if (( issues == 0 )); then
        log "Pre-flight clean — no orphans detected."
    else
        warn "$issues consistency issue(s) detected. Manual cleanup recommended."
        echo
        read -rp "  Press Enter to continue to main menu (or Ctrl-C to abort and investigate)..." _
    fi
    echo
}

# ---------- Egress IP detection (shared) ----------
# Self-contained shell snippet — produces "PUBLIC_IP|EGRESS_IF|METHOD" on stdout.
EGRESS_PROBE='
    EGRESS_IF=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oE "dev [^ ]+" | head -1 | cut -d" " -f2)
    EGRESS_IF=${EGRESS_IF:-?}
    PUB_IP=""
    METHOD=""
    for svc in ifconfig.me api.ipify.org ifconfig.co icanhazip.com; do
        for proto in https http; do
            if command -v curl >/dev/null 2>&1; then
                RAW=$(curl -4 -s --max-time 5 "${proto}://${svc}" 2>/dev/null)
                PUB_IP=$(echo "$RAW" | head -1 | tr -d "[:space:]" | grep -oE "^[0-9]{1,3}(\.[0-9]{1,3}){3}$")
                if [ -n "$PUB_IP" ]; then METHOD="curl ${svc}"; break 2; fi
            fi
            if command -v wget >/dev/null 2>&1; then
                RAW=$(wget -qO- --timeout=5 "${proto}://${svc}" 2>/dev/null)
                PUB_IP=$(echo "$RAW" | head -1 | tr -d "[:space:]" | grep -oE "^[0-9]{1,3}(\.[0-9]{1,3}){3}$")
                if [ -n "$PUB_IP" ]; then METHOD="wget ${svc}"; break 2; fi
            fi
        done
    done
    if [ -z "$PUB_IP" ] && command -v dig >/dev/null 2>&1; then
        PUB_IP=$(dig +short +time=3 myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -1 | grep -oE "^[0-9]{1,3}(\.[0-9]{1,3}){3}$")
        [ -n "$PUB_IP" ] && METHOD="dig opendns"
    fi
    if [ -z "$PUB_IP" ]; then
        HAVE_CURL=no; command -v curl >/dev/null 2>&1 && HAVE_CURL=yes
        HAVE_WGET=no; command -v wget >/dev/null 2>&1 && HAVE_WGET=yes
        HAVE_DIG=no;  command -v dig  >/dev/null 2>&1 && HAVE_DIG=yes
        METHOD="failed (curl=$HAVE_CURL wget=$HAVE_WGET dig=$HAVE_DIG)"
    fi
    echo "${PUB_IP}|${EGRESS_IF}|${METHOD}"
'

# Populate NODE_PUBLIC_IP[] and NODE_EGRESS_IF[] for every online node.
# Used at startup so the cluster overview can display the columns.
# Sets the global EGRESS_METHODS[] map too, for the dedicated egress action.
declare -A EGRESS_METHODS
egress_probe_all_nodes() {
    info "Probing egress public IPs (5s timeout per node)..."
    local n
    for n in "${CLUSTER_NODES[@]}"; do
        if [[ "${NODE_ONLINE[$n]:-0}" != "1" ]]; then
            NODE_PUBLIC_IP[$n]="-"
            NODE_EGRESS_IF[$n]="-"
            EGRESS_METHODS[$n]="offline"
            continue
        fi
        local result pub_ip egress_if method
        if [[ "$n" == "$THIS_HOST" ]]; then
            result=$(bash -c "$EGRESS_PROBE" 2>/dev/null || true)
        else
            result=$(ssh -o ConnectTimeout=5 \
                         -o StrictHostKeyChecking=accept-new \
                         -o BatchMode=yes \
                         "root@${NODE_IP[$n]:-$n}" "$EGRESS_PROBE" 2>/dev/null || true)
        fi
        if [[ -z "$result" ]]; then
            NODE_PUBLIC_IP[$n]="?"
            NODE_EGRESS_IF[$n]="?"
            EGRESS_METHODS[$n]="ssh failed"
        else
            IFS='|' read -r pub_ip egress_if method <<< "$result"
            NODE_PUBLIC_IP[$n]="${pub_ip:-?}"
            NODE_EGRESS_IF[$n]="${egress_if:-?}"
            EGRESS_METHODS[$n]="${method:-?}"
        fi
    done
}

show_cluster_overview() {
    echo
    printf '  %s%s%s%s Cluster: %s %s%s%s%s\n' \
        "$CYAN" "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" \
        "$CLUSTER_NAME" \
        "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" "$NC"
    echo
    printf "  %-12s %-10s %-7s %-7s %-10s %-10s %-17s %-10s\n" \
        "Node" "Status" "CTs" "VMs" "Free RAM" "Free Disk" "Public IP" "Egress IF"
    printf "  %-12s %-10s %-7s %-7s %-10s %-10s %-17s %-10s\n" \
        "----" "------" "---" "---" "--------" "---------" "---------" "---------"
    for n in "${CLUSTER_NODES[@]}"; do
        local stcol pad
        if [[ "${NODE_ONLINE[$n]}" == "1" ]]; then
            stcol="${GREEN}${G_OK_DOT} online${NC}"; pad=$((10 - 8))
        else
            stcol="${RED}${G_CROSS} offline${NC}"; pad=$((10 - 9))
        fi
        (( pad < 0 )) && pad=0
        printf "  %-12s ${stcol}%*s %-7s %-7s %-10s %-10s %-17s %-10s\n" \
            "$n" "$pad" "" \
            "[${NODE_CT_COUNT[$n]}]" \
            "[${NODE_VM_COUNT[$n]}]" \
            "${NODE_FREE_RAM_GB[$n]} GB" \
            "${NODE_FREE_DISK_GB[$n]} GB" \
            "${NODE_PUBLIC_IP[$n]:-?}" \
            "${NODE_EGRESS_IF[$n]:-?}"
    done
    echo
}

top_menu() {
    local first_run=1
    while true; do
        if (( first_run == 1 )); then
            show_splash
            first_run=0
        fi
        show_cluster_overview
        echo "  What would you like to do?"
        echo
        printf '  %s1)%s Configure a container           %s change ID, hostname, VLAN, IP, MAC, and/or node\n' "$GREEN" "$NC" "$G_DASH"
        printf '  %s2)%s Refresh cluster overview        %s re-poll cluster state\n' "$CYAN" "$NC" "$G_DASH"
        echo "  q) Quit"
        echo
        read -rp "  Choice: " CHOICE
        case "$CHOICE" in
            1) action_configure ;;
            2) discover_cluster; egress_probe_all_nodes ;;
            q|Q) info "Exiting."; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# Sets SELECTED_NODE to a node name or "ALL"; returns 1 if user backs out
SELECTED_NODE=""
select_node() {
    local allow_all="${1:-1}"
    while true; do
        echo
        echo "Available nodes:"
        local i=1
        declare -gA NODE_INDEX
        NODE_INDEX=()
        for n in "${CLUSTER_NODES[@]}"; do
            local marker=""
            [[ "${NODE_ONLINE[$n]}" == "0" ]] && marker=" ${RED}(offline)${NC}"
            printf "  %d) %-12s  [%s CTs] [%s VMs]%s\n" \
                "$i" "$n" "${NODE_CT_COUNT[$n]}" "${NODE_VM_COUNT[$n]}" "$marker"
            NODE_INDEX[$i]="$n"
            i=$(( i + 1 ))
        done
        (( allow_all == 1 )) && echo "  a) All nodes (combined view)"
        echo "  b) Back to main menu"
        echo
        read -rp "Select node: " NC
        case "$NC" in
            b|B) return 1 ;;
            a|A) [[ $allow_all -eq 1 ]] && { SELECTED_NODE="ALL"; return 0; } ;;
            *)
                if [[ "$NC" =~ ^[0-9]+$ ]] && [[ -n "${NODE_INDEX[$NC]:-}" ]]; then
                    SELECTED_NODE="${NODE_INDEX[$NC]}"
                    return 0
                fi
                for n in "${CLUSTER_NODES[@]}"; do
                    if [[ "$n" == "$NC" ]]; then
                        SELECTED_NODE="$n"; return 0
                    fi
                done
                warn "Invalid selection."
                ;;
        esac
    done
}

# Selection result globals
SEL_CT_ID="" SEL_CT_NODE="" SEL_CT_HOSTNAME="" SEL_CT_VLAN=""
SEL_CT_IP="" SEL_CT_STATUS="" SEL_CT_MEM="" SEL_CT_DISK=""
SEL_CT_STORAGE="" SEL_CT_VOLUME=""

# Returns 0 = selected, 1 = back, 2 = pick another node
select_ct() {
    local node_filter="$1"
    local search_term=""
    local nodes_to_scan=()
    if [[ "$node_filter" == "ALL" ]]; then
        nodes_to_scan=("${CLUSTER_NODES[@]}")
    else
        nodes_to_scan=("$node_filter")
    fi

    while true; do
        declare -A LIST_MAP
        LIST_MAP=()
        local idx=0
        local rows=()

        # Build list of all CTs from cached resources, filtered by node
        local all_cts
        all_cts=$(echo "$CLUSTER_RESOURCES_YAML" | yaml_list_to_rows "type,vmid,node,status" \
            | awk -F'|' '$1=="lxc" {print $2"|"$3"|"$4}' | sort -n)

        for n in "${nodes_to_scan[@]}"; do
            local ct_list
            ct_list=$(echo "$all_cts" | awk -F'|' -v node="$n" '$2==node {print $1"|"$3}')
            while IFS='|' read -r vmid status; do
                [[ -z "$vmid" ]] && continue
                local hn vlan ip mem disk_size storage volume
                IFS='|' read -r hn vlan ip mem disk_size storage volume \
                    <<< "$(extract_ct_info "$vmid" "$n")"
                hn="${hn:-<unset>}"; vlan="${vlan:--}"; ip="${ip:--}"

                if [[ -n "$search_term" ]]; then
                    if ! echo "$vmid $hn $ip $vlan $n" | grep -qi -- "$search_term"; then
                        continue
                    fi
                fi

                idx=$(( idx + 1 ))
                LIST_MAP[$idx]="$vmid|$n|$hn|$vlan|$ip|$status|$mem|$disk_size|$storage|$volume"
                rows+=("$idx|$vmid|$n|$hn|$vlan|$ip|$status|$disk_size")
            done <<< "$ct_list"
        done

        echo
        if [[ "$node_filter" == "ALL" ]]; then
            echo "LXC containers across cluster:"
        else
            echo "LXC containers on $node_filter:"
        fi
        [[ -n "$search_term" ]] && echo "  (filtered by: \"$search_term\")${NC}"

        if (( idx == 0 )); then
            warn "No LXC containers found$([[ -n "$search_term" ]] && echo " matching filter")."
            if [[ "$node_filter" != "ALL" ]]; then
                local vm_n="${NODE_VM_COUNT[$node_filter]:-0}"
                (( vm_n > 0 )) && info "Node has $vm_n VM(s), which this tool cannot manage."
            fi
            echo
            echo "  n) Pick another node    r) Reset filter    b) Back    q) Quit"
            read -rp "Choice: " EC
            case "$EC" in
                n|N) return 2 ;;
                r|R) search_term=""; continue ;;
                q|Q) exit 0 ;;
                *)   return 1 ;;
            esac
        fi

        printf "  %-4s %-7s %-10s %-22s %-6s %-20s %-10s %s\n" \
            "#" "ID" "Node" "Hostname" "VLAN" "IP" "Status" "Size"
        printf "  %-4s %-7s %-10s %-22s %-6s %-20s %-10s %s\n" \
            "---" "------" "---------" "---------------------" "-----" \
            "-------------------" "---------" "------"
        for row in "${rows[@]}"; do
            local i vmid n hn vlan ip status disk_size stcol pad
            IFS='|' read -r i vmid n hn vlan ip status disk_size <<< "$row"
            stcol=$(fmt_status "$status")
            pad=$(( 10 - ${#status} )); (( pad < 0 )) && pad=0
            printf "  %-4s %-7s %-10s %-22s %-6s %-20s ${stcol}%*s %s\n" \
                "${i})" "$vmid" "$n" "$hn" "$vlan" "$ip" "$pad" "" "${disk_size:--}"
        done
        echo
        echo "  Enter # to select | f) Filter | r) Reset filter | n) Pick another node | b) Back | q) Quit"
        echo
        read -rp "Choice: " CC
        case "$CC" in
            b|B) return 1 ;;
            n|N) return 2 ;;
            r|R) search_term=""; continue ;;
            f|F) read -rp "Filter by (ID, hostname, IP, VLAN, node): " search_term; continue ;;
            q|Q) exit 0 ;;
            *)
                if [[ "$CC" =~ ^[0-9]+$ ]] && [[ -n "${LIST_MAP[$CC]:-}" ]]; then
                    IFS='|' read -r SEL_CT_ID SEL_CT_NODE SEL_CT_HOSTNAME \
                        SEL_CT_VLAN SEL_CT_IP SEL_CT_STATUS SEL_CT_MEM \
                        SEL_CT_DISK SEL_CT_STORAGE SEL_CT_VOLUME \
                        <<< "${LIST_MAP[$CC]}"
                    return 0
                fi
                warn "Invalid selection."
                ;;
        esac
    done
}

ct_has_snapshots() {
    local id="$1" node="$2"
    local conf="/etc/pve/nodes/$node/lxc/$id.conf"
    [[ -f "$conf" ]] || return 1
    local count
    count=$(awk '/^\[.+\]/ {c++} END {print c+0}' "$conf")
    (( count > 0 ))
}

id_in_use() {
    local id="$1"
    local rows
    rows=$(echo "$CLUSTER_RESOURCES_YAML" | yaml_list_to_rows "vmid,type,node")
    while IFS='|' read -r vmid type node; do
        [[ "$vmid" == "$id" ]] && [[ "$type" == "lxc" || "$type" == "qemu" ]] \
            && { echo "$type on $node"; return 0; }
    done <<< "$rows"
    return 1
}

update_net0_in_config() {
    local conf="$1" new_ip="$2" new_vlan="$3" new_mac="${4:-}"
    local current_line new_line
    current_line=$(awk '/^net0:/ {sub(/^net0: */, ""); print; exit}' "$conf")
    new_line="$current_line"

    if [[ -n "$new_ip" ]]; then
        if echo "$new_line" | grep -q 'ip='; then
            new_line=$(echo "$new_line" | sed -E "s|ip=[^,]+|ip=${new_ip}|")
        else
            new_line="${new_line},ip=${new_ip}"
        fi
    fi
    if [[ -n "$new_vlan" ]]; then
        if echo "$new_line" | grep -q 'tag='; then
            new_line=$(echo "$new_line" | sed -E "s|tag=[0-9]+|tag=${new_vlan}|")
        else
            new_line="${new_line},tag=${new_vlan}"
        fi
    fi
    if [[ -n "$new_mac" ]]; then
        if echo "$new_line" | grep -q 'hwaddr='; then
            new_line=$(echo "$new_line" | sed -E "s|hwaddr=[^,]+|hwaddr=${new_mac}|")
        else
            new_line="${new_line},hwaddr=${new_mac}"
        fi
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "Would update net0 in $conf:"
        echo "         Old: net0: $current_line"
        echo "         New: net0: $new_line"
    else
        sed -i "s|^net0:.*|net0: $new_line|" "$conf"
    fi
    log_file "net0 updated in $conf: $current_line  -->  $new_line"
}

# Generate a Proxmox-style MAC address (BC:24:11:XX:XX:XX prefix).
# Uses /dev/urandom for the random bytes — RANDOM is biased and predictable.
generate_mac() {
    local b4 b5 b6
    if [[ -r /dev/urandom ]]; then
        read -r b4 b5 b6 < <(od -An -N3 -tx1 /dev/urandom | tr -d ' ' | sed 's/\(..\)\(..\)\(..\)/\1 \2 \3/')
    else
        b4=$(printf '%02x' $(( RANDOM & 0xff )))
        b5=$(printf '%02x' $(( RANDOM & 0xff )))
        b6=$(printf '%02x' $(( RANDOM & 0xff )))
    fi
    printf 'BC:24:11:%s:%s:%s\n' "${b4^^}" "${b5^^}" "${b6^^}"
}

# Extract the current MAC from a config file's net0 line.
get_current_mac() {
    local conf="$1"
    awk '/^net0:/ {
        if (match($0, /hwaddr=[A-Fa-f0-9:]+/)) {
            s = substr($0, RSTART+7, RLENGTH-7)
            print s
        }
        exit
    }' "$conf"
}

# Update the hostname: line in the CT config file.
# Note: the actual /etc/hostname inside the CT only refreshes on next boot.
update_hostname_in_config() {
    local conf="$1" new_hostname="$2"
    local current_hostname
    current_hostname=$(awk -F': *' '/^hostname:/ {print $2; exit}' "$conf")

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "Would update hostname in $conf:"
        echo "         Old: hostname: ${current_hostname:-<unset>}"
        echo "         New: hostname: $new_hostname"
    else
        if grep -q '^hostname:' "$conf"; then
            sed -i "s|^hostname:.*|hostname: $new_hostname|" "$conf"
        else
            # Insert hostname line at top of config (above first network/disk entry)
            sed -i "1i hostname: $new_hostname" "$conf"
        fi
    fi
    log_file "hostname updated in $conf: ${current_hostname:-<unset>} --> $new_hostname"
}

# Validate hostname per RFC 1123: 1-63 chars, letters/digits/hyphens, no
# leading or trailing hyphen.
valid_hostname() {
    local h="$1"
    [[ ${#h} -ge 1 && ${#h} -le 63 ]] || return 1
    [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    return 0
}

write_rollback_net() {
    local f="$1" id="$2" node="$3" old_vlan="$4" old_ip="$5" old_hostname="${6:-}"
    cat > "$f" <<EOF
#!/usr/bin/env bash
# Rollback for network/hostname change on CT $id ($(date))
# Restores VLAN=$old_vlan IP=$old_ip HOSTNAME=$old_hostname
set -e
CONF="/etc/pve/nodes/$node/lxc/$id.conf"
[[ -f "\$CONF" ]] || { echo "Config not found: \$CONF"; exit 1; }
cp "\$CONF" "\$CONF.before-rollback-\$(date +%s)"
LINE=\$(awk '/^net0:/ {sub(/^net0: */, ""); print; exit}' "\$CONF")
EOF
    if [[ -n "$old_ip" && "$old_ip" != "-" ]]; then
        echo "LINE=\$(echo \"\$LINE\" | sed -E 's|ip=[^,]+|ip=$old_ip|')" >> "$f"
    fi
    if [[ -n "$old_vlan" && "$old_vlan" != "-" ]]; then
        echo "LINE=\$(echo \"\$LINE\" | sed -E 's|tag=[0-9]+|tag=$old_vlan|')" >> "$f"
    fi
    cat >> "$f" <<EOF
sed -i "s|^net0:.*|net0: \$LINE|" "\$CONF"
EOF
    if [[ -n "$old_hostname" ]]; then
        echo "sed -i 's|^hostname:.*|hostname: $old_hostname|' \"\$CONF\"" >> "$f"
    fi
    cat >> "$f" <<EOF
echo "Rollback applied for CT $id"
EOF
    chmod +x "$f"
}

write_rollback_renumber() {
    local f="$1" old_id="$2" new_id="$3" tgt_node="$4" src_node="$5"
    shift 5
    local rename_ops=("$@")
    cat > "$f" <<EOF
#!/usr/bin/env bash
# Rollback for CT renumber: $new_id -> $old_id ($(date))
# Originally on $src_node, currently on $tgt_node
#
# IMPORTANT: run this script ON the node that currently owns the CT ($tgt_node).
# The lvrename and config operations below assume local execution on $tgt_node.
set -e
echo "Stopping CT $new_id..."
pct stop $new_id 2>/dev/null || true
EOF
    for op in "${rename_ops[@]}"; do
        local storage oldvol newvol vg
        IFS='|' read -r storage oldvol newvol vg <<< "$op"
        echo "lvrename $vg $newvol $oldvol" >> "$f"
    done
    cat >> "$f" <<EOF
NEW_CONF="/etc/pve/nodes/$tgt_node/lxc/$new_id.conf"
OLD_CONF="/etc/pve/nodes/$tgt_node/lxc/$old_id.conf"
[[ -f "\$NEW_CONF" ]] && {
    cp "\$NEW_CONF" "\$OLD_CONF"
    sed -i 's/vm-${new_id}-disk/vm-${old_id}-disk/g' "\$OLD_CONF"
    rm "\$NEW_CONF"
}
EOF
    if [[ "$src_node" != "$tgt_node" ]]; then
        echo "pct migrate $old_id $src_node" >> "$f"
    fi
    echo "echo \"Rollback complete: CT is now $old_id\"" >> "$f"
    chmod +x "$f"
}

action_configure() {
    if ! select_node 1; then return; fi
    local node="$SELECTED_NODE"
    while true; do
        if select_ct "$node"; then
            break
        else
            local rc=$?
            if (( rc == 2 )); then
                select_node 1 || return
                node="$SELECTED_NODE"
                continue
            else
                return
            fi
        fi
    done

    local SRC_ID="$SEL_CT_ID"
    local SRC_NODE="$SEL_CT_NODE"
    local HOSTNAME="$SEL_CT_HOSTNAME"
    local VLAN="$SEL_CT_VLAN"
    local IP_RAW="$SEL_CT_IP"
    local MEM="$SEL_CT_MEM"
    local DISK="$SEL_CT_DISK"

    [[ "$HOSTNAME" == "<unset>" ]] && HOSTNAME=""
    [[ "$VLAN" == "-" ]] && VLAN=""
    [[ "$IP_RAW" == "-" ]] && IP_RAW=""

    echo
    banner "Source Container Details"
    printf "  ${CYAN}%-15s${NC} %s\n" "ID:"        "$SRC_ID"
    printf "  ${CYAN}%-15s${NC} %s\n" "Hostname:"  "${HOSTNAME:-<unknown>}"
    printf "  ${CYAN}%-15s${NC} %s\n" "Node:"      "$SRC_NODE"
    printf "  ${CYAN}%-15s${NC} %s\n" "Status:"    "$(fmt_status "$SEL_CT_STATUS")"
    printf "  ${CYAN}%-15s${NC} %s\n" "VLAN tag:"  "${VLAN:-<none>}"
    printf "  ${CYAN}%-15s${NC} %s\n" "IP:"        "${IP_RAW:-<unknown>}"
    printf "  ${CYAN}%-15s${NC} %s\n" "Memory:"    "${MEM:-?} MB"
    printf "  ${CYAN}%-15s${NC} %s\n" "Disk size:" "${DISK:-?}"

    echo
    info "Press Enter at any prompt to keep the current value."
    echo

    # Collect proposed changes
    local NEW_HOSTNAME NEW_VLAN NEW_IP NEW_ID
    read -rp "New hostname (Enter to keep '${HOSTNAME:-<unset>}'): " NEW_HOSTNAME
    read -rp "New VLAN tag (Enter to keep '${VLAN:-none}', '-' to remove): " NEW_VLAN
    read -rp "New IP CIDR (Enter to keep '${IP_RAW:-none}', 'dhcp' for DHCP): " NEW_IP

    if [[ -n "$NEW_HOSTNAME" ]] && ! valid_hostname "$NEW_HOSTNAME"; then
        err "Invalid hostname '$NEW_HOSTNAME' (must be 1-63 chars, alphanumeric + hyphens)"
        return
    fi

    # Compute suggested ID from final VLAN/IP values
    local FINAL_VLAN="${NEW_VLAN:-$VLAN}"
    local FINAL_IP="${NEW_IP:-$IP_RAW}"
    [[ "$FINAL_VLAN" == "-" ]] && FINAL_VLAN=""
    local SUGGESTED
    SUGGESTED=$(compute_suggested_id "$FINAL_VLAN" "$FINAL_IP")

    if [[ -n "$SUGGESTED" ]]; then
        echo
        printf '  %sSuggested ID based on VLAN+IP: %s%s\n' "$GREEN" "$SUGGESTED" "$NC"
        read -rp "New container ID (Enter to keep $SRC_ID): " NEW_ID
    else
        read -rp "New container ID (Enter to keep $SRC_ID): " NEW_ID
    fi

    # If user pressed Enter, NEW_ID = current ID (no renumber)
    NEW_ID="${NEW_ID:-$SRC_ID}"

    [[ "$NEW_ID" =~ ^[0-9]+$ ]] || { err "Invalid new ID '$NEW_ID'"; return; }
    if (( NEW_ID < 100 )); then
        warn "New ID < 100 is typically reserved. Proceeding anyway."
    fi

    # Target node selection
    echo
    echo "  Available target nodes:"
    local i=1
    declare -A TGT_INDEX
    local mem_gb_needed=0
    [[ -n "$MEM" ]] && mem_gb_needed=$(( (MEM + 1023) / 1024 ))
    for n in "${CLUSTER_NODES[@]}"; do
        local marker=""
        [[ "$n" == "$SRC_NODE" ]] && marker=" (current)"
        local warn_str=""
        if [[ "$n" != "$SRC_NODE" ]] && (( mem_gb_needed > 0 )) \
           && (( ${NODE_FREE_RAM_GB[$n]} < mem_gb_needed )); then
            warn_str=" ${RED}(needs ${mem_gb_needed} GB, only ${NODE_FREE_RAM_GB[$n]} GB free)${NC}"
        fi
        printf "  %d) %-12s  free: %s GB RAM, %s GB disk%s%s\n" \
            "$i" "$n" "${NODE_FREE_RAM_GB[$n]}" "${NODE_FREE_DISK_GB[$n]}" "$marker" "$warn_str"
        TGT_INDEX[$i]="$n"
        i=$(( i + 1 ))
    done
    echo
    read -rp "Target node (Enter to keep $SRC_NODE): " TC
    local TGT_NODE
    if [[ -z "$TC" ]]; then
        TGT_NODE="$SRC_NODE"
    elif [[ "$TC" =~ ^[0-9]+$ ]] && [[ -n "${TGT_INDEX[$TC]:-}" ]]; then
        TGT_NODE="${TGT_INDEX[$TC]}"
    else
        local matched=0
        for n in "${CLUSTER_NODES[@]}"; do
            [[ "$n" == "$TC" ]] && { TGT_NODE="$n"; matched=1; break; }
        done
        (( matched == 1 )) || { err "Invalid target"; return; }
    fi

    # ---- Leave source behind? (Copy vs Move) ----
    # The question makes sense in three situations:
    #   1. Cross-node move + same ID — backup stays on source, original migrates
    #   2. Cross-node move + new ID  — backup stays on source under new ID
    #   3. Same-node + new ID        — local clone (duplicate in place)
    # Whenever Copy is chosen, the "kept on source" CT needs an ID different
    # from the one going to the target. We always end up with two distinct IDs.
    local LEAVE_SOURCE_BEHIND=0
    local BACKUP_ID=""     # the ID of the stopped backup on $SRC_NODE
    local SAME_NODE_CLONE=0
    if [[ "$NEW_ID" != "$SRC_ID" ]] || [[ "$TGT_NODE" != "$SRC_NODE" ]]; then
        echo
        info "Operation mode:"
        echo "  ${G_DASH} ${CYAN}Move${NC}  : source CT $SRC_ID is migrated/renamed and removed from $SRC_NODE"
        echo "  ${G_DASH} ${CYAN}Copy${NC}  : a stopped backup is left on $SRC_NODE,"
        echo "             the resulting CT goes to $TGT_NODE (or stays in place for same-node clone)"
        read -rp "Leave a stopped backup on $SRC_NODE? [y/N]: " LEAVE
        [[ "${LEAVE,,}" == "y" ]] && LEAVE_SOURCE_BEHIND=1

        if (( LEAVE_SOURCE_BEHIND == 1 )); then
            # Decide which CT keeps SRC_ID and which CT gets the new ID.
            #
            # Case A — user gave a NEW_ID different from SRC_ID:
            #   The resulting CT keeps NEW_ID, the backup retains SRC_ID.
            #   We just clone SRC_ID -> NEW_ID, then migrate NEW_ID if needed.
            #   The "backup" is the untouched source CT at SRC_ID.
            #   No extra prompt needed.
            #
            # Case B — user kept NEW_ID == SRC_ID (so NEW_ID hasn't been set
            # to anything different) AND we have a node change:
            #   The migrated CT keeps SRC_ID on the target; the backup needs
            #   a NEW ID on the source. Prompt for it.
            #
            # Case C — same node, same ID, user wants a copy: impossible
            # because we required NEW_ID!=SRC_ID OR node change to even
            # reach this block. Won't happen.
            if [[ "$NEW_ID" == "$SRC_ID" ]]; then
                # Case B — node change without ID change. Need a backup ID.
                echo
                info "Cross-node move with backup: the migrated CT keeps ID $SRC_ID on $TGT_NODE."
                info "The backup on $SRC_NODE needs a different ID."
                local SUGG_BACKUP_ID
                # Suggest 9XXXX prefix to mark it as a backup (e.g. 22514 -> 92514)
                if (( SRC_ID < 10000 )); then
                    SUGG_BACKUP_ID="9${SRC_ID}"
                elif (( SRC_ID < 100000 )); then
                    SUGG_BACKUP_ID="9${SRC_ID:1}"
                else
                    SUGG_BACKUP_ID="$((SRC_ID + 90000))"
                fi
                while true; do
                    read -rp "Backup CT ID on $SRC_NODE (Enter for suggested $SUGG_BACKUP_ID): " BACKUP_ID
                    BACKUP_ID="${BACKUP_ID:-$SUGG_BACKUP_ID}"
                    if ! [[ "$BACKUP_ID" =~ ^[0-9]+$ ]]; then
                        warn "Invalid ID."
                        continue
                    fi
                    if [[ "$BACKUP_ID" == "$SRC_ID" ]]; then
                        warn "Backup ID must differ from source ID."
                        continue
                    fi
                    local collision
                    if collision=$(id_in_use "$BACKUP_ID"); then
                        warn "Backup ID $BACKUP_ID already in use: $collision"
                        continue
                    fi
                    break
                done
                # Same-node clone flag — backup creation happens on source,
                # then we still migrate the original SRC_ID to TGT_NODE.
                # Distinguish from Case A which renumbers via clone.
                SAME_NODE_CLONE=1
                info "Will clone $SRC_ID ${G_ARROW} $BACKUP_ID on $SRC_NODE (backup), then migrate $SRC_ID to $TGT_NODE."
            else
                # Case A — clone SRC_ID -> NEW_ID. Backup IS the original SRC_ID.
                BACKUP_ID="$SRC_ID"
                info "Will clone $SRC_ID ${G_ARROW} $NEW_ID; original $SRC_ID stays as backup on $SRC_NODE."
            fi

            # Same-node + ID change: we don't migrate; both CTs end up on
            # SRC_NODE. That's the "local clone" use case.
            if [[ "$TGT_NODE" == "$SRC_NODE" ]]; then
                info "Same-node clone: both CTs will reside on $SRC_NODE after the operation."
            fi
        fi
    fi

    # ---- MAC address handling ----
    # LXC migrate, rename, and pct clone all PRESERVE the MAC address by
    # default (unlike VM clones, which auto-regenerate). Preserving the MAC
    # is critical for DHCP-assigned IPs: same MAC = same DHCP lease = same IP.
    # We ask explicitly so the user makes a conscious choice.
    local CURRENT_MAC NEW_MAC=""
    CURRENT_MAC=$(get_current_mac "/etc/pve/nodes/$SRC_NODE/lxc/$SRC_ID.conf")
    echo
    if (( LEAVE_SOURCE_BEHIND == 1 )); then
        # In Copy mode, regenerating prevents two CTs sharing the same MAC
        # if the source is ever started again — but source-stays-stopped is
        # the intent, so keeping MAC is still safe and DHCP-friendly.
        info "MAC address: keeping the source MAC ($CURRENT_MAC) preserves the DHCP lease for the new CT."
        info "             (Source stays stopped, so there's no immediate conflict either way.)"
    else
        info "MAC address: keeping the current MAC ($CURRENT_MAC) preserves DHCP-assigned IPs."
    fi
    read -rp "Regenerate MAC address for the resulting CT? [y/N]: " REGEN
    if [[ "${REGEN,,}" == "y" ]]; then
        NEW_MAC=$(generate_mac)
        info "New MAC will be: $NEW_MAC"
    fi

    # ---- Determine what's actually changing ----
    local RENUMBER_NEEDED=0
    local MIGRATE_NEEDED=0
    local HOSTNAME_CHANGE=0
    local NETWORK_CHANGE=0
    local MAC_CHANGE=0

    [[ "$NEW_ID" != "$SRC_ID" ]] && RENUMBER_NEEDED=1
    [[ "$TGT_NODE" != "$SRC_NODE" ]] && MIGRATE_NEEDED=1
    [[ -n "$NEW_HOSTNAME" ]] && HOSTNAME_CHANGE=1
    [[ -n "$NEW_VLAN" || -n "$NEW_IP" ]] && NETWORK_CHANGE=1
    [[ -n "$NEW_MAC" ]] && { MAC_CHANGE=1; NETWORK_CHANGE=1; }

    # Abort if nothing is changing
    if (( RENUMBER_NEEDED == 0 && MIGRATE_NEEDED == 0 \
        && HOSTNAME_CHANGE == 0 && NETWORK_CHANGE == 0 )); then
        info "No changes requested — returning to menu."
        return
    fi

    # PVE does NOT support true live migration for LXC (only QEMU/KVM).
    # The script explicitly stops the CT, waits for kernel mount teardown,
    # then performs an offline migrate, then starts the CT on the target.

    # ID collision check (only if renumbering)
    if (( RENUMBER_NEEDED == 1 )); then
        info "Checking ID availability cluster-wide..."
        local collision
        if collision=$(id_in_use "$NEW_ID"); then
            err "ID $NEW_ID already in use: $collision"
            return
        fi
        log "ID $NEW_ID is available."
    fi

    # Snapshot check (renumber doesn't tolerate them; migrate handles them OK)
    if (( RENUMBER_NEEDED == 1 )) && ct_has_snapshots "$SRC_ID" "$SRC_NODE"; then
        err "CT $SRC_ID has snapshots. Remove first via: pct delsnapshot $SRC_ID <name>"
        return
    fi

    # Bind mount check for cross-node migration
    local conf_src="/etc/pve/nodes/$SRC_NODE/lxc/$SRC_ID.conf"
    local mp_lines
    mp_lines=$(grep -E '^mp[0-9]+:' "$conf_src" 2>/dev/null || true)
    if [[ -n "$mp_lines" ]] && (( MIGRATE_NEEDED == 1 )); then
        echo
        warn "CT has bind mounts / mount points — these must exist on $TGT_NODE:"
        echo "$mp_lines" | sed 's/^/    /'
        read -rp "Continue anyway? [y/N]: " MPC
        [[ "${MPC,,}" == "y" ]] || { info "Cancelled."; return; }
    fi

    # Backup job check (only matters if renumbering)
    local backup_refs=()
    local UPDATE_JOBS="N"
    if (( RENUMBER_NEEDED == 1 )) && [[ -f "$JOBS_CFG" ]]; then
        while IFS= read -r line; do
            backup_refs+=("$line")
        done < <(grep -nE "^[[:space:]]*vmid[[:space:]]+.*\b${SRC_ID}\b" "$JOBS_CFG" || true)
        if (( ${#backup_refs[@]} > 0 )); then
            echo
            warn "${#backup_refs[@]} backup job reference(s) to CT $SRC_ID found:"
            for r in "${backup_refs[@]}"; do echo "    $r"; done
            read -rp "Update jobs.cfg to replace $SRC_ID with $NEW_ID? [y/N]: " UPDATE_JOBS
            UPDATE_JOBS="${UPDATE_JOBS:-N}"
        fi
    fi

    # ---- Final summary ----
    echo
    banner "Operation Summary"
    printf "  ${CYAN}%-22s${NC} %s\n" "Source CT:" "$SRC_ID ($HOSTNAME) on $SRC_NODE"
    if (( LEAVE_SOURCE_BEHIND == 1 )); then
        if (( SAME_NODE_CLONE == 1 )); then
            printf "  ${CYAN}%-22s${NC} %s\n" "Mode:" "Copy (backup $BACKUP_ID on $SRC_NODE, original $SRC_ID moves to $TGT_NODE)"
        else
            printf "  ${CYAN}%-22s${NC} %s\n" "Mode:" "Copy (source $SRC_ID kept as backup, new CT $NEW_ID created)"
        fi
    elif (( RENUMBER_NEEDED == 1 )) || (( MIGRATE_NEEDED == 1 )); then
        printf "  ${CYAN}%-22s${NC} %s\n" "Mode:" "Move (source removed)"
    else
        printf "  ${CYAN}%-22s${NC} %s\n" "Mode:" "In-place edit"
    fi
    if (( RENUMBER_NEEDED == 1 )); then
        printf "  ${CYAN}%-22s${NC} %s ${G_ARROW} %s\n" "New CT ID:" "$SRC_ID" "$NEW_ID"
    fi
    if (( HOSTNAME_CHANGE == 1 )); then
        printf "  ${CYAN}%-22s${NC} %s ${G_ARROW} %s\n" "Hostname change:" "${HOSTNAME:-<unset>}" "$NEW_HOSTNAME"
    fi
    if [[ -n "$NEW_VLAN" ]]; then
        printf "  ${CYAN}%-22s${NC} %s ${G_ARROW} %s\n" "VLAN change:" "${VLAN:-<none>}" "$NEW_VLAN"
    fi
    if [[ -n "$NEW_IP" ]]; then
        printf "  ${CYAN}%-22s${NC} %s ${G_ARROW} %s\n" "IP change:" "${IP_RAW:-<none>}" "$NEW_IP"
    fi
    if (( MAC_CHANGE == 1 )); then
        printf "  ${CYAN}%-22s${NC} %s ${G_ARROW} %s\n" "MAC change:" "${CURRENT_MAC:-<unknown>}" "$NEW_MAC"
    else
        printf "  ${CYAN}%-22s${NC} %s\n" "MAC preserved:" "${CURRENT_MAC:-<unknown>}"
    fi
    if (( MIGRATE_NEEDED == 1 )); then
        printf "  ${CYAN}%-22s${NC} %s ${G_ARROW} %s\n" "Target node:" "$SRC_NODE" "$TGT_NODE"
    fi
    printf "  ${CYAN}%-22s${NC} %s\n" "Update jobs.cfg:" "$([[ "${UPDATE_JOBS^^}" == "Y" ]] && echo YES || echo no)"
    printf "  ${CYAN}%-22s${NC} %s\n" "Dry run:" "$([[ $DRY_RUN -eq 1 ]] && echo YES || echo no)"
    echo
    read -rp "  Proceed? [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { info "Cancelled."; return; }

    # ---- Execute ----

    # Determine SSH prefix for the SOURCE node (where the CT lives before
    # any migration). pct stop / pct status / pct migrate all need to run
    # on the node that owns the CT.
    local SRC_PREFIX
    SRC_PREFIX=$(ssh_prefix "$SRC_NODE")

    # Detect features that complicate teardown (nesting, fuse, etc.) — these
    # need extra settle time after stop before the LV can be released.
    local HAS_COMPLEX_FEATURES=0
    local conf_check="/etc/pve/nodes/$SRC_NODE/lxc/$SRC_ID.conf"
    if [[ -f "$conf_check" ]] && \
       grep -qE '^features:.*(nesting|fuse|mount)' "$conf_check"; then
        HAS_COMPLEX_FEATURES=1
    fi

    # 1. Stop CT if needed.
    # We ALWAYS stop explicitly (even for migrations) so we control the
    # timing and can wait for kernel-side mount teardown to settle before
    # the migrate copies the volume. PVE's `pct migrate --restart` races
    # past this teardown with CTs that have nesting=1 etc., causing
    # "filesystem in use" errors on lvremove and corrupt mounts on target.
    local was_running=0
    local ct_status
    ct_status=$($SRC_PREFIX pct status "$SRC_ID" 2>/dev/null || true)
    if echo "$ct_status" | grep -q running; then
        was_running=1
        info "Stopping CT $SRC_ID on $SRC_NODE..."
        run "${SRC_PREFIX:+$SRC_PREFIX }pct stop $SRC_ID"
        if [[ $DRY_RUN -eq 0 ]]; then
            # Wait for pct to report stopped
            for _ in {1..30}; do
                ct_status=$($SRC_PREFIX pct status "$SRC_ID" 2>/dev/null || true)
                echo "$ct_status" | grep -q stopped && break
                sleep 1
            done
            # Extra settle time for CTs with nesting/fuse — kernel mount
            # namespaces and lxcfs binds need time to fully release.
            if (( HAS_COMPLEX_FEATURES == 1 )); then
                info "CT has nesting/fuse features — waiting 10s for kernel mount teardown..."
                sleep 10
            else
                # Brief settle for any CT
                sleep 2
            fi
            # Verify the rootfs LV is really not in use before we touch it
            local rootfs_vol="vm-${SRC_ID}-disk-0"
            local lv_open
            lv_open=$($SRC_PREFIX lvs --noheadings -o lv_attr "pve/$rootfs_vol" 2>/dev/null | tr -d ' ')
            # lv_attr position 6: 'o' = open, '-' = not open
            local i=0
            while [[ "${lv_open:5:1}" == "o" ]] && (( i < 15 )); do
                info "  LV $rootfs_vol still marked open — waiting another second..."
                sleep 1
                lv_open=$($SRC_PREFIX lvs --noheadings -o lv_attr "pve/$rootfs_vol" 2>/dev/null | tr -d ' ')
                i=$((i + 1))
            done
        fi
    fi

    # 2a. CLONE PATH (Copy mode — source kept as stopped backup)
    # Two sub-cases:
    #   Case A — user picked a NEW_ID different from SRC_ID:
    #     Clone SRC_ID -> NEW_ID locally on $SRC_NODE.
    #     SRC_ID remains untouched as the backup.
    #     If target differs, migrate NEW_ID to $TGT_NODE.
    #   Case B — user kept the same ID (NEW_ID == SRC_ID) and changed node:
    #     Clone SRC_ID -> BACKUP_ID locally on $SRC_NODE — this becomes the
    #     backup. Then migrate the original SRC_ID to $TGT_NODE.
    #
    # In both cases the clone uses --full 1 (real copy, not linked).
    if (( LEAVE_SOURCE_BEHIND == 1 )); then
        if (( SAME_NODE_CLONE == 1 )); then
            # Case B: clone SRC_ID -> BACKUP_ID on source (becomes backup),
            # then migrate the original SRC_ID to target.
            info "Cloning CT $SRC_ID ${G_ARROW} $BACKUP_ID on $SRC_NODE (backup, full clone)..."
            if ! run "${SRC_PREFIX:+$SRC_PREFIX }pct clone $SRC_ID $BACKUP_ID --full 1"; then
                err "pct clone failed. Source CT $SRC_ID untouched, no backup created."
                return
            fi
            log "Backup clone complete: $BACKUP_ID on $SRC_NODE."

            info "Migrating original CT $SRC_ID from $SRC_NODE to $TGT_NODE..."
            if ! run "${SRC_PREFIX:+$SRC_PREFIX }pct migrate $SRC_ID $TGT_NODE"; then
                err "pct migrate failed for $SRC_ID. Backup $BACKUP_ID exists on $SRC_NODE."
                err "Recovery options:"
                err "  - Keep current state and retry migrate manually:"
                err "      ${SRC_PREFIX:+$SRC_PREFIX }pct migrate $SRC_ID $TGT_NODE"
                err "  - Roll back the backup creation:"
                err "      ${SRC_PREFIX:+$SRC_PREFIX }pct destroy $BACKUP_ID"
                return
            fi

            # Post-migration cleanup for original (same as Move path)
            if [[ $DRY_RUN -eq 0 ]]; then
                info "Verifying source-side cleanup of original $SRC_ID on $SRC_NODE..."
                local src_lv="vm-${SRC_ID}-disk-0"
                local i=0 lv_exists=""
                while (( i < 15 )); do
                    lv_exists=$($SRC_PREFIX lvs --noheadings -o lv_name "pve/$src_lv" 2>/dev/null | tr -d ' ' || true)
                    [[ -z "$lv_exists" ]] && break
                    sleep 1
                    i=$(( i + 1 ))
                done
                if [[ -n "$lv_exists" ]]; then
                    warn "Source LV pve/$src_lv still present after migration — attempting force-remove..."
                    $SRC_PREFIX lvchange -an -f "pve/$src_lv" 2>/dev/null || true
                    sleep 2
                    if $SRC_PREFIX lvremove -f "pve/$src_lv" 2>/dev/null; then
                        log "Source LV force-removed successfully."
                    else
                        err "Could NOT remove source LV pve/$src_lv on $SRC_NODE."
                    fi
                else
                    log "Source LV removed cleanly."
                fi
                $SRC_PREFIX "rm -rf /var/lib/lxc/$SRC_ID" 2>/dev/null || true
            fi

            # In Case B, the resulting (migrated) CT keeps SRC_ID on target.
            # Set MIGRATE_NEEDED=0 so the standard Move block below is skipped;
            # we've handled the migrate already. RENUMBER_NEEDED stays 0 (it
            # was already 0 since NEW_ID == SRC_ID).
            MIGRATE_NEEDED=0
        else
            # Case A: clone SRC_ID -> NEW_ID on source. Source stays as backup.
            info "Cloning CT $SRC_ID ${G_ARROW} $NEW_ID on $SRC_NODE (full clone)..."
            if ! run "${SRC_PREFIX:+$SRC_PREFIX }pct clone $SRC_ID $NEW_ID --full 1"; then
                err "pct clone failed. Source CT $SRC_ID untouched."
                return
            fi
            log "Clone complete: $SRC_ID ${G_ARROW} $NEW_ID on $SRC_NODE."

            # Migrate the clone to target node if needed.
            if (( MIGRATE_NEEDED == 1 )); then
                info "Migrating clone $NEW_ID from $SRC_NODE to $TGT_NODE..."
                if ! run "${SRC_PREFIX:+$SRC_PREFIX }pct migrate $NEW_ID $TGT_NODE"; then
                    err "pct migrate failed for clone $NEW_ID. Clone remains on $SRC_NODE."
                    err "Manual cleanup options:"
                    err "  - To delete the clone: ${SRC_PREFIX:+$SRC_PREFIX }pct destroy $NEW_ID"
                    err "  - To migrate manually: ${SRC_PREFIX:+$SRC_PREFIX }pct migrate $NEW_ID $TGT_NODE"
                    return
                fi

                # Verify clone's source-side cleanup on $SRC_NODE
                if [[ $DRY_RUN -eq 0 ]]; then
                    info "Verifying clone source-side cleanup on $SRC_NODE..."
                    local clone_lv="vm-${NEW_ID}-disk-0"
                    local i=0 lv_exists=""
                    while (( i < 15 )); do
                        lv_exists=$($SRC_PREFIX lvs --noheadings -o lv_name "pve/$clone_lv" 2>/dev/null | tr -d ' ' || true)
                        [[ -z "$lv_exists" ]] && break
                        sleep 1
                        i=$(( i + 1 ))
                    done
                    if [[ -n "$lv_exists" ]]; then
                        warn "Clone source-side LV pve/$clone_lv still present — attempting force-remove..."
                        $SRC_PREFIX lvchange -an -f "pve/$clone_lv" 2>/dev/null || true
                        sleep 2
                        if $SRC_PREFIX lvremove -f "pve/$clone_lv" 2>/dev/null; then
                            log "Clone source-side LV force-removed successfully."
                        else
                            err "Could NOT remove clone source-side LV pve/$clone_lv on $SRC_NODE."
                        fi
                    else
                        log "Clone source-side LV removed cleanly."
                    fi
                    $SRC_PREFIX "rm -rf /var/lib/lxc/$NEW_ID" 2>/dev/null || true
                fi
            fi

            # Case A is done — bypass the standard Move blocks below.
            RENUMBER_NEEDED=0
            MIGRATE_NEEDED=0
        fi
    fi

    # 2b. MOVE PATH — migrate (must run on the source node; CT is now stopped)
    if (( MIGRATE_NEEDED == 1 )); then
        info "Migrating CT $SRC_ID from $SRC_NODE to $TGT_NODE..."
        # Always offline migrate now that we've explicitly stopped + settled.
        # Don't use --restart; we handle start ourselves at the end so we can
        # also do renumber/network changes in between.
        run "${SRC_PREFIX:+$SRC_PREFIX }pct migrate $SRC_ID $TGT_NODE"

        # Post-migration cleanup: verify source-side LV is actually gone.
        # PVE's lvremove can silently fail when complex-feature CTs (nesting=1
        # etc) leave kernel mounts around — the result is a ghost LV that
        # keeps the rootfs accessible despite PVE thinking the CT is gone.
        # We poll for the LV to disappear; if it's still there after a wait,
        # force a deactivate-then-remove.
        if [[ $DRY_RUN -eq 0 ]]; then
            info "Verifying source-side cleanup on $SRC_NODE..."
            local src_lv="vm-${SRC_ID}-disk-0"
            local i=0 lv_exists=""
            while (( i < 15 )); do
                lv_exists=$($SRC_PREFIX lvs --noheadings -o lv_name "pve/$src_lv" 2>/dev/null | tr -d ' ' || true)
                [[ -z "$lv_exists" ]] && break
                sleep 1
                i=$(( i + 1 ))
            done
            if [[ -n "$lv_exists" ]]; then
                warn "Source LV pve/$src_lv still present after migration — attempting force-remove..."
                # Deactivate first (releases kernel-side dm mapping)
                $SRC_PREFIX lvchange -an -f "pve/$src_lv" 2>/dev/null || true
                sleep 2
                if $SRC_PREFIX lvremove -f "pve/$src_lv" 2>/dev/null; then
                    log "Source LV force-removed successfully."
                else
                    err "Could NOT remove source LV pve/$src_lv on $SRC_NODE."
                    err "  Manual cleanup required to prevent ghost CT:"
                    err "    ssh root@$SRC_NODE \"lvchange -an -f pve/$src_lv && lvremove -f pve/$src_lv\""
                fi
            else
                log "Source LV removed cleanly."
            fi

            # Also clean up /var/lib/lxc/<id>/ on source — runtime cache
            # left behind by PVE migrate.
            $SRC_PREFIX "rm -rf /var/lib/lxc/$SRC_ID" 2>/dev/null || true
        fi
    fi

    # SSH prefix for the TARGET node (where the CT lives AFTER migration).
    # Used for LVM rename and post-migration pct commands.
    local REMOTE_PREFIX
    REMOTE_PREFIX=$(ssh_prefix "$TGT_NODE")
    if [[ -n "$REMOTE_PREFIX" ]]; then
        info "CT now lives on $TGT_NODE — subsequent ops via SSH to ${NODE_IP[$TGT_NODE]:-$TGT_NODE}"
    fi

    # 3. Apply hostname / VLAN / IP / MAC
    # Path depends on which mode finished above:
    #   - Move:               config at SRC_ID until step 4 renames it
    #   - Copy / Case A:      config at NEW_ID on target (clone landed there)
    #   - Copy / Case B:      config at SRC_ID on target (original migrated)
    local conf_now
    if (( LEAVE_SOURCE_BEHIND == 1 )) && (( SAME_NODE_CLONE == 0 )); then
        conf_now="/etc/pve/nodes/$TGT_NODE/lxc/$NEW_ID.conf"
    else
        conf_now="/etc/pve/nodes/$TGT_NODE/lxc/$SRC_ID.conf"
    fi
    local NEW_VLAN_FOR_CONFIG=""
    [[ -n "$NEW_VLAN" && "$NEW_VLAN" != "-" ]] && NEW_VLAN_FOR_CONFIG="$NEW_VLAN"
    if (( HOSTNAME_CHANGE == 1 )); then
        info "Applying hostname change..."
        update_hostname_in_config "$conf_now" "$NEW_HOSTNAME"
    fi
    if (( NETWORK_CHANGE == 1 )); then
        info "Applying network changes..."
        update_net0_in_config "$conf_now" "$NEW_IP" "$NEW_VLAN_FOR_CONFIG" "$NEW_MAC"
    fi

    # 4. Renumber (LV rename + config rename)
    local rb_file=""
    if (( RENUMBER_NEEDED == 1 )); then
        info "Detecting CT disks..."
        local DISK_LINES=()
        mapfile -t DISK_LINES < <(grep -E '^(rootfs|mp[0-9]+):' "$conf_now")
        (( ${#DISK_LINES[@]} > 0 )) || die "No disks found in config."

        local RENAME_OPS=()
        for line in "${DISK_LINES[@]}"; do
            local VOL_REF STORAGE VOLNAME VG
            VOL_REF=$(echo "$line" | sed -E 's/^[^:]+: *([^,]+).*/\1/')
            STORAGE="${VOL_REF%%:*}"
            VOLNAME="${VOL_REF#*:}"
            if [[ "$VOLNAME" =~ ^vm-${SRC_ID}-disk-([0-9]+)$ ]]; then
                local NEW_VOLNAME="vm-${NEW_ID}-disk-${BASH_REMATCH[1]}"
                VG=$(grep -A5 "^lvmthin: $STORAGE" /etc/pve/storage.cfg 2>/dev/null \
                    | awk '/vgname/ {print $2; exit}')
                VG="${VG:-pve}"
                RENAME_OPS+=("$STORAGE|$VOLNAME|$NEW_VOLNAME|$VG")
                info "  Will rename: $STORAGE:$VOLNAME ${G_ARROW} $STORAGE:$NEW_VOLNAME"
            else
                warn "  Skipping non-standard volume: $VOL_REF"
            fi
        done

        local ts
        ts=$(date +%Y%m%d-%H%M%S)
        rb_file="$ROLLBACK_DIR/${ts}-renumber-${SRC_ID}-to-${NEW_ID}.sh"
        write_rollback_renumber "$rb_file" "$SRC_ID" "$NEW_ID" "$TGT_NODE" "$SRC_NODE" "${RENAME_OPS[@]}"
        info "Rollback snippet written to: $rb_file"

        for op in "${RENAME_OPS[@]}"; do
            local storage oldvol newvol vg
            IFS='|' read -r storage oldvol newvol vg <<< "$op"
            run "${REMOTE_PREFIX:+$REMOTE_PREFIX }lvrename $vg $oldvol $newvol"
        done
        log "Disk rename complete."

        local NEW_CONF="/etc/pve/nodes/$TGT_NODE/lxc/$NEW_ID.conf"
        if [[ $DRY_RUN -eq 0 ]]; then
            cp "$conf_now" "$NEW_CONF"
            sed -i "s/vm-${SRC_ID}-disk/vm-${NEW_ID}-disk/g" "$NEW_CONF"
            rm "$conf_now"
            log "Config moved: $conf_now ${G_ARROW} $NEW_CONF"
        else
            dry "cp $conf_now $NEW_CONF"
            dry "sed -i ... $NEW_CONF"
            dry "rm $conf_now"
        fi

        # Clean up /var/lib/lxc/<old_id>/ on the target node — this is the
        # runtime config cache. It's regenerated on start, but leaving it
        # around creates orphaned directory trees that look like ghosts.
        if [[ $DRY_RUN -eq 0 ]]; then
            info "Cleaning up runtime cache for old ID $SRC_ID..."
            run "${REMOTE_PREFIX:+$REMOTE_PREFIX }rm -rf /var/lib/lxc/$SRC_ID"
        fi

        # Post-rename verification: mount the new LV read-only and compare
        # its /etc/hostname to what the config says. Catches the failure
        # mode where the LV we renamed contains different content than the
        # config describes (which happened in earlier incident).
        if [[ $DRY_RUN -eq 0 ]]; then
            info "Verifying renamed LV content matches config..."
            local cfg_hostname disk_hostname
            cfg_hostname=$(awk -F': *' '/^hostname:/ {print $2; exit}' "$NEW_CONF" | tr -d '[:space:]')
            disk_hostname=$(lv_sniff_hostname "$TGT_NODE" "vm-${NEW_ID}-disk-0")
            if [[ "$disk_hostname" == "BUSY" ]]; then
                warn "  LV is in use — cannot verify content. Inspect manually after CT start."
            elif [[ -z "$disk_hostname" ]]; then
                warn "  Could not read hostname from LV (mount failed). Inspect manually."
            elif [[ "$disk_hostname" == "$cfg_hostname" ]]; then
                log "  Verified: LV hostname '$disk_hostname' matches config."
            else
                err "  MISMATCH: LV contains hostname '$disk_hostname' but config says '$cfg_hostname'"
                err "  This indicates the wrong LV was renamed. Review before starting CT."
            fi
        fi

        if [[ "${UPDATE_JOBS^^}" == "Y" ]]; then
            info "Updating $JOBS_CFG..."
            if [[ $DRY_RUN -eq 0 ]]; then
                cp "$JOBS_CFG" "${JOBS_CFG}.bak.$(date +%Y%m%d-%H%M%S)"
                sed -i -E "/^[[:space:]]*vmid[[:space:]]+/ { s/\b${SRC_ID}\b/${NEW_ID}/g }" "$JOBS_CFG"
                log "jobs.cfg updated."
            else
                dry "Would replace $SRC_ID ${G_ARROW} $NEW_ID in $JOBS_CFG"
            fi
        fi
    fi

    # The effective CT ID and node going forward
    local FINAL_ID="$NEW_ID"

    # ---- Completion ----
    echo
    printf '\n  %s%s%s%s %s Operation Complete %s%s%s%s\n\n' \
        "$GREEN" "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" \
        "$G_CHECK" \
        "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" "$G_HBAR_HEAVY" "$NC"

    if [[ $DRY_RUN -eq 0 ]]; then
        info "Verifying new config..."
        local final_conf="/etc/pve/nodes/$TGT_NODE/lxc/$FINAL_ID.conf"
        if [[ -f "$final_conf" ]]; then
            head -20 "$final_conf"
        else
            warn "Could not read new config at $final_conf"
        fi
    fi
    echo
    printf "  ${CYAN}%-12s${NC} %s\n" "CT ID:"    "$FINAL_ID"
    printf "  ${CYAN}%-12s${NC} %s\n" "Node:"     "$TGT_NODE"
    if (( LEAVE_SOURCE_BEHIND == 1 )); then
        if (( SAME_NODE_CLONE == 1 )); then
            printf "  ${CYAN}%-12s${NC} %s\n" "Backup:" "CT $BACKUP_ID kept as stopped backup on $SRC_NODE"
        else
            printf "  ${CYAN}%-12s${NC} %s\n" "Backup:" "CT $SRC_ID kept as stopped backup on $SRC_NODE"
        fi
    fi
    [[ -n "$rb_file" ]] && printf "  ${CYAN}%-12s${NC} %s\n" "Rollback:" "$rb_file"
    printf "  ${CYAN}%-12s${NC} %s\n" "Logfile:"  "$LOGFILE"
    echo

    log_file "Operation complete: $SRC_ID -> $FINAL_ID on $TGT_NODE (leave=$LEAVE_SOURCE_BEHIND, same_node_clone=$SAME_NODE_CLONE, backup_id=${BACKUP_ID:-none})"

    # Every successful operation leaves the CT stopped — script explicitly
    # stops, waits, then migrates/renumbers offline. Prompt user to start.
    local NEEDS_START=1

    if [[ $DRY_RUN -eq 0 ]] && (( NEEDS_START == 1 )); then
        local action_verb="Start"
        local pct_cmd="pct start $FINAL_ID"
        # If only network/hostname changed (no renumber, no migrate, no clone)
        # and CT was already running, offer restart instead of start.
        # In Copy mode (LEAVE_SOURCE_BEHIND), the clone is brand new so
        # it must always be Start, never Restart.
        if (( RENUMBER_NEEDED == 0 && MIGRATE_NEEDED == 0 && LEAVE_SOURCE_BEHIND == 0 )) \
           && [[ "$SEL_CT_STATUS" == "running" ]]; then
            action_verb="Restart"
            pct_cmd="pct restart $FINAL_ID"
        fi
        read -rp "  ${action_verb} CT $FINAL_ID now? [y/N]: " START_NOW
        if [[ "${START_NOW,,}" == "y" ]]; then
            info "${action_verb}ing CT $FINAL_ID on $TGT_NODE..."
            local start_prefix
            start_prefix=$(ssh_prefix "$TGT_NODE")
            if ${start_prefix:+$start_prefix }$pct_cmd; then
                log "CT $FINAL_ID ${action_verb,,}ed on $TGT_NODE."
            else
                err "Failed to ${action_verb,,} CT $FINAL_ID on $TGT_NODE"
            fi
        else
            info "CT left stopped. Later:  $pct_cmd  (on $TGT_NODE)"
        fi
    fi
    echo
    discover_cluster
}


# ---------- Main ----------
discover_cluster
egress_probe_all_nodes
preflight_check
top_menu
