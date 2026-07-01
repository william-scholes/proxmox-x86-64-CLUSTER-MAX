#!/usr/bin/env bash
set -euo pipefail

TARGET_MODEL="x86-64-CLUSTER-MAX"
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
NODES=$(pvesh get /nodes --output-format json | jq -r '.[].node')

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