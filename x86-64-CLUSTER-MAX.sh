#!/usr/bin/env bash
set -euo pipefail

TARGET_MODEL="x86-64-CLUSTER-MAX"
MODEL_PROVIDED=false
SPECIFIC_NODES=""

# Parse command line arguments
while getopts "m:n:" opt; do
    case ${opt} in
        m)
            TARGET_MODEL=$OPTARG
            MODEL_PROVIDED=true
            ;;
        n)
            SPECIFIC_NODES=$OPTARG
            ;;
        \?)
            echo "Usage: $0 [-m custom_model_name] [-n node1,node2]"
            exit 1
            ;;
    esac
done

if [ -n "$SPECIFIC_NODES" ] && [ "$MODEL_PROVIDED" = false ]; then
    echo "❌ ERROR: Custom CPU model name (-m) is mandatory when specific nodes (-n) are specified."
    exit 1
fi

# Validate the custom CPU model name against Proxmox's strict syntax rules
if [[ ! "$TARGET_MODEL" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "❌ ERROR: Model name '$TARGET_MODEL' contains invalid characters."
    echo "   Proxmox strictly requires letters, numbers, dashes (-), and underscores (_)."
    echo "   Please remove spaces, plus signs (+), or special characters and try again."
    exit 1
fi

CUSTOM_CPU_DIR="/etc/pve/virtual-guest"
CUSTOM_CPU_FILE="${CUSTOM_CPU_DIR}/cpu-models.conf"

# Explicitly block physical hardware/power-management flags that KVM refuses to virtualize
BLOCKLIST=("acpi" "tm" "tm2" "pbe" "dtes64" "monitor" "ds-cpl" "smx" "est" "xtpr" "vnmi" "pdcm" "ht" "dts" "ds" "vme")

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
if [ -n "$SPECIFIC_NODES" ]; then
    # Convert comma-separated input into space-separated string for loop
    NODES=$(echo "$SPECIFIC_NODES" | tr ',' ' ')
else
    # Fetch all cluster nodes automatically
    NODES=$(pvesh get /nodes --output-format json | jq -r '.[].node')
fi

if [ -z "$NODES" ]; then
    echo "ERROR: No cluster nodes found or pvesh failed."
    exit 1
fi

INITIAL_NODE=true
declare -A COMMON_FLAGS

for NODE in $NODES; do
    echo -n "Checking node: $NODE... "
    
    NODE_FLAGS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$NODE" "grep -m1 '^flags' /proc/cpuinfo" 2>/dev/null | \
                 sed 's/.*: //' | \
                 tr '_' '-' ) || true
                 
    if [ -z "$NODE_FLAGS" ]; then
        echo "WARNING: Could not fetch CPU flags."
        continue
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
    if [ -n "${QEMU_ALLOWED_FLAGS[$FLAG]+x}" ]; then
        
        IS_BLOCKED=false
        for BLOCKED in "${BLOCKLIST[@]}"; do
            if [ "$FLAG" == "$BLOCKED" ]; then
                IS_BLOCKED=true
                break
            fi
        done
        
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

# Create a safe backup before writing any changes
cp "$CUSTOM_CPU_FILE" "${CUSTOM_CPU_FILE}.bak"
echo "✓ Pre-modification backup created at: ${CUSTOM_CPU_FILE}.bak"

if grep -q "^cpu-model: ${TARGET_MODEL}$" "$CUSTOM_CPU_FILE"; then
    echo "Profile ${TARGET_MODEL} already exists in config. Updating entry..."
    
    TMP_FILE=$(mktemp)
    awk -v target="cpu-model: ${TARGET_MODEL}" '
        $0 == target { skip=1; next }
        skip && /^[ \t]/ { next }
        skip && /^[^ \t]/ { skip=0 }
        !skip { print }
    ' "$CUSTOM_CPU_FILE" > "$TMP_FILE"
    
    # Clean up excess empty lines to keep the file neat
    awk 'NF > 0 {blank=0} NF == 0 {blank++} blank < 2' "$TMP_FILE" > "$CUSTOM_CPU_FILE"
    rm "$TMP_FILE"
fi

echo "✓ Appending configuration to: ${CUSTOM_CPU_FILE}"
# Append the new profile with strict Proxmox GUI formatting
# \n ensures the mandatory blank line separation
# \t ensures exact tab indentation instead of spaces
{
    echo -e "\ncpu-model: ${TARGET_MODEL}"
    echo -e "\thv-vendor-id QEMU"
    echo -e "\treported-model qemu64"
    echo -e "\tflags ${CONFIG_FLAGS}"
} >> "$CUSTOM_CPU_FILE"

echo "✓ Successfully created custom profile: ${TARGET_MODEL}"
echo "This model will sync cluster-wide immediately via pmxcfs."
