#!/bin/bash
# Script to automate Docker installation (via Snap or apt on Ubuntu), IP change to 10.20.0.0/16, verification, and cleanup
# Run with sudo: sudo ./docker_install_and_ip_change.sh
set -e # Exit on any error

# Configuration
SUBNET="10.20.0.0/16"
BIP="10.20.1.1/24"  # Safer: Small /24 for bridge, outside main pools to avoid overlap
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
        echo "✗ No Docker detected. Will install via Snap."
        DOCKER_TYPE="snap"
        DOCKER_CONFIG_PATH="/var/snap/docker/current/config/daemon.json"
        RESTART_CMD="snap restart docker"
        VERIFY_CMD="snap services docker | grep -q 'docker.dockerd.*active'"
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
        echo "Installing Docker via apt..."
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common jq
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update
        apt install -y docker-ce
        echo "✓ Docker installed via apt."
    fi
}

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
   
    # If file exists, merge; else create new
    if [ -f "$DOCKER_CONFIG_PATH" ]; then
        jq --arg bip "$BIP" --argjson pools '[{"base": "'"$SUBNET"'", "size": '"$SIZE"'}]' \
           '. + {"log-level": "error", "bip": $bip, "default-address-pools": $pools}' \
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
    $RESTART_CMD
    sleep 30  # Increased for reliability
    echo "✓ Docker restarted."
}

# Function to verify Docker running
verify_docker_running() {
    if eval "$VERIFY_CMD"; then
        echo "✓ Docker is active."
    else
        echo "✗ Docker not active. Check logs."
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
    docker run -d --name "$TEST_CONTAINER_NAME" alpine sleep 10 >/dev/null
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
    install_docker  # Defaults to Snap if none detected
    detect_docker_type  # Re-detect after install
fi
backup_config
update_daemon_config
restart_docker
verify_docker_running
test_ip_change
# Optional: Bring up docker0 if down
if ip link show docker0 | grep -q "state DOWN"; then
    ip link set docker0 up
    echo "✓ Brought docker0 up."
fi
docker network prune -f  # Clean up old networks to free IPs

echo ""
echo "========================================="
echo "✓ All done! Docker is installed/configured."
echo "Verify further: docker network inspect bridge"
echo "Verify pools: docker system info | grep -A 10 'Default Address Pools'"
echo "========================================="
