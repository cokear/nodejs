#!/bin/sh
# nodejs_argo_alpine.sh - Alpine Linux 版本（修复管道执行）
# 适用于 curl | bash 在线执行

set -e

LOGFILE="/var/log/nodejs_argo_install.log"
mkdir -p "$(dirname "$LOGFILE")"

log() {
  msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" | tee -a "$LOGFILE"
}

log "开始 NodeJS Argo 完整安装与管理脚本 (Alpine Linux)"

# ===== 选择操作 =====
printf "请选择操作 1) 安装 2) 卸载（默认 1）: "
read -r ACTION
ACTION=${ACTION:-1}

if [ "$ACTION" = "2" ]; then
  log "开始卸载流程"

  # 停止 OpenRC 服务
  if rc-service nodejs-argo status >/dev/null 2>&1; then
    log "停止 OpenRC 服务 nodejs-argo"
    rc-service nodejs-argo stop || true
    rc-update del nodejs-argo default || true
  fi

  # 停止 PM2
  if command -v pm2 >/dev/null 2>&1; then
    if pm2 list | grep -q nodejs-argo; then
      log "停止 PM2 应用 nodejs-argo"
      pm2 stop nodejs-argo
      pm2 delete nodejs-argo
      pm2 save
      pm2 unstartup || true
    fi
  fi

  # 停止 screen
  if screen -ls 2>/dev/null | grep -q "nodejs-argo"; then
    log "结束 screen 会话 nodejs-argo"
    screen -S nodejs-argo -X quit || true
  fi

  # 删除 crontab 自启动
  if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null | grep -v "nodejs-argo" | crontab - || true
  fi

  # 停止进程
  pkill -f "node.*index.js" || true

  # 移除安装目录
  if [ -d "/opt/nodejs-argo" ]; then
    log "移除 /opt/nodejs-argo 安装目录"
    rm -rf /opt/nodejs-argo
  fi

  # 移除服务文件
  if [ -f "/etc/init.d/nodejs-argo" ]; then
    rm -f /etc/init.d/nodejs-argo
  fi

  # 移除自启动脚本
  if [ -f "/etc/local.d/nodejs-argo.start" ]; then
    rm -f /etc/local.d/nodejs-argo.start
  fi

  log "卸载完成"
  exit 0
fi

log "开始安装流程"

# ===== 1) 工作目录 =====
printf "工作目录（默认 /opt/nodejs-argo）: "
read -r WORKDIR
WORKDIR=${WORKDIR:-/opt/nodejs-argo}
mkdir -p "$WORKDIR"
cd "$WORKDIR"
log "工作目录: $WORKDIR"

# ===== 2) 主要参数 =====
printf "HTTP 服务端口 PORT（默认 3000）: "
read -r PORT
PORT=${PORT:-3000}

printf "Argo 隧道端口 ARGO_PORT（默认 8001）: "
read -r ARGO_PORT
ARGO_PORT=${ARGO_PORT:-8001}

printf "UUID（默认 865c9c45-145e-40f4-aa59-1aa5ac212f5e）: "
read -r UUID
UUID=${UUID:-865c9c45-145e-40f4-aa59-1aa5ac212f5e}

printf "是否使用固定隧道？输入固定域名（如 frr.61154321.dpdns.org），若不使用请直接回车: "
read -r FIX_DOMAIN
FIX_DOMAIN=${FIX_DOMAIN:-}
ARGO_AUTH=""
if [ -n "$FIX_DOMAIN" ]; then
  printf "固定隧道鉴权 ARGO_AUTH: "
  read -r ARGO_AUTH
  ARGO_AUTH=${ARGO_AUTH:-}
fi

# ===== 哪吒配置（修复版）=====
printf "NEZHA 服务地址（格式: nz.example.com:443 或 nz.example.com），若不配置直接回车: "
read -r NEZHA_SERVER
NEZHA_SERVER=${NEZHA_SERVER:-}
NEZHA_PORT=""
NEZHA_KEY=""
NEZHA_VERSION=""

if [ -n "$NEZHA_SERVER" ]; then
  printf "选择哪吒版本：1) v1（推荐） 2) v0（默认 1）: "
  read -r NEZHA_VERSION_CHOICE
  NEZHA_VERSION_CHOICE=${NEZHA_VERSION_CHOICE:-1}
  
  if [ "$NEZHA_VERSION_CHOICE" = "1" ]; then
    NEZHA_VERSION="v1"
    if ! echo "$NEZHA_SERVER" | grep -q ":"; then
      printf "请输入端口（默认 443）: "
      read -r NEZHA_PORT_INPUT
      NEZHA_PORT_INPUT=${NEZHA_PORT_INPUT:-443}
      NEZHA_SERVER="${NEZHA_SERVER}:${NEZHA_PORT_INPUT}"
    fi
    NEZHA_PORT=""
    printf "Nezha 密钥 (NZ_CLIENT_SECRET): "
    read -r NEZHA_KEY
    log "✅ 使用哪吒 v1，NEZHA_SERVER=$NEZHA_SERVER, NEZHA_PORT=(留空)"
  else
    NEZHA_VERSION="v0"
    if echo "$NEZHA_SERVER" | grep -q ":"; then
      NEZHA_PORT=$(echo "$NEZHA_SERVER" | cut -d: -f2)
      NEZHA_SERVER=$(echo "$NEZHA_SERVER" | cut -d: -f1)
    else
      printf "请输入端口（默认 5555）: "
      read -r NEZHA_PORT
      NEZHA_PORT=${NEZHA_PORT:-5555}
    fi
    printf "Nezha Agent 密钥: "
    read -r NEZHA_KEY
    log "✅ 使用哪吒 v0，NEZHA_SERVER=$NEZHA_SERVER, NEZHA_PORT=$NEZHA_PORT"
  fi
fi

printf "UPLOAD_URL 订阅上传地址（可选）: "
read -r UPLOAD_URL
printf "PROJECT_URL 项目域名地址（默认 https://www.google.com）: "
read -r PROJECT_URL
PROJECT_URL=${PROJECT_URL:-https://www.google.com}

log "输入摘要: PORT=$PORT ARGO_PORT=$ARGO_PORT FIX_DOMAIN=${FIX_DOMAIN} NEZHA=$NEZHA_VERSION:${NEZHA_SERVER}:${NEZHA_PORT}"

# ===== 3) 安装基础依赖与 Node.js (Alpine) =====
log "安装依赖与 Node.js 环境 (Alpine)..."
apk update
apk add --no-cache \
  curl \
  ca-certificates \
  git \
  jq \
  screen \
  tmux \
  bash \
  nodejs \
  npm \
  openrc \
  dcron \
  net-tools

# 启用 cron 和 local 服务
rc-update add dcron default || true
rc-update add local default || true

# ===== 4) 获取资源 =====
if [ ! -d nodejs-argo ]; then
  log "克隆 nodejs-argo 仓库..."
  git clone https://github.com/cokear/nodejs.git nodejs-argo
fi
cd nodejs-argo

# ===== 5) 安装依赖 =====
if [ -f package.json ]; then
  log "安装 npm 依赖..."
  npm install --production
fi

# ===== 6) 构建环境变量 =====
ENV_VARS="PORT=${PORT} ARGO_PORT=${ARGO_PORT} UUID=${UUID}"

# 固定隧道
if [ -n "$FIX_DOMAIN" ]; then
  ENV_VARS="$ENV_VARS ARGO_DOMAIN=${FIX_DOMAIN}"
  if [ -n "$ARGO_AUTH" ]; then
    ENV_VARS="$ENV_VARS ARGO_AUTH='${ARGO_AUTH}'"
  fi
fi

# 哪吒配置
if [ -n "$NEZHA_SERVER" ]; then
  ENV_VARS="$ENV_VARS NEZHA_SERVER=${NEZHA_SERVER}"
  if [ -n "$NEZHA_PORT" ]; then
    ENV_VARS="$ENV_VARS NEZHA_PORT=${NEZHA_PORT}"
  fi
  if [ -n "$NEZHA_KEY" ]; then
    ENV_VARS="$ENV_VARS NEZHA_KEY=${NEZHA_KEY}"
  fi
fi

# 其他配置
ENV_VARS="$ENV_VARS UPLOAD_URL='${UPLOAD_URL:-}' PROJECT_URL=${PROJECT_URL}"

log "环境变量: $ENV_VARS"

START_CMD="node index.js"

# ===== 7) 后台运行方式 =====
printf "后台运行方式：1) screen+cron 2) tmux+cron 3) pm2 4) openrc（默认 4）: "
read -r RUNNER
RUNNER=${RUNNER:-4}

case "$RUNNER" in
  1)
    log "启动: screen + cron 自启动"
    
    # 创建启动脚本 - 修复：使用引号包裹
    START_SCRIPT="$WORKDIR/start_nodejs_argo.sh"
    cat > "$START_SCRIPT" << 'SCRIPT_END'
#!/bin/sh
cd __PWD__
export __ENV_VARS__
screen -dmS nodejs-argo sh -c "__START_CMD__"
SCRIPT_END
    
    # 替换占位符
    sed -i "s|__PWD__|$PWD|g" "$START_SCRIPT"
    sed -i "s|__ENV_VARS__|$ENV_VARS|g" "$START_SCRIPT"
    sed -i "s|__START_CMD__|$START_CMD|g" "$START_SCRIPT"
    chmod +x "$START_SCRIPT"
    
    # 添加到 crontab
    (crontab -l 2>/dev/null | grep -v "nodejs-argo"; echo "@reboot sleep 10 && $START_SCRIPT") | crontab -
    
    # 立即启动
    screen -dmS nodejs-argo sh -c "export $ENV_VARS; $START_CMD"
    
    log "✅ 已添加 crontab 自启动任务"
    ;;
    
  2)
    log "启动: tmux + cron 自启动"
    
    # 创建启动脚本
    START_SCRIPT="$WORKDIR/start_nodejs_argo.sh"
    cat > "$START_SCRIPT" << 'SCRIPT_END'
#!/bin/sh
cd __PWD__
export __ENV_VARS__
tmux new-session -d -s nodejs-argo "__START_CMD__"
SCRIPT_END
    
    sed -i "s|__PWD__|$PWD|g" "$START_SCRIPT"
    sed -i "s|__ENV_VARS__|$ENV_VARS|g" "$START_SCRIPT"
    sed -i "s|__START_CMD__|$START_CMD|g" "$START_SCRIPT"
    chmod +x "$START_SCRIPT"
    
    # 添加到 crontab
    (crontab -l 2>/dev/null | grep -v "nodejs-argo"; echo "@reboot sleep 10 && $START_SCRIPT") | crontab -
    
    # 立即启动
    tmux new-session -d -s nodejs-argo "export $ENV_VARS; $START_CMD"
    
    log "✅ 已添加 crontab 自启动任务"
    ;;
    
  3)
    log "启动: PM2 (内置自启动)"
    if ! command -v pm2 >/dev/null 2>&1; then
      npm install -g pm2
    fi
    
    # 创建 ecosystem 配置文件 - 使用临时文件方式
    ECOSYSTEM_FILE="$PWD/ecosystem.config.js"
    cat > "$ECOSYSTEM_FILE" << 'ECOSYSTEM_END'
module.exports = {
  apps: [{
    name: 'nodejs-argo',
    script: 'index.js',
    cwd: '__PWD__',
    env: {
__ENV_VARS_JS__
    },
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '500M'
  }]
};
ECOSYSTEM_END
    
    # 转换环境变量为 JS 格式
    ENV_VARS_JS=$(echo "$ENV_VARS" | tr ' ' '\n' | sed "s/=/: '/;s/$/',/" | sed 's/^/      /')
    sed -i "s|__PWD__|$PWD|g" "$ECOSYSTEM_FILE"
    sed -i "s|__ENV_VARS_JS__|$ENV_VARS_JS|g" "$ECOSYSTEM_FILE"
    
    # PM2 启动
    pm2 start "$ECOSYSTEM_FILE"
    pm2 save
    
    # 配置 PM2 自启动
    pm2 startup | grep -E "sudo|rc-update" | sh || true
    
    log "✅ PM2 自启动已配置"
    ;;
    
  4)
    log "启动: OpenRC (系统服务自启动)"
    SERVICE_FILE="/etc/init.d/nodejs-argo"
    
    # 生成环境变量字符串
    ENV_EXPORTS=$(echo "$ENV_VARS" | sed "s/\([A-Z_]*\)='\?\([^']*\)'\?/export \1='\2'/g")
    
    # 创建服务文件 - 使用临时文件
    cat > "$SERVICE_FILE" << 'SERVICE_END'
#!/sbin/openrc-run

name="nodejs-argo"
description="NodeJS Argo Service"

command="/usr/bin/node"
command_args="__PWD__/index.js"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
directory="__PWD__"
output_log="/var/log/nodejs-argo/output.log"
error_log="/var/log/nodejs-argo/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    mkdir -p 
