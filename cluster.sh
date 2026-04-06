#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load user config
if [[ ! -f "$SCRIPT_DIR/config.env" ]]; then
    echo "Missing config.env. Copy config.env.example to config.env and fill in your values."
    exit 1
fi
source "$SCRIPT_DIR/config.env"

TEMPLATE=9000
SNIPPET_DIR="/var/lib/vz/snippets"
CLOUD_IMAGE="noble-server-cloudimg-amd64.img"
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/$CLOUD_IMAGE"

VM_IDS=(101 201 202)

declare -A VM_CONFIG=(
    [101]="--cicustom vendor=local:snippets/k3s-control-plane.yaml"
    [201]="--cpu host --cores 8 --memory 8192 --hostpci0 mapping=$GPU_MAPPING,pcie=1 --cicustom vendor=local:snippets/k3s-data-plane-gpu.yaml"
    [202]="--cpu host --cores 8 --memory 8192 --cicustom vendor=local:snippets/k3s-data-plane.yaml"
)
declare -A VM_NAME=(
    [101]="control-1"
    [201]="data-1"
    [202]="data-2"
)
declare -A VM_DISK=(
    [101]="32G"
    [201]="256G"
    [202]="256G"
)

template_create() {
    echo "=== Creating VM template ($TEMPLATE) ==="
    if qm status $TEMPLATE &>/dev/null; then
        echo "Template $TEMPLATE already exists. Run '$0 template-clean' first."
        exit 1
    fi
    if [[ ! -f "$SCRIPT_DIR/$CLOUD_IMAGE" ]]; then
        echo "Downloading cloud image..."
        wget -P "$SCRIPT_DIR" "$CLOUD_IMAGE_URL"
    fi
    qm create $TEMPLATE --name ubuntu-template --memory 2048 --cores 2 \
        --net0 virtio,bridge=vmbr0 --machine q35 --bios ovmf \
        --efidisk0 local-lvm:0 --scsihw virtio-scsi-pci
    qm set $TEMPLATE --scsi0 local-lvm:0,import-from="$SCRIPT_DIR/$CLOUD_IMAGE"
    qm set $TEMPLATE --ide2 local-lvm:cloudinit --boot order=scsi0 --agent enabled=1
    qm set $TEMPLATE --sshkeys "$SSH_KEYS" --ciuser ubuntu --cipassword password --ipconfig0 ip=dhcp
    qm resize $TEMPLATE scsi0 32G
    qm template $TEMPLATE
    echo "=== Template $TEMPLATE created ==="
}

template_clean() {
    echo "=== Destroying template ($TEMPLATE) ==="
    set +e
    qm destroy $TEMPLATE --purge 2>/dev/null
    set -e
    echo "Done"
}

clean_node() {
    local id=$1
    set +e
    qm stop $id 2>/dev/null
    qm destroy $id --purge 2>/dev/null
    set -e
}

start_node() {
    local id=$1
    echo "=== Creating ${VM_NAME[$id]} (VM $id) ==="
    qm clone $TEMPLATE $id --name ${VM_NAME[$id]} --full
    qm set $id ${VM_CONFIG[$id]}
    qm resize $id scsi0 ${VM_DISK[$id]}
    qm start $id
}

clean() {
    echo "=== Cleaning VMs ==="
    for id in "${VM_IDS[@]}"; do
        clean_node $id
    done
    echo "Done"
}

copy_snippets() {
    echo "=== Copying snippets ==="
    for f in "$SCRIPT_DIR"/cloud-init/*.yaml; do
        sed -e "s|\${K3S_TOKEN}|$K3S_TOKEN|g" \
            -e "s|\${CONTROL_PLANE_HOST}|$CONTROL_PLANE_HOST|g" \
            "$f" > "$SNIPPET_DIR/$(basename "$f")"
    done
}

start() {
    copy_snippets

    for id in "${VM_IDS[@]}"; do
        start_node $id
    done
    echo "=== Done. Check status: ./cluster.sh status ==="
}

restart() {
    local id=$1
    copy_snippets

    if [[ -n "$id" ]]; then
        if [[ -z "${VM_NAME[$id]}" ]]; then
            echo "Unknown VM ID: $id. Valid IDs: 101, 201, 202"
            exit 1
        fi
        clean_node $id
        start_node $id
    else
        clean
        template_clean
        template_create
        for id in "${VM_IDS[@]}"; do
            start_node $id
        done
    fi
    echo "=== Done ==="
}

status() {
    ssh ubuntu@$CONTROL_PLANE_HOST sudo kubectl get nodes
}

case "${1:-}" in
    template-create) template_create ;;
    template-clean)  template_clean ;;
    clean)           clean ;;
    start)           start ;;
    restart)         restart "$2" ;;
    status)          status ;;
    *) echo "Usage: $0 {template-create|template-clean|clean|start|restart [vmid]|status}" ;;
esac
