#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load environment
if [ -f .env.production ]; then
    source .env.production
else
    log_error ".env.production not found!"
    exit 1
fi

REBUILD=false
if [ "$1" == "--rebuild" ]; then
    REBUILD=true
    log_info "Rebuild mode: building without cache"
fi

log_info "Deploying kaernten-funkt to ${DEPLOY_HOST}:${REMOTE_DIR}"
echo ""

# Step 1: Ensure remote directory exists
log_info "Ensuring remote directory exists..."
ssh ${DEPLOY_HOST} "mkdir -p ${REMOTE_DIR}"
log_ok "Remote directory ready"

# Step 2: Sync repository
log_info "Checking remote repository..."
REPO_URL=$(git remote get-url origin 2>/dev/null || echo "")

if [ -z "$REPO_URL" ]; then
    log_warn "No git remote found. Syncing files with rsync..."
    rsync -avz --delete \
        --exclude node_modules \
        --exclude dist \
        --exclude .env \
        --exclude '.env.*' \
        --exclude .claude \
        ./ ${DEPLOY_HOST}:${REMOTE_DIR}/
    log_ok "Files synced"
else
    log_info "Git remote: ${REPO_URL}"
    ssh ${DEPLOY_HOST} "
        if [ -d ${REMOTE_DIR}/.git ]; then
            cd ${REMOTE_DIR} && git pull --ff-only
        else
            git clone ${REPO_URL} ${REMOTE_DIR}
        fi
    "
    log_ok "Repository synced"
fi

# Step 3: Create .env on remote (if needed)
log_info "Setting up remote environment..."
ssh ${DEPLOY_HOST} "cat > ${REMOTE_DIR}/.env.production << 'ENVEOF'
DEPLOY_HOST=${DEPLOY_HOST}
REMOTE_DIR=${REMOTE_DIR}
CONTAINER_NAME=${CONTAINER_NAME}
IMAGE_NAME=${IMAGE_NAME}
CONTAINER_PORT=${CONTAINER_PORT}
SITE_URL=${SITE_URL}
ENVEOF"
log_ok "Environment configured"

# Step 4: Build Docker image
log_info "Building Docker image on remote..."
if [ "$REBUILD" = true ]; then
    ssh ${DEPLOY_HOST} "cd ${REMOTE_DIR} && docker build --no-cache -t ${IMAGE_NAME} ."
else
    ssh ${DEPLOY_HOST} "cd ${REMOTE_DIR} && docker build -t ${IMAGE_NAME} ."
fi
log_ok "Docker image built"

# Step 5: Restart container
log_info "Restarting container..."
ssh ${DEPLOY_HOST} "cd ${REMOTE_DIR} && docker compose down && docker compose up -d"
log_ok "Container started"

# Step 6: Health check
log_info "Waiting for container to be healthy..."
sleep 5

CONTAINER_STATUS=$(ssh ${DEPLOY_HOST} "docker inspect --format='{{.State.Status}}' ${CONTAINER_NAME} 2>/dev/null || echo 'not found'")
if [ "$CONTAINER_STATUS" == "running" ]; then
    log_ok "Container is running"
else
    log_error "Container status: ${CONTAINER_STATUS}"
    exit 1
fi

# Step 7: Check local health
log_info "Checking local health..."
LOCAL_PORT=$(echo ${CONTAINER_PORT} | cut -d: -f1)
HTTP_STATUS=$(ssh ${DEPLOY_HOST} "curl -s -o /dev/null -w '%{http_code}' http://localhost:${LOCAL_PORT}/" 2>/dev/null || echo "000")
if [ "$HTTP_STATUS" == "200" ]; then
    log_ok "Local health check passed (HTTP ${HTTP_STATUS})"
else
    log_warn "Local health check returned HTTP ${HTTP_STATUS}"
fi

# Step 8: Check public URL
if [ -n "$SITE_URL" ]; then
    log_info "Checking public URL: ${SITE_URL}"
    PUBLIC_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${SITE_URL}" 2>/dev/null || echo "000")
    if [ "$PUBLIC_STATUS" == "200" ]; then
        log_ok "Public URL accessible (HTTP ${PUBLIC_STATUS})"
    else
        log_warn "Public URL returned HTTP ${PUBLIC_STATUS} - tunnel may need configuration"
    fi
fi

echo ""
log_ok "Deployment complete!"
echo -e "${GREEN}Site: ${SITE_URL}${NC}"
