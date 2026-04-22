#!/usr/bin/env bash
# OpenCTI Docker Install Script — Ubuntu 24.04
# Usage: sudo bash install-opencti.sh [install_dir] [admin_email] [admin_password] [host] [port]
set -euo pipefail

###############################################################################
# CONFIGURATION — override via arguments or edit defaults below
###############################################################################
INSTALL_DIR="${1:-/opt/opencti}"
OPENCTI_ADMIN_EMAIL="${2:-admin@opencti.io}"
OPENCTI_ADMIN_PASSWORD="${3:-ChangeMePlease}"
OPENCTI_HOST="${4:-localhost}"
OPENCTI_PORT="${5:-8080}"
ELASTIC_MEMORY_SIZE="4G"

###############################################################################
# HELPERS
###############################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Run this script as root or with sudo."

###############################################################################
# 1. REMOVE OLD DOCKER PACKAGES
###############################################################################
info "Removing conflicting Docker packages (if any)..."
for pkg in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
  apt-get remove -y "$pkg" 2>/dev/null || true
done

###############################################################################
# 2. INSTALL DOCKER (official repo)
###############################################################################
info "Installing prerequisites..."
apt-get update -qq
apt-get install -y ca-certificates curl jq

info "Adding Docker GPG key and repository..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

. /etc/os-release
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

info "Installing Docker CE..."
apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
info "Docker version: $(docker --version)"
info "Docker Compose version: $(docker compose version)"

###############################################################################
# 3. CLONE OPENCTI DOCKER REPO
###############################################################################
info "Cloning OpenCTI Docker repository to ${INSTALL_DIR}..."
if [[ -d "${INSTALL_DIR}/docker" ]]; then
  warn "Directory ${INSTALL_DIR}/docker already exists — pulling latest changes."
  git -C "${INSTALL_DIR}/docker" pull
else
  mkdir -p "${INSTALL_DIR}"
  git clone https://github.com/OpenCTI-Platform/docker.git "${INSTALL_DIR}/docker"
fi
cd "${INSTALL_DIR}/docker"

###############################################################################
# 4. GENERATE .env FILE
###############################################################################
info "Generating .env file with randomised secrets..."
MINIO_ROOT_USER=$(cat /proc/sys/kernel/random/uuid)
MINIO_ROOT_PASSWORD=$(cat /proc/sys/kernel/random/uuid)
RABBITMQ_DEFAULT_PASS=$(openssl rand -base64 32)
OPENCTI_ADMIN_TOKEN=$(cat /proc/sys/kernel/random/uuid)
OPENCTI_HEALTHCHECK_ACCESS_KEY=$(cat /proc/sys/kernel/random/uuid)
OPENCTI_ENCRYPTION_KEY=$(openssl rand -base64 32)

cat > "${INSTALL_DIR}/docker/.env" <<EOF
###########################
# DEPENDENCIES
###########################
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
RABBITMQ_DEFAULT_USER=opencti
RABBITMQ_DEFAULT_PASS=${RABBITMQ_DEFAULT_PASS}
SMTP_HOSTNAME=localhost
OPENSEARCH_ADMIN_PASSWORD=changeme
ELASTIC_MEMORY_SIZE=${ELASTIC_MEMORY_SIZE}

###########################
# COMMON
###########################
XTM_COMPOSER_ID=$(cat /proc/sys/kernel/random/uuid)
COMPOSE_PROJECT_NAME=xtm

###########################
# OPENCTI
###########################
OPENCTI_HOST=${OPENCTI_HOST}
OPENCTI_PORT=${OPENCTI_PORT}
OPENCTI_EXTERNAL_SCHEME=http
OPENCTI_ADMIN_EMAIL=${OPENCTI_ADMIN_EMAIL}
OPENCTI_ADMIN_PASSWORD=${OPENCTI_ADMIN_PASSWORD}
OPENCTI_ADMIN_TOKEN=${OPENCTI_ADMIN_TOKEN}
OPENCTI_HEALTHCHECK_ACCESS_KEY=${OPENCTI_HEALTHCHECK_ACCESS_KEY}
OPENCTI_ENCRYPTION_KEY=${OPENCTI_ENCRYPTION_KEY}

###########################
# OPENCTI CONNECTORS
###########################
CONNECTOR_EXPORT_FILE_STIX_ID=$(cat /proc/sys/kernel/random/uuid)
CONNECTOR_EXPORT_FILE_CSV_ID=$(cat /proc/sys/kernel/random/uuid)
CONNECTOR_EXPORT_FILE_TXT_ID=$(cat /proc/sys/kernel/random/uuid)
CONNECTOR_IMPORT_FILE_STIX_ID=$(cat /proc/sys/kernel/random/uuid)
CONNECTOR_IMPORT_DOCUMENT_ID=$(cat /proc/sys/kernel/random/uuid)
CONNECTOR_IMPORT_FILE_YARA_ID=$(cat /proc/sys/kernel/random/uuid)
CONNECTOR_IMPORT_EXTERNAL_REFERENCE_ID=$(cat /proc/sys/kernel/random/uuid)
CONNECTOR_ANALYSIS_ID=$(cat /proc/sys/kernel/random/uuid)

###########################
# OPENCTI DEFAULT DATA
###########################
CONNECTOR_OPENCTI_ID=$(cat /proc/sys/kernel/random/uuid)
CONNECTOR_MITRE_ID=$(cat /proc/sys/kernel/random/uuid)
EOF

info ".env file written to ${INSTALL_DIR}/docker/.env"

###############################################################################
# 5. KERNEL TUNING — required for ElasticSearch / OpenSearch
###############################################################################
info "Setting vm.max_map_count=1048575 (required for ElasticSearch)..."
sysctl -w vm.max_map_count=1048575

# Make persistent across reboots
if grep -q "^vm.max_map_count" /etc/sysctl.conf; then
  sed -i 's/^vm.max_map_count.*/vm.max_map_count=1048575/' /etc/sysctl.conf
else
  echo "vm.max_map_count=1048575" >> /etc/sysctl.conf
fi

###############################################################################
# 6. START OPENCTI
###############################################################################
info "Starting OpenCTI via docker compose (detached)..."
systemctl start docker
docker compose -f "${INSTALL_DIR}/docker/docker-compose.yml" \
  --env-file "${INSTALL_DIR}/docker/.env" up -d

###############################################################################
# 7. SUMMARY
###############################################################################
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  OpenCTI install complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "  URL:      http://${OPENCTI_HOST}:${OPENCTI_PORT}"
echo -e "  Email:    ${OPENCTI_ADMIN_EMAIL}"
echo -e "  Password: ${OPENCTI_ADMIN_PASSWORD}"
echo -e "  .env:     ${INSTALL_DIR}/docker/.env"
echo ""
echo -e "  Check container status:"
echo -e "    docker compose -f ${INSTALL_DIR}/docker/docker-compose.yml ps"
echo ""
echo -e "${YELLOW}  NOTE: First startup can take 3-5 minutes while services initialise.${NC}"
