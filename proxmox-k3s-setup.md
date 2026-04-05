# Proxmox K3s Setup Guide

## Hardware
- CPU: AMD Ryzen 5900X, Motherboard: ASUS B550-I
- NVMe 1 (nvme1n1): Proxmox OS, NVMe 2 (nvme0n1): added to pve VG
- GPU: NVIDIA RTX 3090 (PCI 08:00.0, IDs: 10de:2204, 10de:1aef)

## 1. Storage — Extend LVM with second NVMe
```bash
wipefs -a /dev/nvme0n1
pvcreate /dev/nvme0n1
vgextend pve /dev/nvme0n1
lvextend -l +100%FREE pve/data
```

## 2. GPU Passthrough
```bash
# GRUB
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"/' /etc/default/grub
update-grub

# VFIO modules
echo -e 'vfio\nvfio_iommu_type1\nvfio_pci' > /etc/modules-load.d/vfio.conf

# Blacklist Nvidia on host
echo -e 'blacklist nouveau\nblacklist nvidia' > /etc/modprobe.d/blacklist.conf

# Bind GPU to VFIO
echo 'options vfio-pci ids=10de:2204,10de:1aef' > /etc/modprobe.d/vfio.conf

# Apply and reboot
update-initramfs -u -k all
reboot
```

Verify after reboot:
```bash
dmesg | grep -i -e iommu -e AMD-Vi
lspci -nnk -s 08:00 | grep -i driver  # should show vfio-pci
```

Create GPU resource mapping in Proxmox UI:
Datacenter > Resource Mappings > Add PCI Device > name: `rtx3090`, device: `08:00.0`, check "All Functions"

## 3. Cloud-Init Template

### Prepare SSH keys
```bash
ssh-keygen -t rsa -b 4096  # if needed
cat ~/.ssh/id_rsa.pub > /tmp/keys.pub
echo "YOUR_PC_PUBLIC_KEY" >> /tmp/keys.pub
```

### All snippets use a shared pre-defined K3s token. Before copying, replace `my-secret-token` in all 3 yaml files with your own secret value.

Copy cloud-init snippets to Proxmox host. Enable Snippets: Datacenter > Storage > local > Edit > Content > add Snippets
```bash
mkdir -p /var/lib/vz/snippets
cp k3s-control-plane.yaml k3s-data-plane.yaml k3s-data-plane-gpu.yaml /var/lib/vz/snippets/
```

### Create template
```bash
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qm create 9000 --name ubuntu-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0 --machine q35 --bios ovmf --efidisk0 local-lvm:0 --scsihw virtio-scsi-pci
qm set 9000 --scsi0 local-lvm:0,import-from=/root/noble-server-cloudimg-amd64.img
qm set 9000 --ide2 local-lvm:cloudinit --boot order=scsi0 --agent enabled=1
qm set 9000 --sshkeys /tmp/keys.pub --ciuser ubuntu --cipassword password --ipconfig0 ip=dhcp
qm resize 9000 scsi0 32G
qm template 9000
```

## 4. Deploy Cluster

Use `cluster.sh` on the Proxmox host:
```bash
./cluster.sh start    # create and start all VMs
./cluster.sh clean    # stop and destroy all VMs
./cluster.sh restart  # clean + start
./cluster.sh status   # check cluster nodes
```

Hostname resolution uses DHCP DNS (UniFi Dream Machine Pro registers VM hostnames automatically). Workers find the control plane via `control-1` hostname — no hardcoded IPs needed.

## 5. Verify
```bash
ssh ubuntu@control-1 sudo kubectl get nodes
# All 3 nodes should show Ready
```

## 6. GPU for Kubernetes
```bash
sudo kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
sudo kubectl describe node data-1 | grep nvidia
```
