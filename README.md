# home-prod

Home automation Kubernetes cluster on Proxmox with GPU passthrough, NFS storage, and automatic DNS.

## What's Included

- **3-node Kubernetes cluster** on Proxmox VMs (1 control plane, 2 workers) provisioned via cloud-init
- **GPU passthrough** with NVIDIA container runtime support (optional)
- **NFS persistent storage** on the Proxmox host, provisioned dynamically via CSI driver
- **Automatic DNS** via external-dns + Cloudflare
- **Home Assistant** with NFS-backed config and Ingress routing

## Architecture

```
Proxmox Host
├── NFS server (/mnt/nfs/k3s)
├── VM: control-1 ── control plane + Traefik ingress
├── VM: data-1    ── worker + GPU (optional)
└── VM: data-2    ── worker

Kubernetes Cluster
├── NFS CSI driver       ── dynamic persistent volumes
├── external-dns         ── auto-syncs Ingress hostnames to Cloudflare DNS
├── NVIDIA device plugin ── exposes GPU to pods (optional)
└── Home Assistant       ── ha.<domain>, config persisted on NFS
```

VM hostnames are registered automatically via DHCP DNS, so the cluster uses hostnames instead of hardcoded IPs. external-dns keeps Cloudflare DNS records in sync with the cluster's current IPs.

## Project Structure

```
.
├── cluster.sh                      # Cluster lifecycle management (runs on Proxmox host)
├── config.env.example              # Cluster config template
├── cloud-init/
│   ├── k3s-control-plane.yaml      # Control plane provisioning
│   ├── k3s-data-plane.yaml         # Worker node provisioning
│   └── k3s-data-plane-gpu.yaml     # GPU worker node provisioning
├── helm/
│   ├── Chart.yaml                  # Helm chart with dependencies
│   ├── values.yaml                 # Default values
│   ├── values-secret.yaml.example  # User-specific config template
│   └── templates/
│       ├── cloudflare-secret.yaml
│       ├── home-assistant.yaml
│       ├── nfs-storage-class.yaml
│       └── nvidia-device-plugin.yaml
```

## Prerequisites

- A Kubernetes cluster with kubectl access — if you don't have one, see [Host Setup](#host-setup) below
- An NFS server accessible from your cluster nodes
- Cloudflare account with a domain
- A router that registers VM hostnames via DHCP (e.g., UniFi)
- Helm 3

## Deploy

### 1. Configure

```bash
cp helm/values-secret.yaml.example helm/values-secret.yaml
```

Edit `helm/values-secret.yaml`:

| Key | Description | Example |
|-----|-------------|---------|
| `domain` | Base domain for your apps | `home.example.com` |
| `nfs.server` | NFS server hostname or IP | `pve` |
| `cloudflare.apiToken` | [Cloudflare API token](https://dash.cloudflare.com/profile/api-tokens) with Edit Zone DNS permission | |
| `external-dns.domainFilters` | Your Cloudflare zone | `[example.com]` |
| `homeAssistant.timezone` | Your timezone | `America/Los_Angeles` |
| `gpu.enabled` | Enable NVIDIA GPU support | `true` / `false` |

### 2. Install

```bash
cd helm
helm dependency update
helm install home-prod . -f values-secret.yaml
```

Home Assistant will be available at `http://ha.<your-domain>` once DNS propagates (may take a few minutes).

### 3. Upgrade

After changing values or templates:

```bash
cd helm
helm upgrade home-prod . -f values-secret.yaml
```

### GPU Support

Disabled by default. To enable, set `gpu.enabled: true` in your `values-secret.yaml`. The NVIDIA device plugin only runs on nodes labeled `nvidia.com/gpu=true` (set automatically by the cloud-init script on GPU nodes).

Verify:
```bash
kubectl describe node <gpu-node> | grep nvidia.com/gpu
# Should show nvidia.com/gpu: 1 under Allocatable
```

---

## Host Setup

This section covers setting up a K3s cluster on Proxmox from scratch. K3s is a lightweight Kubernetes distribution that's well-suited for home use — it bundles Traefik ingress, CoreDNS, and a local storage provider out of the box with minimal resource overhead. Skip this if you already have a Kubernetes cluster.

### NFS Storage

Create a dedicated volume for persistent storage that survives VM rebuilds.

**1. Create and mount a volume**

```bash
lvcreate -V 256G -T pve/data -n nfs    # adjust size as needed
mkfs.ext4 /dev/pve/nfs
mkdir -p /mnt/nfs
mount /dev/pve/nfs /mnt/nfs
```

Add to `/etc/fstab` so it persists across reboots:
```
/dev/pve/nfs /mnt/nfs ext4 defaults 0 2
```

**2. Install and configure NFS server**

```bash
apt install -y nfs-kernel-server
mkdir -p /mnt/nfs/k3s
chown nobody:nogroup /mnt/nfs/k3s
```

Add to `/etc/exports` (adjust the subnet to match your network):
```
/mnt/nfs/k3s <your-subnet>(rw,sync,no_subtree_check,no_root_squash)
```

Apply:
```bash
exportfs -ra
systemctl restart nfs-kernel-server
```

### GPU Passthrough (Optional)

Skip this section if you don't have a GPU.

**1. Enable IOMMU**

Edit `/etc/default/grub` and add IOMMU flags to `GRUB_CMDLINE_LINUX_DEFAULT`:
- AMD: `quiet amd_iommu=on iommu=pt`
- Intel: `quiet intel_iommu=on iommu=pt`

Then run `update-grub`.

**2. Load VFIO modules**

Create `/etc/modules-load.d/vfio.conf`:
```
vfio
vfio_iommu_type1
vfio_pci
```

**3. Blacklist GPU drivers on host**

Create `/etc/modprobe.d/blacklist.conf`:
```
blacklist nouveau
blacklist nvidia
```

**4. Bind GPU to VFIO**

Find your GPU's vendor:device IDs with `lspci -nn`, then create `/etc/modprobe.d/vfio.conf`:
```
options vfio-pci ids=<gpu-id>,<audio-id>
```

**5. Apply and reboot**

```bash
update-initramfs -u -k all
reboot
```

Verify after reboot: `lspci -nnk -s <pci-slot> | grep -i driver` should show `vfio-pci`.

**6. Create GPU resource mapping**

In the Proxmox UI: Datacenter > Resource Mappings > Add PCI Device. Use the mapping name as `GPU_MAPPING` in `config.env`.

### SSH Keys

Prepare SSH keys so you can access VMs from both the Proxmox host and your workstation.

```bash
# On the Proxmox host, combine keys into a single file
cat ~/.ssh/id_rsa.pub > /tmp/keys.pub
```

Append your workstation's public key to the same file:
```bash
echo "<your-workstation-public-key>" >> /tmp/keys.pub
```

Use this path as `SSH_KEYS` in `config.env`.

### Enable Snippets

In the Proxmox UI: Datacenter > Storage > local > Edit > Content > add **Snippets**. This allows cloud-init files to be stored on the host.

### Deploy the Cluster

```bash
cp config.env.example config.env
```

Edit `config.env`:

| Key | Description | Example |
|-----|-------------|---------|
| `K3S_TOKEN` | Shared secret for K3s nodes to join | Any random string |
| `GPU_MAPPING` | Proxmox GPU resource mapping name | `rtx3090` |
| `NFS_SERVER` | NFS server hostname | `pve` |
| `CONTROL_PLANE_HOST` | Control plane VM hostname | `control-1` |
| `SSH_KEYS` | Path to SSH public keys file | `/tmp/keys.pub` |

```bash
# Create VM template and start cluster
./cluster.sh template-create
./cluster.sh start

# Verify (wait a few minutes for cloud-init to finish)
./cluster.sh status
```

> **Note:** The GPU worker node reboots automatically after cloud-init finishes to load the NVIDIA kernel module. This is expected — it rejoins the cluster after ~1 minute.

### Set Up kubectl

From your workstation:

```bash
ssh ubuntu@<control-plane-host> "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/<control-plane-host>/" > ~/.kube/config
```

### Cluster Management

```bash
./cluster.sh start              # Create and start all VMs
./cluster.sh clean              # Stop and destroy all VMs
./cluster.sh restart            # Rebuild entire cluster
./cluster.sh restart 201        # Rebuild a single node
./cluster.sh status             # Check node status
./cluster.sh template-create    # Create VM template
./cluster.sh template-clean     # Destroy VM template
```
