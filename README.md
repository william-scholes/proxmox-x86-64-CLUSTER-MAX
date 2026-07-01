Here is a complete, well-structured `README.md` ready to be dropped into your GitHub repository. It explains the exact problem the script solves, why existing tools don't quite cut it, and provides clear, step-by-step instructions for anyone else running a mixed-hardware Proxmox cluster.



\---



\# Proxmox Max Cluster CPU Generator



A dynamic, mathematical CPU profile generator for Proxmox VE clusters.



This script queries every node in a mixed-hardware Proxmox cluster, calculates the absolute maximum overlapping CPU instruction set, filters out bare-metal hypervisor flags, and automatically generates a custom, cluster-safe CPU type for your virtual machines.



\## Why does this exist?



If you run a mixed-hardware Proxmox cluster (e.g., older Intel nodes mixed with newer AMD nodes), live migrating VMs requires a common CPU baseline to prevent kernel panics.



While Proxmox provides native QEMU microarchitecture baselines (like `x86-64-v2-AES`), these predefined baselines are strict. They often leave performance on the table by entirely dropping specific hardware flags (like `pclmulqdq` or `avx`) that might actually be fully supported across your specific mix of hardware.



Instead of relying on rigid baselines, this script acts as a dynamic calculator to squeeze every single overlapping instruction out of your specific hardware mix, ensuring maximum performance without sacrificing live migration safety.



\## Features



\* \*\*Dynamic Node Discovery:\*\* Uses the Proxmox API (`pvesh` and `jq`) to deterministically find all online cluster nodes.

\* \*\*Mathematical Intersection:\*\* Pulls `/proc/cpuinfo` from every host and mathematically intersects the lists down to the lowest common denominator.

\* \*\*Native QEMU Allowlist:\*\* Dynamically queries your local `qemu-system-x86\_64` binary for supported CPUID flags to ensure it never passes unrecognized instructions to the emulator.

\* \*\*KVM Hardware Blocklist:\*\* Reads from a customizable blocklist to strip out bare-metal power-management flags (like `acpi` and `est`) that crash KVM.

\* \*\*Zero-Touch Sync:\*\* Writes directly to the Proxmox Cluster Filesystem (`pmxcfs`), immediately propagating the custom CPU profile to all nodes in the cluster.



\---



\## Prerequisites



Before running the script, ensure `jq` is installed on the node executing the script, as it does not ship with Proxmox by default.



```bash

apt update \&\& apt install jq -y



```



\---



\## Setup \& Usage



\### 1. Create the KVM Blocklist



KVM refuses to virtualize physical hardware and power-management states. You must define a blocklist so the script knows which raw kernel flags to strip out before handing the profile to QEMU/KVM.



Create the configuration file:



```bash

mkdir -p /etc/pve/virtual-guest

nano /etc/pve/virtual-guest/kvm-blocklist.conf



```



Paste the following known physical flags into the file (one per line):



```text

acpi

tm

tm2

pbe

dtes64

monitor

ds-cpl

smx

est

xtpr

vnmi

pdcm

ht

dts

ds

vme



```



\*Save and exit.\*



\### 2. Run the Script



Execute the script on \*\*any single node\*\* in your cluster. (You do not need to run this on every node; the Proxmox cluster filesystem will automatically sync the output).



```bash

chmod +x cluster-cpu-query.sh

./cluster-cpu-query.sh



```



\### 3. Apply the Custom CPU to a VM



Once the script successfully runs, the new CPU profile will be available in the Proxmox Web GUI.



1\. Navigate to your VM in the Proxmox UI.

2\. Go to \*\*Hardware\*\* -> \*\*Processors\*\* -> \*\*Edit\*\*.

3\. In the \*\*Type\*\* dropdown, scroll to the bottom (Custom section).

4\. Select \*\*`x86-64-CLUSTER-MAX`\*\*.

5\. \*\*Completely shut down\*\* (do not just reboot) the guest OS, then start the VM to apply the new hardware profile.



\---



\## How It Works Under the Hood



1\. \*\*Dependency Check:\*\* Verifies `jq`, `pvesh`, `awk`, `ssh`, and `qemu-system-x86\_64` are present.

2\. \*\*QEMU Query:\*\* Runs `qemu-system-x86\_64 -cpu help` to build a dynamic array of hypervisor-supported instructions.

3\. \*\*Node Query:\*\* Loops through all online nodes via internal SSH and reads `grep -m1 '^flags' /proc/cpuinfo`.

4\. \*\*Intersection:\*\* Compares all arrays and deletes any flags that do not exist on 100% of the active nodes.

5\. \*\*Filtering:\*\* Passes the surviving flags through the QEMU allowlist and the KVM `kvm-blocklist.conf` file.

6\. \*\*Configuration:\*\* Appends the highly optimized `+flag;+flag` syntax to `/etc/pve/virtual-guest/cpu-models.conf`, using `qemu64` as the emulation base model.



\## Disclaimer



This script forcefully overrides native Proxmox virtualization guardrails. While the generated output relies on the actual overlapping instruction sets of your hardware, extreme hardware discrepancies (e.g., migrating between vastly different architectures) may still result in unexpected guest OS behavior. Test live migrations thoroughly before using in a production environment.

