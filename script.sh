#!/bin/bash

# Script to automate Docker installation (via Snap on Ubuntu), IP change to 10.20.0.0/24, verification, and cleanup
# Run with sudo: sudo ./docker_install_and_ip_change.sh

set -e  # Exit on any error

# Configuration
DOCKER_CONFIG_PATH="/var/snap/docker/current/config/daemon.json"
SUBNET="10.20.0.0/16"
BIP="10.20.0.1/16"
SIZE=24
TEST_CONTAINER_NAME="temp-ip-test"

echo "========================================="
echo "Docker Install, IP Change, Verify, and Cleanup Script"
echo "Target IP range: $SUBNET"
echo "========================================="

# Function to check if Docker is installed
check_docker_installed() {
    if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
        echo "✓ Docker (Snap) is already installed."
        return 0
    elif command -v docker >/dev/null 2>&1; then
        echo "✓ Docker command found (non-Snap installation)."
        return 0
    else
        echo "✗ Docker not installed."
        return 1
    fi
}

# Function to install Docker via Snap
install_docker_snap() {
    echo "Installing Docker via Snap..."
    apt update
    apt install -y snapd
    snap install docker
    echo "✓ Docker installed via Snap."
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
        # Simple merge: assume existing is simple JSON, add keys if missing
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
    snap restart docker
    sleep 20
    echo "✓ Docker restarted."
}

# Function to verify Docker running
verify_docker_running() {
    if snap services docker | grep -q "docker.dockerd.*active"; then
        echo "✓ Docker is active."
        return 0
    else
        echo "✗ Docker not active. Check 'snap logs docker'."
        exit 1
    fi
}

# Function to test IP change
test_ip_change() {
    echo "Testing bridge IP..."
    if ip addr show docker0 | grep -q "inet $BIP"; then
        echo "✓ Bridge IP: $BIP"
    else
        echo "⚠ Bridge IP not showing yet (normal if no containers)."
    fi
    
    echo "Testing with temporary container..."
    docker run -d --name "$TEST_CONTAINER_NAME" alpine sleep 10 >/dev/null
    sleep 3
    CONTAINER_GW=$(docker exec "$TEST_CONTAINER_NAME" ip route show default | awk '{print $3}' | head -1)
    
    if [[ "$CONTAINER_GW" == "10.20.0.1" ]]; then
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
if ! check_docker_installed; then
    install_docker_snap
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

echo ""
echo "========================================="
echo "✓ All done! Docker is installed/configured."
echo "Verify further: docker network inspect bridge"
echo "========================================="
