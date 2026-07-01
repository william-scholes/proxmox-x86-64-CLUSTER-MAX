# Proxmox Max Cluster CPU Generator

A dynamic, mathematical CPU profile generator for Proxmox VE clusters.

This script queries every node in a mixed-hardware Proxmox cluster, calculates the absolute maximum overlapping CPU instruction set, filters out bare-metal hypervisor flags, and automatically generates a custom, cluster-safe CPU type for your virtual machines.

## Why does this exist?

If you run a mixed-hardware Proxmox cluster (e.g., older Intel nodes mixed with newer AMD nodes), live migrating VMs requires a common CPU baseline to prevent kernel panics.

While Proxmox provides native QEMU microarchitecture baselines (like `x86-64-v2-AES`), these predefined baselines are strict. They often leave performance on the table by entirely dropping specific hardware flags (like `pclmulqdq` or `avx`) that might actually be fully supported across your specific mix of hardware.

Instead of relying on rigid baselines, this script acts as a dynamic calculator to squeeze every single overlapping instruction out of your specific hardware mix, ensuring maximum performance without sacrificing live migration safety.

## Features

* **Dynamic Node Discovery:** Uses the Proxmox API (`pvesh` and `jq`) to deterministically find all online cluster nodes.
* **Targeted Node Filtering:** Allows targeting specific subsets of nodes (e.g., Intel-only nodes) to maximize instruction sets for specific VM pools.
* **Mathematical Intersection:** Pulls `/proc/cpuinfo` from every host and mathematically intersects the lists down to the lowest common denominator.
* **Native QEMU Allowlist:** Dynamically queries your local `qemu-system-x86_64` binary for supported CPUID flags to ensure it never passes unrecognized instructions to the emulator.
* **KVM Hardware Blocklist:** Automatically filters out raw hardware and power-management flags (such as `acpi` and `est`) using a built-in blocklist to prevent KVM virtualization crashes.
* **Zero-Touch Sync:** Writes directly to the Proxmox Cluster Filesystem (`pmxcfs`), immediately propagating the custom CPU profile to all nodes in the cluster.

---

## Prerequisites

Before running the script, ensure `jq` is installed on the node executing the script, as it does not ship with Proxmox by default.

```bash
apt update && apt install jq -y
```

---

## Setup & Usage

### 1. Command-Line Options & Help

You can view all available command-line options by running the script with the `--help` flag:

```bash
./x86-64-CLUSTER-MAX.sh --help
```

Output:
```text
Proxmox Max Cluster CPU Generator

Usage: ./x86-64-CLUSTER-MAX.sh [options]

Options:
  -n, --nodes <list>   Comma-separated list of specific nodes to query (e.g. node1,node2)
  -m, --model <name>   Custom name for the generated CPU profile (e.g. x86-64-CUSTOM)
                       (Mandatory if -n/--nodes is specified)
  -h, --help           Show this help message

If no options are specified, the script automatically queries all active cluster nodes
and defaults the model name to 'x86-64-CLUSTER-MAX'.
```

### 2. Run the Script

Execute the script on **any single node** in your cluster. (You do not need to run this on every node; the Proxmox cluster filesystem will automatically sync the output).

#### Option A: Intersect All Nodes (Default)
Query all active nodes in the cluster and generate a CPU profile named `x86-64-CLUSTER-MAX`:

```bash
chmod +x x86-64-CLUSTER-MAX.sh
./x86-64-CLUSTER-MAX.sh
```

#### Option B: Intersect Specific Nodes
Query only a subset of cluster nodes (e.g., `proxmox1` and `proxmox2`) and generate a custom-named profile (e.g., `x86-64-INTEL-ONLY`):

```bash
./x86-64-CLUSTER-MAX.sh --nodes proxmox1,proxmox2 --model x86-64-INTEL-ONLY
```

> [!IMPORTANT]
> If you specify specific nodes using `-n` / `--nodes`, you **must** supply a custom CPU model name using `-m` / `--model` to prevent accidentally overwriting the full-cluster default profile.

#### Example Output (All Nodes Mode):

```text
root@proxmox3:~# ./x86-64-CLUSTER-MAX.sh
=== Checking Dependencies ===
✓ All dependencies met.

=== Fetching QEMU Recognized Flags ===
✓ Loaded 407 QEMU-supported flags.

=== Querying Proxmox Cluster Nodes ===
Checking node: proxmox2... Found 113 raw flags.
Checking node: proxmox3... Found 133 raw flags.
Checking node: proxmox1... Found 82 raw flags.

=== Building Absolute Maximum QEMU Profile ===
✓ Intersected down to 81 shared raw flags.
✓ Filtered against QEMU capabilities and KVM hardware blocklist.
✓ Added 45 safe CPU flags to the new profile.

=== Writing Custom Cluster Profile ===
✓ Successfully created custom profile: x86-64-CLUSTER-MAX
root@proxmox3:~#
```

### 3. Apply the Custom CPU to a VM

Once the script successfully runs, the new CPU profile will be available in the Proxmox Web GUI.

1. Navigate to your VM in the Proxmox UI.
2. Go to **Hardware** -> **Processors** -> **Edit**.
3. In the **Type** dropdown, scroll to the bottom (Custom section).
4. Select the custom model name (e.g. **`x86-64-CLUSTER-MAX`** or your custom name).
5. **Completely shut down** (do not just reboot) the guest OS, then start the VM to apply the new hardware profile.

---

## Screenshots

<img width="2554" height="964" alt="image" src="https://github.com/user-attachments/assets/b871e34b-54aa-456e-8810-ca3cf1164c78" />

---

## How It Works Under the Hood

1. **Dependency Check:** Verifies `jq`, `pvesh`, `awk`, `ssh`, and `qemu-system-x86_64` are present.
2. **QEMU Query:** Runs `qemu-system-x86_64 -cpu help` to build a dynamic array of hypervisor-supported instructions.
3. **Node Query & Validation:** Validates selected/discovered hosts against the cluster list, loops through them via internal SSH, and reads `grep -m1 '^flags' /proc/cpuinfo`.
4. **Intersection:** Compares all arrays and deletes any flags that do not exist on 100% of the target nodes.
5. **Filtering:** Passes the surviving flags through the QEMU allowlist and the built-in KVM hardware blocklist.
6. **Configuration:** Appends the highly optimized `+flag;+flag` syntax to `/etc/pve/virtual-guest/cpu-models.conf`, using `qemu64` as the emulation base model.

---

## Disclaimer

This script forcefully overrides native Proxmox virtualization guardrails. While the generated output relies on the actual overlapping instruction sets of your hardware, extreme hardware discrepancies (e.g., migrating between vastly different architectures) may still result in unexpected guest OS behavior. Test live migrations thoroughly before using in a production environment.

> [!NOTE]
> This script was only tested on Proxmox VE cluster version 9.2.3. Your mileage may vary (YMMV) on other versions.

---

## Author

* **William Scholes** - [william-scholes](https://github.com/william-scholes)

