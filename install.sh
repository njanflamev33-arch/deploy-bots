#!/bin/bash

# ============================================
# XeloraCloud VPS Bot - Installation Script
# ============================================
# This script installs and configures everything needed
# for the XeloraCloud Discord VPS hosting bot
# ============================================

set -e  # Exit on error

# Colors for beautiful output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# XeloraCloud ASCII Art
print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║   ██╗  ██╗███████╗██╗      ██████╗ ██████╗  █████╗      ║
║   ╚██╗██╔╝██╔════╝██║     ██╔═══██╗██╔══██╗██╔══██╗     ║
║    ╚███╔╝ █████╗  ██║     ██║   ██║██████╔╝███████║     ║
║    ██╔██╗ ██╔══╝  ██║     ██║   ██║██╔══██╗██╔══██║     ║
║   ██╔╝ ██╗███████╗███████╗╚██████╔╝██║  ██║██║  ██║     ║
║   ╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝     ║
║                                                           ║
║              ☁️  CLOUD VPS HOSTING PLATFORM  ☁️          ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Print step with styling
print_step() {
    echo -e "\n${PURPLE}▶ ${1}${NC}"
}

print_success() {
    echo -e "${GREEN}✓ ${1}${NC}"
}

print_error() {
    echo -e "${RED}✗ ${1}${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ ${1}${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ ${1}${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root!"
        echo "Please run: sudo ./install.sh"
        exit 1
    fi
    print_success "Running as root"
}

# Detect OS and Docker
detect_os() {
    print_step "Detecting environment..."
    
    # Check for Docker/Container
    IN_DOCKER=false
    if [ -f /.dockerenv ]; then
        IN_DOCKER=true
        print_warning "🐳 Running inside Docker container detected!"
    elif grep -q docker /proc/1/cgroup 2>/dev/null; then
        IN_DOCKER=true
        print_warning "🐳 Running inside Docker/Container environment detected!"
    fi
    
    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
        print_success "Detected: $PRETTY_NAME"
    else
        print_error "Cannot detect OS. This script supports Ubuntu/Debian."
        exit 1
    fi
    
    # Show Docker warning
    if [ "$IN_DOCKER" = true ]; then
        echo
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║           🐳 DOCKER ENVIRONMENT DETECTED 🐳          ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo
        print_info "Running LXD inside Docker requires:"
        echo -e "   ${YELLOW}•${NC} Privileged mode (--privileged)"
        echo -e "   ${YELLOW}•${NC} AppArmor unconfined (--security-opt apparmor=unconfined)"
        echo -e "   ${YELLOW}•${NC} Cgroup parent (--cgroup-parent=docker.slice)"
        echo
        print_warning "If your Docker container doesn't have these, LXD may not work!"
        echo
        print_info "Recommended Docker run command:"
        echo -e "${CYAN}docker run -it --privileged --security-opt apparmor=unconfined \\"
        echo -e "  --cgroup-parent=docker.slice -v /lib/modules:/lib/modules:ro \\"
        echo -e "  ubuntu:22.04 /bin/bash${NC}"
        echo
        
        read -p "$(echo -e ${YELLOW}Do you want to continue anyway? \(y/n\):${NC} )" -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Installation cancelled."
            exit 1
        fi
        print_success "Continuing with Docker-compatible installation..."
        echo
    fi
    
    # Check if Ubuntu or Debian
    if [[ "$OS" != "ubuntu" ]] && [[ "$OS" != "debian" ]]; then
        print_warning "This script is optimized for Ubuntu/Debian."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Update system
update_system() {
    print_step "Updating system packages..."
    apt-get update -qq
    apt-get upgrade -y -qq
    print_success "System updated"
}

# Install LXD/LXC with Docker support
install_lxd() {
    print_step "Installing LXD/LXC..."
    
    # Check if running in Docker/Container
    if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        print_warning "⚠️  Detected Docker/Container environment!"
        echo
        print_info "LXD in Docker requires special configuration."
        print_info "This will install LXD with Docker-specific settings."
        echo
        read -p "$(echo -e ${YELLOW}Continue with Docker-compatible LXD installation? \(y/n\):${NC} )" -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "LXD installation cancelled. Cannot proceed without LXD."
            exit 1
        fi
        
        DOCKER_MODE=true
    else
        DOCKER_MODE=false
    fi
    
    if command -v lxc &> /dev/null; then
        print_info "LXD is already installed"
        lxc version
    else
        if [ "$DOCKER_MODE" = true ]; then
            print_step "Installing LXD for Docker environment..."
            
            # Method 1: Try apt-get first (faster, more reliable in Docker)
            print_info "Attempting installation via apt..."
            apt-get update -qq
            
            if apt-get install -y lxd lxd-client 2>/dev/null; then
                print_success "LXD installed via apt"
            else
                print_warning "apt installation failed, trying snap..."
                
                # Install snapd for Docker
                print_info "Installing snapd with Docker compatibility..."
                apt-get install -y snapd fuse squashfuse
                
                # Start snapd
                systemctl unmask snapd.service || true
                systemctl enable snapd.socket || true
                systemctl start snapd.socket || true
                
                # Wait for snapd to be ready
                print_info "Waiting for snapd to initialize..."
                for i in {1..30}; do
                    if snap version &>/dev/null; then
                        break
                    fi
                    sleep 1
                done
                
                # Install LXD via snap with special flags
                print_info "Installing LXD via snap (Docker mode)..."
                snap install lxd --channel=latest/stable 2>/dev/null || snap install lxd || {
                    print_warning "Snap installation failed, using alternative method..."
                    
                    # Alternative: Install from Ubuntu repos
                    add-apt-repository -y ppa:ubuntu-lxc/stable || true
                    apt-get update -qq
                    apt-get install -y lxd lxd-client
                }
            fi
            
            # Add PATH for snap binaries
            export PATH=$PATH:/snap/bin
            echo 'export PATH=$PATH:/snap/bin' >> ~/.bashrc
            
            # Verify installation
            if command -v lxc &> /dev/null; then
                print_success "LXD installed successfully in Docker mode"
            else
                print_error "LXD installation failed!"
                print_info "Trying one more method..."
                
                # Last resort: Direct binary installation
                wget https://linuxcontainers.org/downloads/lxd/lxd-latest.tar.gz -O /tmp/lxd.tar.gz
                tar -xzf /tmp/lxd.tar.gz -C /usr/local/
                ln -sf /usr/local/lxd/bin/lxc /usr/local/bin/lxc
                ln -sf /usr/local/lxd/bin/lxd /usr/local/bin/lxd
                
                if command -v lxc &> /dev/null; then
                    print_success "LXD installed from source"
                else
                    print_error "All installation methods failed!"
                    exit 1
                fi
            fi
            
        else
            # Normal installation (non-Docker)
            # Install snapd if not present
            if ! command -v snap &> /dev/null; then
                print_info "Installing snapd..."
                apt-get install -y snapd
                systemctl enable --now snapd.socket
                sleep 5
            fi
            
            print_info "Installing LXD via snap..."
            snap install lxd
            print_success "LXD installed successfully"
        fi
        
        # Initialize LXD
        print_step "Initializing LXD..."
        
        if [ "$DOCKER_MODE" = true ]; then
            # Docker-specific initialization
            print_info "Configuring LXD for Docker environment..."
            
            # Create minimal preseed for Docker
            cat <<EOF | lxd init --preseed
config:
  core.https_address: '[::]:8443'
  core.trust_password: xeloracloud
networks:
- config:
    ipv4.address: 10.10.10.1/24
    ipv4.nat: "true"
    ipv6.address: none
  description: ""
  name: lxdbr0
  type: bridge
storage_pools:
- config:
    size: 30GB
  description: ""
  name: default
  driver: dir
profiles:
- config: {}
  description: ""
  devices:
    eth0:
      name: eth0
      network: lxdbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
EOF
            print_success "LXD initialized for Docker (using dir storage)"
            print_warning "Note: Using 'dir' storage driver (no ZFS in Docker)"
            
        else
            # Normal initialization with ZFS
            cat <<EOF | lxd init --preseed
config: {}
networks:
- config:
    ipv4.address: auto
    ipv6.address: none
  description: ""
  name: lxdbr0
  type: bridge
storage_pools:
- config:
    size: 50GB
  description: ""
  name: default
  driver: zfs
profiles:
- config: {}
  description: ""
  devices:
    eth0:
      name: eth0
      network: lxdbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
EOF
            print_success "LXD initialized with ZFS storage pool"
        fi
    fi
    
    # Verify LXD is working
    print_info "Verifying LXD installation..."
    if lxc list &>/dev/null; then
        print_success "✅ LXD is working correctly!"
    else
        print_warning "LXD may need additional configuration"
        print_info "Attempting to fix..."
        
        # Try to start LXD service
        systemctl start lxd || true
        systemctl start snap.lxd.daemon || true
        
        sleep 3
        
        if lxc list &>/dev/null; then
            print_success "✅ LXD is now working!"
        else
            print_error "LXD verification failed"
            print_info "You may need to manually configure LXD with: lxd init"
        fi
    fi
}

# Install Python and dependencies
install_python() {
    print_step "Installing Python and dependencies..."
    
    apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev \
        build-essential \
        git \
        wget \
        curl \
        htop \
        tmux \
        tmate \
        net-tools \
        sysstat
    
    print_success "System dependencies installed"
}

# Create XeloraCloud directory structure
create_directories() {
    print_step "Creating XeloraCloud directory structure..."
    
    INSTALL_DIR="/opt/xeloracloud"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    mkdir -p logs backups data
    
    print_success "Directory structure created at $INSTALL_DIR"
}

# Install Python packages
install_python_packages() {
    print_step "Installing Python packages..."
    
    # Create virtual environment
    python3 -m venv venv
    source venv/bin/activate
    
    # Upgrade pip
    pip install --upgrade pip setuptools wheel
    
    # Install required packages
    pip install \
        discord.py \
        aiohttp \
        psutil \
        python-dotenv \
        colorama \
        tabulate
    
    print_success "Python packages installed"
}

# Interactive configuration setup
interactive_config() {
    print_step "Interactive Configuration Setup"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}\n"
    
    # Get server IP
    print_info "Detecting server IP..."
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "0.0.0.0")
    print_success "Server IP: ${SERVER_IP}"
    echo
    
    # Discord Bot Token
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║          DISCORD BOT TOKEN (REQUIRED)                ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    print_info "Get your token from: ${CYAN}https://discord.com/developers/applications${NC}"
    print_info "Create a bot → Go to 'Bot' tab → Reset Token → Copy"
    echo
    
    while true; do
        read -p "$(echo -e ${GREEN}Enter your Discord Bot Token:${NC} )" DISCORD_TOKEN
        if [[ -z "$DISCORD_TOKEN" ]]; then
            print_error "Token cannot be empty!"
        elif [[ ${#DISCORD_TOKEN} -lt 50 ]]; then
            print_error "Token seems too short. Please check and try again."
        else
            print_success "Token saved!"
            break
        fi
    done
    echo
    
    # Main Admin ID
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║          MAIN ADMIN USER ID (REQUIRED)               ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    print_info "Enable Developer Mode in Discord → Right-click your profile → Copy ID"
    echo
    
    while true; do
        read -p "$(echo -e ${GREEN}Enter your Discord User ID:${NC} )" MAIN_ADMIN_ID
        if [[ -z "$MAIN_ADMIN_ID" ]]; then
            print_error "Admin ID cannot be empty!"
        elif ! [[ "$MAIN_ADMIN_ID" =~ ^[0-9]+$ ]]; then
            print_error "Admin ID must be a number!"
        else
            print_success "Main Admin ID saved!"
            break
        fi
    done
    echo
    
    # Additional Admin IDs
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║       ADDITIONAL ADMIN IDs (OPTIONAL)                ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    print_info "Add multiple admin Discord User IDs (comma-separated)"
    print_info "Example: 123456789012345678,987654321098765432"
    print_info "Press Enter to skip if you don't want additional admins"
    echo
    
    read -p "$(echo -e ${GREEN}Enter additional admin IDs \(or press Enter to skip\):${NC} )" ADDITIONAL_ADMINS
    
    if [[ -n "$ADDITIONAL_ADMINS" ]]; then
        # Clean up spaces
        ADDITIONAL_ADMINS=$(echo "$ADDITIONAL_ADMINS" | tr -d ' ')
        print_success "Additional admins will be added on first start!"
    else
        ADDITIONAL_ADMINS=""
        print_info "No additional admins configured"
    fi
    echo
    
    # Log Channel ID (Optional)
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║          LOG CHANNEL ID (OPTIONAL)                   ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    print_info "Create a channel in your Discord server for bot logs"
    print_info "Right-click the channel → Copy ID"
    print_info "Press Enter to skip (logs will only be in console)"
    echo
    
    read -p "$(echo -e ${GREEN}Enter Log Channel ID \(or press Enter to skip\):${NC} )" LOG_CHANNEL_ID
    
    if [[ -z "$LOG_CHANNEL_ID" ]]; then
        LOG_CHANNEL_ID="0"
        print_info "No log channel configured"
    elif ! [[ "$LOG_CHANNEL_ID" =~ ^[0-9]+$ ]]; then
        print_warning "Invalid ID, skipping log channel"
        LOG_CHANNEL_ID="0"
    else
        print_success "Log channel configured!"
    fi
    echo
    
    # Bot Prefix
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║              BOT COMMAND PREFIX                      ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    print_info "Choose your bot command prefix (default: .)"
    print_info "Examples: ! / ? / - / ."
    echo
    
    read -p "$(echo -e ${GREEN}Enter bot prefix \(or press Enter for default '.'\):${NC} )" BOT_PREFIX
    
    if [[ -z "$BOT_PREFIX" ]]; then
        BOT_PREFIX="."
        print_info "Using default prefix: ."
    else
        print_success "Prefix set to: ${BOT_PREFIX}"
    fi
    echo
    
    # VPS User Role ID
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║          VPS USER ROLE ID (OPTIONAL)                 ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    print_info "If you have a specific role for VPS users, enter its ID"
    print_info "Right-click the role → Copy ID"
    print_info "Press Enter to auto-create the role"
    echo
    
    read -p "$(echo -e ${GREEN}Enter VPS User Role ID \(or press Enter to auto-create\):${NC} )" VPS_USER_ROLE_ID
    
    if [[ -z "$VPS_USER_ROLE_ID" ]]; then
        VPS_USER_ROLE_ID="0"
        print_info "Role will be auto-created on first start"
    else
        print_success "VPS User Role ID saved!"
    fi
    echo
    
    # Advanced Settings
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║            ADVANCED SETTINGS                         ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    
    read -p "$(echo -e ${GREEN}Max VPS per user \(default: 5\):${NC} )" MAX_VPS
    MAX_VPS=${MAX_VPS:-5}
    
    read -p "$(echo -e ${GREEN}Default RAM in GB \(default: 2\):${NC} )" DEFAULT_RAM
    DEFAULT_RAM=${DEFAULT_RAM:-2}
    
    read -p "$(echo -e ${GREEN}Default CPU cores \(default: 2\):${NC} )" DEFAULT_CPU
    DEFAULT_CPU=${DEFAULT_CPU:-2}
    
    read -p "$(echo -e ${GREEN}Default Storage in GB \(default: 20\):${NC} )" DEFAULT_STORAGE
    DEFAULT_STORAGE=${DEFAULT_STORAGE:-20}
    
    echo
    print_success "Advanced settings configured!"
    
    # Create .env file
    print_step "Generating configuration file..."
    
    cat > .env << EOF
# ════════════════════════════════════════════════════════════
#           XeloraCloud Configuration File
#           Generated on $(date)
# ════════════════════════════════════════════════════════════

# ────────────────────────────────────────────────────────────
# DISCORD BOT CONFIGURATION
# ────────────────────────────────────────────────────────────
DISCORD_TOKEN=${DISCORD_TOKEN}
BOT_NAME=XeloraCloud
PREFIX=${BOT_PREFIX}

# ────────────────────────────────────────────────────────────
# SERVER CONFIGURATION
# ────────────────────────────────────────────────────────────
YOUR_SERVER_IP=${SERVER_IP}

# ────────────────────────────────────────────────────────────
# ADMIN CONFIGURATION
# ────────────────────────────────────────────────────────────
MAIN_ADMIN_ID=${MAIN_ADMIN_ID}
ADDITIONAL_ADMINS=${ADDITIONAL_ADMINS}

# ────────────────────────────────────────────────────────────
# DISCORD IDs
# ────────────────────────────────────────────────────────────
VPS_USER_ROLE_ID=${VPS_USER_ROLE_ID}
LOG_CHANNEL_ID=${LOG_CHANNEL_ID}

# ────────────────────────────────────────────────────────────
# STORAGE CONFIGURATION
# ────────────────────────────────────────────────────────────
DEFAULT_STORAGE_POOL=default

# ────────────────────────────────────────────────────────────
# RESOURCE THRESHOLDS (Percentage)
# ────────────────────────────────────────────────────────────
CPU_THRESHOLD=90
RAM_THRESHOLD=90
DISK_THRESHOLD=85

# ────────────────────────────────────────────────────────────
# FEATURES
# ────────────────────────────────────────────────────────────
AUTO_SUSPEND_ENABLED=false
MAX_VPS_PER_USER=${MAX_VPS}

# ────────────────────────────────────────────────────────────
# DEFAULT VPS RESOURCES
# ────────────────────────────────────────────────────────────
DEFAULT_RAM=${DEFAULT_RAM}
DEFAULT_CPU=${DEFAULT_CPU}
DEFAULT_STORAGE=${DEFAULT_STORAGE}

# ────────────────────────────────────────────────────────────
# PORT FORWARDING RANGE
# ────────────────────────────────────────────────────────────
PORT_RANGE_START=20000
PORT_RANGE_END=50000

# ────────────────────────────────────────────────────────────
# BACKUP SETTINGS
# ────────────────────────────────────────────────────────────
BACKUP_RETENTION_DAYS=30
AUTO_BACKUP_ENABLED=false

# ════════════════════════════════════════════════════════════
# End of Configuration
# ════════════════════════════════════════════════════════════
EOF
    
    chmod 600 .env  # Secure the file
    
    print_success "Configuration file created: .env"
    echo
    
    # Show configuration summary
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         CONFIGURATION SUMMARY                        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "${GREEN}✓${NC} Bot Token: ${CYAN}${DISCORD_TOKEN:0:20}...${NC}"
    echo -e "${GREEN}✓${NC} Main Admin ID: ${CYAN}${MAIN_ADMIN_ID}${NC}"
    if [[ -n "$ADDITIONAL_ADMINS" ]]; then
        echo -e "${GREEN}✓${NC} Additional Admins: ${CYAN}${ADDITIONAL_ADMINS}${NC}"
    fi
    if [[ "$LOG_CHANNEL_ID" != "0" ]]; then
        echo -e "${GREEN}✓${NC} Log Channel: ${CYAN}${LOG_CHANNEL_ID}${NC}"
    fi
    echo -e "${GREEN}✓${NC} Bot Prefix: ${CYAN}${BOT_PREFIX}${NC}"
    echo -e "${GREEN}✓${NC} Server IP: ${CYAN}${SERVER_IP}${NC}"
    echo -e "${GREEN}✓${NC} Max VPS/User: ${CYAN}${MAX_VPS}${NC}"
    echo -e "${GREEN}✓${NC} Default Resources: ${CYAN}${DEFAULT_RAM}GB RAM / ${DEFAULT_CPU} CPU / ${DEFAULT_STORAGE}GB Disk${NC}"
    echo
    
    read -p "$(echo -e ${YELLOW}Is this configuration correct? \(y/n\):${NC} )" -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Restarting configuration..."
        rm -f .env
        interactive_config
    else
        print_success "Configuration confirmed!"
    fi
}

# Create systemd service
create_service() {
    print_step "Creating systemd service..."
    
    cat > /etc/systemd/system/xeloracloud.service << EOF
[Unit]
Description=XeloraCloud VPS Hosting Bot
After=network.target lxd.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/xeloracloud
Environment="PATH=/opt/xeloracloud/venv/bin"
ExecStart=/opt/xeloracloud/venv/bin/python3 /opt/xeloracloud/bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    
    print_success "Systemd service created"
    print_info "Enable with: systemctl enable xeloracloud"
    print_info "Start with: systemctl start xeloracloud"
}

# Create helper scripts
create_helper_scripts() {
    print_step "Creating helper scripts..."
    
    # Start script
    cat > start.sh << 'EOF'
#!/bin/bash
echo "🚀 Starting XeloraCloud..."
systemctl start xeloracloud
systemctl status xeloracloud --no-pager
EOF
    chmod +x start.sh
    
    # Stop script
    cat > stop.sh << 'EOF'
#!/bin/bash
echo "🛑 Stopping XeloraCloud..."
systemctl stop xeloracloud
EOF
    chmod +x stop.sh
    
    # Restart script
    cat > restart.sh << 'EOF'
#!/bin/bash
echo "🔄 Restarting XeloraCloud..."
systemctl restart xeloracloud
systemctl status xeloracloud --no-pager
EOF
    chmod +x restart.sh
    
    # Logs script
    cat > logs.sh << 'EOF'
#!/bin/bash
echo "📋 XeloraCloud Logs (Press Ctrl+C to exit)"
journalctl -u xeloracloud -f
EOF
    chmod +x logs.sh
    
    # Update script
    cat > update.sh << 'EOF'
#!/bin/bash
echo "⬆️  Updating XeloraCloud..."
systemctl stop xeloracloud
git pull origin main
source venv/bin/activate
pip install --upgrade -r requirements.txt
systemctl start xeloracloud
echo "✅ Update complete!"
EOF
    chmod +x update.sh
    
    # Troubleshoot script
    cat > troubleshoot.sh << 'EOF'
#!/bin/bash
# XeloraCloud Troubleshooting Script

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      XeloraCloud Troubleshooting Tool                ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo

# Check if running in Docker
if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    echo -e "${YELLOW}🐳 Docker environment detected!${NC}\n"
fi

echo -e "${BLUE}[1/7] Checking LXD installation...${NC}"
if command -v lxc &> /dev/null; then
    echo -e "${GREEN}✓ LXD is installed${NC}"
    lxc version
else
    echo -e "${RED}✗ LXD is not installed${NC}"
    echo -e "   Run: ${CYAN}snap install lxd${NC}"
fi
echo

echo -e "${BLUE}[2/7] Checking LXD service...${NC}"
if systemctl is-active --quiet lxd 2>/dev/null; then
    echo -e "${GREEN}✓ LXD service is running${NC}"
elif systemctl is-active --quiet snap.lxd.daemon 2>/dev/null; then
    echo -e "${GREEN}✓ LXD daemon is running${NC}"
else
    echo -e "${YELLOW}⚠ LXD service may not be running${NC}"
    echo -e "   Try: ${CYAN}systemctl start lxd${NC}"
    echo -e "   Or: ${CYAN}systemctl start snap.lxd.daemon${NC}"
fi
echo

echo -e "${BLUE}[3/7] Testing LXD connectivity...${NC}"
if lxc list &>/dev/null; then
    echo -e "${GREEN}✓ LXD is responding${NC}"
    lxc list
else
    echo -e "${RED}✗ Cannot connect to LXD${NC}"
    echo -e "   Try: ${CYAN}lxd init${NC}"
fi
echo

echo -e "${BLUE}[4/7] Checking Python installation...${NC}"
if [ -d "/opt/xeloracloud/venv" ]; then
    echo -e "${GREEN}✓ Virtual environment exists${NC}"
else
    echo -e "${RED}✗ Virtual environment missing${NC}"
    echo -e "   Run: ${CYAN}cd /opt/xeloracloud && python3 -m venv venv${NC}"
fi
echo

echo -e "${BLUE}[5/7] Checking configuration...${NC}"
if [ -f "/opt/xeloracloud/.env" ]; then
    echo -e "${GREEN}✓ Configuration file exists${NC}"
    if grep -q "YOUR_DISCORD_BOT_TOKEN_HERE" /opt/xeloracloud/.env; then
        echo -e "${RED}✗ Discord token not configured!${NC}"
        echo -e "   Edit: ${CYAN}nano /opt/xeloracloud/.env${NC}"
    else
        echo -e "${GREEN}✓ Discord token configured${NC}"
    fi
else
    echo -e "${RED}✗ Configuration file missing${NC}"
fi
echo

echo -e "${BLUE}[6/7] Checking bot file...${NC}"
if [ -f "/opt/xeloracloud/bot.py" ]; then
    echo -e "${GREEN}✓ Bot file exists${NC}"
else
    echo -e "${RED}✗ Bot file missing${NC}"
    echo -e "   Copy with: ${CYAN}cp bot.py /opt/xeloracloud/${NC}"
fi
echo

echo -e "${BLUE}[7/7] Checking XeloraCloud service...${NC}"
if systemctl is-active --quiet xeloracloud 2>/dev/null; then
    echo -e "${GREEN}✓ XeloraCloud service is running${NC}"
    systemctl status xeloracloud --no-pager | head -15
else
    echo -e "${YELLOW}⚠ XeloraCloud service is not running${NC}"
    echo -e "   Start with: ${CYAN}systemctl start xeloracloud${NC}"
    echo -e "   Check logs: ${CYAN}journalctl -u xeloracloud -n 50${NC}"
fi
echo

echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Quick Fix Commands                      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo -e "${YELLOW}Restart LXD:${NC} ${CYAN}systemctl restart lxd${NC}"
echo -e "${YELLOW}Restart Bot:${NC} ${CYAN}systemctl restart xeloracloud${NC}"
echo -e "${YELLOW}View Logs:${NC} ${CYAN}journalctl -u xeloracloud -f${NC}"
echo -e "${YELLOW}Test LXD:${NC} ${CYAN}lxc launch ubuntu:22.04 test${NC}"
echo
EOF
    chmod +x troubleshoot.sh
    
    # Docker help document
    cat > DOCKER_HELP.md << 'EOF'
# 🐳 Running XeloraCloud in Docker

## ⚠️ Important Docker Requirements

LXD requires specific Docker configurations to run properly:

### Required Docker Run Flags:
```bash
docker run -it \
  --privileged \
  --security-opt apparmor=unconfined \
  --cgroup-parent=docker.slice \
  -v /lib/modules:/lib/modules:ro \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  ubuntu:22.04 /bin/bash
```

### Explanation:
- `--privileged`: Gives container extended privileges
- `--security-opt apparmor=unconfined`: Disables AppArmor restrictions
- `--cgroup-parent=docker.slice`: Proper cgroup configuration
- `-v /lib/modules:/lib/modules:ro`: Kernel modules access
- `-v /sys/fs/cgroup:/sys/fs/cgroup:rw`: Cgroup filesystem access

## 🔧 Alternative: Docker Compose

```yaml
version: '3.8'
services:
  xeloracloud:
    image: ubuntu:22.04
    privileged: true
    security_opt:
      - apparmor=unconfined
    cgroup_parent: docker.slice
    volumes:
      - /lib/modules:/lib/modules:ro
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      - ./xeloracloud:/opt/xeloracloud
    command: /bin/bash
```

## 🛠️ Troubleshooting Docker + LXD

### Problem: "cannot communicate with server"
**Solution:**
```bash
systemctl start lxd
# or
systemctl start snap.lxd.daemon
```

### Problem: LXD won't start
**Solution:**
```bash
# Use dir storage instead of ZFS
lxd init --auto --storage-backend=dir
```

### Problem: Permission denied
**Solution:**
```bash
# Ensure running as root in container
whoami  # should show 'root'

# Add your user to lxd group (if not root)
usermod -aG lxd $USER
```

## 📚 Best Practices

1. **Use Ubuntu 22.04** as base image (best LXD support)
2. **Allocate enough resources** (4GB+ RAM recommended)
3. **Use dir storage** in Docker (not ZFS)
4. **Check logs** regularly: `journalctl -u lxd -f`

## 🚀 Quick Start in Docker

```bash
# 1. Start privileged container
docker run -it --privileged ubuntu:22.04 bash

# 2. Install dependencies
apt update && apt install -y wget curl

# 3. Download and run install script
wget https://your-url/install.sh
chmod +x install.sh
./install.sh

# 4. Follow the interactive setup
# When asked about Docker, say YES

# 5. Start the bot
cd /opt/xeloracloud
./start.sh
```

## 📞 Need Help?

- Run troubleshooter: `./troubleshoot.sh`
- Check logs: `journalctl -u xeloracloud -f`
- Test LXD: `lxc list`

## 🔗 Useful Links

- LXD Documentation: https://linuxcontainers.org/lxd/
- Docker Documentation: https://docs.docker.com/
- XeloraCloud GitHub: [Your Repository]

---
*Remember: LXD in Docker is experimental. For production, use a VPS/dedicated server!*
EOF
    
    print_success "Helper scripts created"
}

# Configure firewall
configure_firewall() {
    print_step "Configuring firewall..."
    
    if command -v ufw &> /dev/null; then
        # Allow SSH
        ufw allow 22/tcp
        
        # Allow port range for VPS port forwarding
        ufw allow 20000:50000/tcp
        ufw allow 20000:50000/udp
        
        # Enable if not already
        if ! ufw status | grep -q "Status: active"; then
            print_warning "UFW will be enabled. Make sure SSH (port 22) is allowed!"
            read -p "Enable UFW firewall? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                ufw --force enable
                print_success "Firewall configured and enabled"
            fi
        else
            ufw reload
            print_success "Firewall rules updated"
        fi
    else
        print_info "UFW not installed, skipping firewall configuration"
    fi
}

# Optimize system for LXC
optimize_system() {
    print_step "Optimizing system for LXC containers..."
    
    # Increase inotify limits
    cat >> /etc/sysctl.conf << EOF

# XeloraCloud optimizations
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
fs.inotify.max_queued_events=32768
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
EOF
    
    sysctl -p
    
    print_success "System optimized for containers"
}

# Create requirements.txt
create_requirements() {
    cat > requirements.txt << EOF
discord.py>=2.3.0
aiohttp>=3.9.0
psutil>=5.9.0
python-dotenv>=1.0.0
colorama>=0.4.6
tabulate>=0.9.0
EOF
    print_success "Requirements file created"
}

# Final setup
final_setup() {
    print_step "Finalizing installation..."
    
    # Set permissions
    chown -R root:root /opt/xeloracloud
    chmod -R 755 /opt/xeloracloud
    
    print_success "Permissions set"
}

# Print completion message
print_completion() {
    echo -e "\n${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║          ✅  INSTALLATION COMPLETE!  ✅                   ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    echo -e "${GREEN}🎉 XeloraCloud has been installed successfully!${NC}\n"
    
    echo -e "${YELLOW}📋 CONFIGURATION DETAILS:${NC}"
    echo -e "   ${GREEN}✓${NC} Bot Token: ${CYAN}Configured${NC}"
    echo -e "   ${GREEN}✓${NC} Admin ID: ${CYAN}Configured${NC}"
    echo -e "   ${GREEN}✓${NC} Config File: ${CYAN}/opt/xeloracloud/.env${NC}\n"
    
    echo -e "${YELLOW}🚀 NEXT STEPS:${NC}"
    echo -e "   1️⃣  Copy your bot.py file to:"
    echo -e "      ${CYAN}cp bot.py /opt/xeloracloud/${NC}\n"
    
    echo -e "   2️⃣  Enable and start the service:"
    echo -e "      ${CYAN}systemctl enable xeloracloud${NC}"
    echo -e "      ${CYAN}systemctl start xeloracloud${NC}\n"
    
    echo -e "   3️⃣  Or use the helper scripts:"
    echo -e "      ${CYAN}cd /opt/xeloracloud${NC}"
    echo -e "      ${CYAN}./start.sh${NC}\n"
    
    echo -e "${YELLOW}🛠️  USEFUL COMMANDS:${NC}"
    echo -e "   • Start:    ${CYAN}./start.sh${NC} or ${CYAN}systemctl start xeloracloud${NC}"
    echo -e "   • Stop:     ${CYAN}./stop.sh${NC} or ${CYAN}systemctl stop xeloracloud${NC}"
    echo -e "   • Restart:  ${CYAN}./restart.sh${NC} or ${CYAN}systemctl restart xeloracloud${NC}"
    echo -e "   • Logs:     ${CYAN}./logs.sh${NC} or ${CYAN}journalctl -u xeloracloud -f${NC}"
    echo -e "   • Status:   ${CYAN}systemctl status xeloracloud${NC}\n"
    
    echo -e "${BLUE}📍 Installation Directory:${NC} ${CYAN}/opt/xeloracloud${NC}"
    echo -e "${BLUE}📍 Configuration File:${NC} ${CYAN}/opt/xeloracloud/.env${NC}"
    echo -e "${BLUE}📍 Log File:${NC} ${CYAN}/opt/xeloracloud/xeloracloud.log${NC}\n"
    
    # Docker-specific instructions
    if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║       🐳 DOCKER ENVIRONMENT DETECTED 🐳              ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
        echo
        print_warning "Running in Docker! Important notes:"
        echo -e "   ${YELLOW}•${NC} LXD may have limited functionality"
        echo -e "   ${YELLOW}•${NC} Ensure Docker is running with --privileged"
        echo -e "   ${YELLOW}•${NC} Test LXD with: ${CYAN}lxc list${NC}"
        echo -e "   ${YELLOW}•${NC} If issues occur, check: ${CYAN}./troubleshoot.sh${NC}"
        echo
    fi
    
    echo -e "${GREEN}🌟 Get your Discord Bot Token:${NC}"
    echo -e "   ${CYAN}https://discord.com/developers/applications${NC}\n"
    
    echo -e "${GREEN}🌟 Get your Discord User ID:${NC}"
    echo -e "   ${CYAN}Enable Developer Mode in Discord → Right-click your profile → Copy ID${NC}\n"
    
    echo -e "${YELLOW}⚠️  TROUBLESHOOTING:${NC}"
    echo -e "   If LXD doesn't work, run: ${CYAN}./troubleshoot.sh${NC}"
    echo -e "   For Docker issues: ${CYAN}cat /opt/xeloracloud/DOCKER_HELP.md${NC}\n"
    
    echo -e "${PURPLE}💜 Thank you for choosing XeloraCloud!${NC}"
    echo -e "${PURPLE}☁️  Happy hosting! ☁️${NC}\n"
}
    
    echo -e "${YELLOW}🛠️  USEFUL COMMANDS:${NC}"
    echo -e "   • Start:    ${CYAN}./start.sh${NC} or ${CYAN}systemctl start xeloracloud${NC}"
    echo -e "   • Stop:     ${CYAN}./stop.sh${NC} or ${CYAN}systemctl stop xeloracloud${NC}"
    echo -e "   • Restart:  ${CYAN}./restart.sh${NC} or ${CYAN}systemctl restart xeloracloud${NC}"
    echo -e "   • Logs:     ${CYAN}./logs.sh${NC} or ${CYAN}journalctl -u xeloracloud -f${NC}"
    echo -e "   • Status:   ${CYAN}systemctl status xeloracloud${NC}\n"
    
    echo -e "${BLUE}📍 Installation Directory:${NC} ${CYAN}/opt/xeloracloud${NC}"
    echo -e "${BLUE}📍 Configuration File:${NC} ${CYAN}/opt/xeloracloud/.env${NC}"
    echo -e "${BLUE}📍 Log File:${NC} ${CYAN}/opt/xeloracloud/xeloracloud.log${NC}\n"
    
    echo -e "${GREEN}🌟 Get your Discord Bot Token:${NC}"
    echo -e "   ${CYAN}https://discord.com/developers/applications${NC}\n"
    
    echo -e "${GREEN}🌟 Get your Discord User ID:${NC}"
    echo -e "   ${CYAN}Enable Developer Mode in Discord → Right-click your profile → Copy ID${NC}\n"
    
    echo -e "${PURPLE}💜 Thank you for choosing XeloraCloud!${NC}"
    echo -e "${PURPLE}☁️  Happy hosting! ☁️${NC}\n"
}

# ============================================
# MAIN INSTALLATION FLOW
# ============================================

main() {
    clear
    print_banner
    
    print_info "Starting XeloraCloud installation...\n"
    sleep 2
    
    check_root
    detect_os
    update_system
    install_lxd
    install_python
    create_directories
    install_python_packages
    create_requirements
    interactive_config  # Interactive configuration instead of create_config
    create_service
    create_helper_scripts
    configure_firewall
    optimize_system
    final_setup
    
    print_completion
}

# Run main function
main

exit 0
