#!/bin/bash
# Improved script to automate Docker installation (via apt on Ubuntu by default, with Snap option), IP change to 10.20.0.0/16, verification, and cleanup
# Run with sudo: sudo ./script.sh
# Changes: Updated Docker apt installation to modern method (no apt-key), install jq if missing, remove fixed-cidr if present, cleanup test container before creation, prune networks before restart, add sudo check, default to apt install if none detected.

set -eu # Exit on error or unset variables

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "✗ This script must be run as root (use sudo)."
    exit 1
fi

# Configuration
SUBNET="10.20.0.0/16"
BIP="10.20.1.1/24" # Safer: Small /24 for bridge, outside main pools to avoid overlap
SIZE=24
TEST_CONTAINER_NAME="temp-ip-test"

echo "========================================="
echo "Docker Install, IP Change, Verify, and Cleanup Script"
echo "Target IP range: $SUBNET (pools), BIP: $BIP"
echo "========================================="

# Function to detect installation type
DOCKER_TYPE=""
DOCKER_CONFIG_PATH=""
RESTART_CMD=""
VERIFY_CMD=""
detect_docker_type() {
    if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
        DOCKER_TYPE="snap"
        DOCKER_CONFIG_PATH="/var/snap/docker/current/config/daemon.json"
        RESTART_CMD="snap restart docker"
        VERIFY_CMD="snap services docker | grep -q 'docker.dockerd.*active'"
        echo "✓ Detected Snap Docker."
    elif command -v docker >/dev/null 2>&1; then
        DOCKER_TYPE="apt"
        DOCKER_CONFIG_PATH="/etc/docker/daemon.json"
        RESTART_CMD="systemctl restart docker"
        VERIFY_CMD="systemctl is-active docker"
        echo "✓ Detected apt-based Docker."
    else
        echo "✗ No Docker detected. Will install via apt."
        DOCKER_TYPE="apt"
        DOCKER_CONFIG_PATH="/etc/docker/daemon.json"
        RESTART_CMD="systemctl restart docker"
        VERIFY_CMD="systemctl is-active docker"
    fi
}

# Function to install Docker
install_docker() {
    if [ "$DOCKER_TYPE" = "snap" ]; then
        echo "Installing Docker via Snap..."
        apt update
        apt install -y snapd jq
        snap install docker
        echo "✓ Docker installed via Snap."
    else
        echo "Installing Docker via apt (modern method)..."
        # Uninstall old versions
        for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
            apt-get remove -y $pkg || true
        done

        apt-get update
        apt-get install -y ca-certificates curl jq
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        echo "✓ Docker installed via apt."
    fi
}

# Ensure jq is installed (required for config updates)
if ! command -v jq >/dev/null 2>&1; then
    echo "Installing jq..."
    apt update
    apt install -y jq
    echo "✓ jq installed."
fi

# Function to backup existing config
backup_config() {
    if [ -f "$DOCKER_CONFIG_PATH" ]; then
        cp "$DOCKER_CONFIG_PATH" "${DOCKER_CONFIG_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
        echo "✓ Backup created."
    else
        echo "No existing config to backup."
    fi
}

# Function to create/update daemon.json
update_daemon_config() {
    echo "Updating Docker configuration..."
    mkdir -p "$(dirname "$DOCKER_CONFIG_PATH")"
    # If file exists, merge, remove fixed-cidr, and add new settings; else create new
    if [ -f "$DOCKER_CONFIG_PATH" ]; then
        jq --arg bip "$BIP" --argjson pools '[{"base": "'"$SUBNET"'", "size": '"$SIZE"'}]' \
           'del(.["fixed-cidr"]) | . + {"log-level": "error", "bip": $bip, "default-address-pools": $pools}' \
           "$DOCKER_CONFIG_PATH" > "${DOCKER_CONFIG_PATH}.tmp"
        mv "${DOCKER_CONFIG_PATH}.tmp" "$DOCKER_CONFIG_PATH"
    else
        cat > "$DOCKER_CONFIG_PATH" << EOF
{
    "log-level": "error",
    "bip": "$BIP",
    "default-address-pools": [
        {
            "base": "$SUBNET",
            "size": $SIZE
        }
    ]
}
EOF
    fi
    chmod 644 "$DOCKER_CONFIG_PATH"
    echo "✓ Configuration updated."
}

# Function to restart Docker
restart_docker() {
    echo "Restarting Docker..."
    if [ "$DOCKER_TYPE" = "apt" ]; then
        systemctl stop docker
        systemctl start docker
    else
        $RESTART_CMD
    fi
    sleep 30 # Increased for reliability
    echo "✓ Docker restarted."
}

# Function to verify Docker running
verify_docker_running() {
    if eval "$VERIFY_CMD"; then
        echo "✓ Docker is active."
    else
        echo "✗ Docker not active. Check logs with: journalctl -u docker (for apt) or snap logs docker (for snap)."
        exit 1
    fi
}

# Function to test IP change
test_ip_change() {
    echo "Testing bridge IP..."
    if ip addr show docker0 | grep -q "inet ${BIP%/*}"; then
        echo "✓ Bridge IP matches BIP."
    else
        echo "⚠ Bridge IP not showing yet (normal if no containers)."
    fi

    echo "Testing with temporary container..."
    # Clean up any existing test container before creating a new one
    cleanup_test_container
    if ! docker run -d --name "$TEST_CONTAINER_NAME" alpine sleep 10 >/dev/null 2>&1; then
        echo "✗ Failed to start test container. Check Docker network settings with: docker network inspect bridge"
        cleanup_test_container
        exit 1
    fi
    sleep 3
    CONTAINER_GW=$(docker exec "$TEST_CONTAINER_NAME" ip route show default | awk '{print $3}' | head -1)
    if [[ "$CONTAINER_GW" == "${BIP%/*}" ]]; then
        echo "✓ Container gateway: $CONTAINER_GW (SUCCESS)"
    else
        echo "✗ Container gateway: $CONTAINER_GW (FAILED)"
        cleanup_test_container
        exit 1
    fi
    cleanup_test_container
    echo "✓ IP change verified."
}

# Function for cleanup (remove test container if exists)
cleanup_test_container() {
    if docker ps -a | grep -q "$TEST_CONTAINER_NAME"; then
        docker rm -f "$TEST_CONTAINER_NAME" >/dev/null
        echo "✓ Cleaned up test container."
    fi
}

# Main execution
detect_docker_type
if [ -z "$DOCKER_TYPE" ]; then
    install_docker
    detect_docker_type # Re-detect after install
fi
backup_config
update_daemon_config
# Clean up old networks before restart
docker network prune -f
echo "✓ Cleaned up old Docker networks."
restart_docker
verify_docker_running
# Validate bridge config after restart
if ! docker network inspect bridge | grep -q "${BIP%/*}"; then
    echo "✗ Bridge IP not applied. Check /etc/docker/daemon.json and Docker logs."
    exit 1
fi
echo "✓ Bridge configuration validated."
test_ip_change
# Optional: Bring up docker0 if down
if ip link show docker0 | grep -q "state DOWN"; then
    ip link set docker0 up
    echo "✓ Brought docker0 up."
fi

echo ""
echo "========================================="
echo "✓ All done! Docker is installed/configured."
echo "Verify further: docker network inspect bridge"
echo "Verify pools: docker system info | grep -A 10 'Default Address Pools'"
echo "========================================="
