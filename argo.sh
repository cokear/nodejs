#!/bin/bash
# nodejs_argo_fixed.sh - 修复版本

set -e

LOGFILE="/var/log/nodejs_argo_install.log"
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || LOGFILE="/tmp/nodejs_argo_install.log"

log() {
  msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" | tee -a "$LOGFILE"
}

log "开始 NodeJS Argo 安装脚本 v2.1 (修复版)"

# 权限检查
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限运行"
  exit 1
fi

# 系统检测
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
  OS_VERSION=$VERSION_ID
else
  OS=$(uname -s)
  OS_VERSION=$(uname -r)
fi

if command -v systemctl >/dev/null 2>&1; then
  INIT_SYSTEM="systemd"
elif command -v rc-service >/dev/null 2>&1; then
  INIT_SYSTEM="openrc"
else
  INIT_SYSTEM="sysvinit"
fi

log "系统: $OS $OS_VERSION"
log "初始化系统: $INIT_SYSTEM"

# 包管理器检测
if command -v apt-get >/dev/null 2>&1; then
  PKG_MANAGER="apt"
elif command -v apk >/dev/null 2>&1; then
  PKG_MANAGER="apk"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
else
  log "错误: 未检测到支持的包管理器"
  exit 1
fi

log "包管理器: $PKG_MANAGER"

# 选择操作
echo ""
read -p "请选择操作 1) 安装 2) 卸载（默认 1）: " ACTION
ACTION=${ACTION:-1}

# 卸载流程
if [ "$ACTION" = "2" ]; then
  log "开始卸载..."
  systemctl stop nodejs-argo 2>/dev/null || true
  systemctl disable nodejs-argo 2>/dev/null || true
  rm -f /etc/systemd/system/nodejs-argo.service
  systemctl daemon-reload 2>/dev/null || true
  
  if command -v pm2 >/dev/null 2>&1; then
    pm2 delete nodejs-argo 2>/dev/null || true
  fi
  
  pkill -f "node.*index.js" 2>/dev/null || true
  rm -rf /opt/nodejs-argo
  rm -rf /var/log/nodejs-argo
  
  log "✅ 卸载完成"
  exit 0
fi

# 配置参数
log "配置安装参数"

read -p "工作目录（默认 /opt/nodejs-argo）: " WORKDIR
WORKDIR=${WORKDIR:-/opt/nodejs-argo}
log "工作目录: $WORKDIR"

read -p "HTTP 端口（默认 3000）: " PORT
PORT=${PORT:-3000}

read -p "Argo 端口（默认 8001）: " ARGO_PORT
ARGO_PORT=${ARGO_PORT:-8001}

read -p "UUID（默认随机生成）: " UUID
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "865c9c45-145e-40f4-aa59-1aa5ac212f5e")}

read -p "固定域名（可选，直接回车跳过）: " FIX_DOMAIN
ARGO_AUTH=""
if [ -n "$FIX_DOMAIN" ]; then
  read -p "ARGO_AUTH: " ARGO_AUTH
fi

read -p "哪吒服务器（可选，如 nz.example.com:443）: " NEZHA_SERVER
NEZHA_KEY=""
if [ -n "$NEZHA_SERVER" ]; then
  read -p "哪吒密钥: " NEZHA_KEY
fi

read -p "PROJECT_URL（默认 https://www.google.com）: " PROJECT_URL
PROJECT_URL=${PROJECT_URL:-https://www.google.com}

# 创建工作目录
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# 安装依赖
log "安装依赖..."
if [ "$PKG_MANAGER" = "apt" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates git jq screen build-essential
fi

# 安装 Node.js
if ! command -v node >/dev/null 2>&1; then
  log "安装 Node.js..."
  
  if [ "$PKG_MANAGER" = "apt" ]; then
    # 使用 NVM
    export NVM_DIR="/root/.nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm install 20
    nvm use 20
    
    # 创建符号链接
    ln -sf "$NVM_DIR/versions/node/$(nvm current)/bin/node" /usr/local/bin/node
    ln -sf "$NVM_DIR/versions/node/$(nvm current)/bin/npm" /usr/local/bin/npm
  elif [ "$PKG_MANAGER" = "apk" ]; then
    apk add --no-cache nodejs npm
  fi
  
  log "Node.js 安装完成: $(node -v)"
else
  log "Node.js 已安装: $(node -v)"
fi

# 克隆项目
if [ ! -d nodejs-argo ]; then
  log "克隆项目..."
  git clone https://github.com/cokear/nodejs.git nodejs-argo
fi

cd nodejs-argo

# 安装 npm 依赖
if [ -f package.json ]; then
  log "安装 npm 依赖..."
  npm install --production
fi

# 构建环境变量
ENV_VARS="PORT=$PORT ARGO_PORT=$ARGO_PORT UUID=$UUID"
[ -n "$FIX_DOMAIN" ] && ENV_VARS="$ENV_VARS ARGO_DOMAIN=$FIX_DOMAIN"
[ -n "$ARGO_AUTH" ] && ENV_VARS="$ENV_VARS ARGO_AUTH='$ARGO_AUTH'"
[ -n "$NEZHA_SERVER" ] && ENV_VARS="$ENV_VARS NEZHA_SERVER=$NEZHA_SERVER"
[ -n "$NEZHA_KEY" ] && ENV_VARS="$ENV_VARS NEZHA_KEY=$NEZHA_KEY"
ENV_VARS="$ENV_VARS PROJECT_URL=$PROJECT_URL"

# 选择运行方式
echo ""
read -p "运行方式 1) screen 2) systemd（推荐） (默认 2): " RUNNER
RUNNER=${RUNNER:-2}

if [ "$RUNNER" = "1" ]; then
  # Screen 方式
  START_SCRIPT="$WORKDIR/start.sh"
  cat > "$START_SCRIPT" <<EOF
#!/bin/bash
cd $PWD
export $ENV_VARS
screen -dmS nodejs-argo node index.js
EOF
  chmod +x "$START_SCRIPT"
  
  # 添加到 crontab
  (crontab -l 2>/dev/null | grep -v "nodejs-argo"; echo "@reboot $START_SCRIPT") | crontab -
  
  # 立即启动
  bash "$START_SCRIPT"
  
  log "✅ Screen 方式配置完成"
  
else
  # Systemd 方式
  SERVICE_FILE="/etc/systemd/system/nodejs-argo.service"
  
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=NodeJS Argo Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$PWD
Environment="NODE_ENV=production"
$(echo "$ENV_VARS" | tr ' ' '\n' | sed 's/^/Environment="/' | sed 's/$/"/')
ExecStart=$(which node) $PWD/index.js
Restart=always
RestartSec=10
StandardOutput=append:/var/log/nodejs-argo/output.log
StandardError=append:/var/log/nodejs-argo/error.log

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p /var/log/nodejs-argo
  systemctl daemon-reload
  systemctl enable nodejs-argo
  systemctl start nodejs-argo
  
  log "✅ Systemd 服务配置完成"
fi

# 等待启动
log "等待服务启动..."
sleep 5

# 显示状态
echo ""
echo "════════════════════════════════════════"
echo "  安装完成"
echo "════════════════════════════════════════"
echo ""
echo "系统: $OS $OS_VERSION"
echo "Node.js: $(node -v)"
echo "工作目录: $PWD"
echo ""

if [ "$RUNNER" = "2" ]; then
  echo "管理命令:"
  echo "  查看状态: systemctl status nodejs-argo"
  echo "  查看日志: journalctl -u nodejs-argo -f"
  echo "  重启服务: systemctl restart nodejs-argo"
  echo "  停止服务: systemctl stop nodejs-argo"
else
  echo "管理命令:"
  echo "  查看进程: screen -r nodejs-argo"
  echo "  分离会话: Ctrl+A D"
fi

echo ""
echo "订阅文件: $PWD/tmp/sub.txt"
if [ -f "$PWD/tmp/sub.txt" ]; then
  echo "订阅内容:"
  cat "$PWD/tmp/sub.txt" 2>/dev/null || true
fi

echo ""
log "✅ 安装完成！"
