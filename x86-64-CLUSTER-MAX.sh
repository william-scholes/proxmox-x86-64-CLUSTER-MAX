#!/usr/bin/env bash
set -euo pipefail

# Default values
TARGET_MODEL="x86-64-CLUSTER-MAX"
CUSTOM_CPU_DIR="/etc/pve/virtual-guest"
CUSTOM_CPU_FILE="${CUSTOM_CPU_DIR}/cpu-models.conf"
BLOCKLIST=("acpi" "tm" "tm2" "pbe" "dtes64" "monitor" "ds-cpl" "smx" "est" "xtpr" "vnmi" "pdcm" "ht" "dts" "ds" "vme")

# Help function
usage() {
    echo "Proxmox Max Cluster CPU Generator"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -n, --nodes <list>   Comma-separated list of specific nodes to query (e.g. node1,node2)"
    echo "  -m, --model <name>   Custom name for the generated CPU profile (e.g. x86-64-CUSTOM)"
    echo "                       (Mandatory if -n/--nodes is specified)"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "If no options are specified, the script automatically queries all active cluster nodes"
    echo "and defaults the model name to 'x86-64-CLUSTER-MAX'."
    exit 0
}

# Option parsing
NODES_INPUT=""
MODEL_INPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        -n|--nodes)
            if [ -z "${2+x}" ] || [[ "$2" =~ ^- ]]; then
                echo "❌ ERROR: --nodes requires a non-empty argument."
                exit 1
            fi
            NODES_INPUT="$2"
            shift 2
            ;;
        -m|--model)
            if [ -z "${2+x}" ] || [[ "$2" =~ ^- ]]; then
                echo "❌ ERROR: --model requires a non-empty argument."
                exit 1
            fi
            MODEL_INPUT="$2"
            shift 2
            ;;
        *)
            echo "❌ ERROR: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Validation: if -n is specified, then -m is mandatory
if [ -n "$NODES_INPUT" ] && [ -z "$MODEL_INPUT" ]; then
    echo "❌ ERROR: Custom CPU model name (-m/--model) is mandatory when specific nodes (-n/--nodes) are specified."
    exit 1
fi

# Set the target model name
if [ -n "$MODEL_INPUT" ]; then
    TARGET_MODEL="$MODEL_INPUT"
fi

echo "=== Checking Dependencies ==="
DEPENDENCIES=("jq" "pvesh" "awk" "ssh" "qemu-system-x86_64")
for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ CRITICAL: Required command '$cmd' is not installed."
        exit 1
    fi
done
echo "✓ All dependencies met."
echo ""

echo "=== Fetching QEMU Recognized Flags ==="
declare -A QEMU_ALLOWED_FLAGS

QEMU_RAW=$(qemu-system-x86_64 -cpu help | sed -n '/Recognized CPUID flags:/,/^$/p' | tail -n +2 | tr -s '[:space:]' '\n' | sed '/^$/d')

if [ -z "$QEMU_RAW" ]; then
    echo "❌ CRITICAL: Could not parse QEMU recognized flags. Aborting."
    exit 1
fi

for flag in $QEMU_RAW; do
    QEMU_ALLOWED_FLAGS["$flag"]=1
done
echo "✓ Loaded ${#QEMU_ALLOWED_FLAGS[@]} QEMU-supported flags."
echo ""

echo "=== Querying Proxmox Cluster Nodes ==="
ALL_CLUSTER_NODES=$(pvesh get /nodes --output-format json | jq -r '.[].node')

if [ -z "$ALL_CLUSTER_NODES" ]; then
    echo "❌ CRITICAL: No cluster nodes found or pvesh failed."
    exit 1
fi

declare -A VALID_NODES
for node in $ALL_CLUSTER_NODES; do
    VALID_NODES["$node"]=1
done

NODES_TO_CHECK=""
IS_EXPLICIT_SELECTION=false

if [ -n "$NODES_INPUT" ]; then
    IS_EXPLICIT_SELECTION=true
    IFS=',' read -ra ADDR <<< "$NODES_INPUT"
    for node in "${ADDR[@]}"; do
        node=$(echo "$node" | tr -d '[:space:]')
        if [ -z "$node" ]; then
            continue
        fi
        if [ -z "${VALID_NODES[$node]+x}" ]; then
            echo "❌ CRITICAL: Node '$node' is not a member of this Proxmox cluster."
            exit 1
        fi
        NODES_TO_CHECK="$NODES_TO_CHECK $node"
    done
else
    NODES_TO_CHECK="$ALL_CLUSTER_NODES"
fi

NODES_TO_CHECK=$(echo "$NODES_TO_CHECK" | sed 's/^[ \t]*//;s/[ \t]*$//')

if [ -z "$NODES_TO_CHECK" ]; then
    echo "❌ CRITICAL: No nodes specified or resolved."
    exit 1
fi

INITIAL_NODE=true
declare -A COMMON_FLAGS

for NODE in $NODES_TO_CHECK; do
    echo -n "Checking node: $NODE... "
    
    NODE_FLAGS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$NODE" "grep -m1 '^flags' /proc/cpuinfo" 2>/dev/null | \
                 sed 's/.*: //' | \
                 tr '_' '-' ) || true
                 
    if [ -z "$NODE_FLAGS" ]; then
        if [ "$IS_EXPLICIT_SELECTION" = true ]; then
            echo "❌ FAILED!"
            echo "❌ CRITICAL: Could not fetch CPU flags from explicitly requested node '$NODE'."
            exit 1
        else
            echo "WARNING: Could not fetch CPU flags. Skipping node."
            continue
        fi
    fi

    FLAG_COUNT=$(echo "$NODE_FLAGS" | wc -w)
    echo "Found $FLAG_COUNT raw flags."

    if [ "$INITIAL_NODE" = true ]; then
        for FLAG in $NODE_FLAGS; do
            COMMON_FLAGS["$FLAG"]=1
        done
        INITIAL_NODE=false
    else
        unset CURRENT_NODE_FLAGS
        declare -A CURRENT_NODE_FLAGS
        for FLAG in $NODE_FLAGS; do
            CURRENT_NODE_FLAGS["$FLAG"]=1
        done
        
        for FLAG in "${!COMMON_FLAGS[@]}"; do
            if [ -z "${CURRENT_NODE_FLAGS[$FLAG]+x}" ]; then
                unset COMMON_FLAGS["$FLAG"]
            fi
        done
    fi
done

echo ""
echo "=== Building Absolute Maximum QEMU Profile ==="
CONFIG_FLAGS=""
ADDED_COUNT=0

MAPFILE_SORTED=($(for key in "${!COMMON_FLAGS[@]}"; do echo "$key"; done | sort))

for FLAG in "${MAPFILE_SORTED[@]}"; do
    # 1. Check if QEMU supports it
    if [ -n "${QEMU_ALLOWED_FLAGS[$FLAG]+x}" ]; then
        
        # 2. Check if it is on the KVM blocklist
        IS_BLOCKED=false
        for BLOCKED in "${BLOCKLIST[@]}"; do
            if [ "$FLAG" == "$BLOCKED" ]; then
                IS_BLOCKED=true
                break
            fi
        done
        
        # 3. Add to config if it passes both checks
        if [ "$IS_BLOCKED" = false ]; then
            CONFIG_FLAGS="${CONFIG_FLAGS}+${FLAG};"
            ADDED_COUNT=$((ADDED_COUNT + 1))
        fi
    fi
done

if [ -z "$CONFIG_FLAGS" ]; then
    echo "❌ CRITICAL: No matching QEMU-compatible flags found. Aborting."
    exit 1
fi

CONFIG_FLAGS=${CONFIG_FLAGS%;}

echo "✓ Intersected down to ${#COMMON_FLAGS[@]} shared raw flags."
echo "✓ Filtered against QEMU capabilities and KVM hardware blocklist."
echo "✓ Added $ADDED_COUNT safe CPU flags to the new profile."
echo ""

echo "=== Writing Custom Cluster Profile ==="
mkdir -p "$CUSTOM_CPU_DIR"
touch "$CUSTOM_CPU_FILE"

if grep -q "^cpu-model: ${TARGET_MODEL}$" "$CUSTOM_CPU_FILE"; then
    echo "Profile ${TARGET_MODEL} already exists. Updating entry..."
    cp "$CUSTOM_CPU_FILE" "${CUSTOM_CPU_FILE}.bak"
    
    TMP_FILE=$(mktemp)
    awk -v target="cpu-model: ${TARGET_MODEL}" '
        $0 == target { skip=1; next }
        skip && /^[ \t]/ { next }
        skip && /^[^ \t]/ { skip=0 }
        !skip { print }
    ' "$CUSTOM_CPU_FILE" > "$TMP_FILE"
    
    cat "$TMP_FILE" > "$CUSTOM_CPU_FILE"
    rm "$TMP_FILE"
fi

cat << EOF >> "$CUSTOM_CPU_FILE"
cpu-model: ${TARGET_MODEL}
    flags ${CONFIG_FLAGS}
    reported-model qemu64
    hv-vendor-id QEMU
EOF

echo "✓ Successfully created custom profile: ${TARGET_MODEL}"