sudo bash << 'ENDSCRIPT'
#!/bin/bash
set -e

echo "════════════════════════════════════════"
echo "  NodeJS Argo 安装脚本 v2.1 (修复版)"
echo "════════════════════════════════════════"
echo ""

# 权限检查
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行"
  exit 1
fi

# 系统检测
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
  OS_VERSION=$VERSION_ID
else
  OS="unknown"
  OS_VERSION="unknown"
fi

echo "✓ 系统: $OS $OS_VERSION"
echo ""

# ═══════════════════════════════════════
# 配置参数（交互式）
# ═══════════════════════════════════════

echo "请配置安装参数（直接回车使用默认值）："
echo ""

read -p "工作目录 [/opt/nodejs-argo]: " INPUT_WORKDIR
WORKDIR=${INPUT_WORKDIR:-/opt/nodejs-argo}

read -p "HTTP 端口 [3000]: " INPUT_PORT
PORT=${INPUT_PORT:-3000}

read -p "Argo 端口 [8001]: " INPUT_ARGO_PORT
ARGO_PORT=${INPUT_ARGO_PORT:-8001}

read -p "UUID [自动生成]: " INPUT_UUID
if [ -z "$INPUT_UUID" ]; then
  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "865c9c45-145e-40f4-aa59-1aa5ac212f5e")
else
  UUID="$INPUT_UUID"
fi

read -p "固定域名（可选）: " FIX_DOMAIN
ARGO_AUTH=""
if [ -n "$FIX_DOMAIN" ]; then
  read -p "ARGO_AUTH: " ARGO_AUTH
fi

read -p "哪吒服务器（可选，如 nz.example.com:443）: " NEZHA_SERVER
NEZHA_KEY=""
if [ -n "$NEZHA_SERVER" ]; then
  read -p "哪吒密钥: " NEZHA_KEY
fi

read -p "PROJECT_URL [https://www.google.com]: " INPUT_PROJECT_URL
PROJECT_URL=${INPUT_PROJECT_URL:-https://www.google.com}

echo ""
echo "配置确认:"
echo "  工作目录: $WORKDIR"
echo "  HTTP 端口: $PORT"
echo "  Argo 端口: $ARGO_PORT"
echo "  UUID: $UUID"
[ -n "$FIX_DOMAIN" ] && echo "  固定域名: $FIX_DOMAIN"
[ -n "$NEZHA_SERVER" ] && echo "  哪吒服务器: $NEZHA_SERVER"
echo ""

# ═══════════════════════════════════════
# 安装依赖
# ═══════════════════════════════════════

echo "📦 安装系统依赖..."
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1
  apt-get install -y curl ca-certificates git jq build-essential >/dev/null 2>&1
  echo "✓ 系统依赖安装完成"
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl ca-certificates git jq nodejs npm >/dev/null 2>&1
  echo "✓ 系统依赖安装完成"
fi

# ═══════════════════════════════════════
# 安装 Node.js
# ═══════════════════════════════════════

if ! command -v node >/dev/null 2>&1; then
  echo "📦 安装 Node.js..."
  
  if command -v apt-get >/dev/null 2>&1; then
    # 尝试 NodeSource
    if curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash - >/dev/null 2>&1; then
      if apt-get install -y nodejs >/dev/null 2>&1; then
        echo "✓ Node.js 安装成功: $(node -v)"
      else
        # 使用 NVM 备用方案
        echo "  使用 NVM 安装..."
        export NVM_DIR="/root/.nvm"
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh 2>/dev/null | bash >/dev/null 2>&1
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        nvm install 20 >/dev/null 2>&1
        nvm use 20 >/dev/null 2>&1
        ln -sf "$NVM_DIR/versions/node/$(nvm current)/bin/node" /usr/local/bin/node
        ln -sf "$NVM_DIR/versions/node/$(nvm current)/bin/npm" /usr/local/bin/npm
        echo "✓ Node.js 安装成功: $(node -v)"
      fi
    else
      # NVM 备用方案
      echo "  使用 NVM 安装..."
      export NVM_DIR="/root/.nvm"
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh 2>/dev/null | bash >/dev/null 2>&1
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
      nvm install 20 >/dev/null 2>&1
      nvm use 20 >/dev/null 2>&1
      ln -sf "$NVM_DIR/versions/node/$(nvm current)/bin/node" /usr/local/bin/node
      ln -sf "$NVM_DIR/versions/node/$(nvm current)/bin/npm" /usr/local/bin/npm
      echo "✓ Node.js 安装成功: $(node -v)"
    fi
  elif command -v apk >/dev/null 2>&1; then
    echo "✓ Node.js 已通过系统包安装"
  fi
else
  echo "✓ Node.js 已安装: $(node -v)"
fi

# ═══════════════════════════════════════
# 克隆项目
# ═══════════════════════════════════════

echo "📂 获取项目文件..."
mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -d nodejs-argo ]; then
  git clone -q https://github.com/cokear/nodejs.git nodejs-argo
  echo "✓ 项目克隆完成"
else
  echo "✓ 项目目录已存在"
fi

cd nodejs-argo

# 安装 npm 依赖
if [ -f package.json ]; then
  echo "📦 安装 npm 依赖..."
  npm install --production >/dev/null 2>&1
  echo "✓ npm 依赖安装完成"
fi

# ═══════════════════════════════════════
# 配置 systemd 服务
# ═══════════════════════════════════════

echo "⚙️  配置系统服务..."

SERVICE_FILE="/etc/systemd/system/nodejs-argo.service"
NODE_PATH=$(which node)

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=NodeJS Argo Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORKDIR/nodejs-argo
Environment="NODE_ENV=production"
Environment="PORT=$PORT"
Environment="ARGO_PORT=$ARGO_PORT"
Environment="UUID=$UUID"
Environment="PROJECT_URL=$PROJECT_URL"
EOF

# 添加可选配置
[ -n "$FIX_DOMAIN" ] && echo "Environment=\"ARGO_DOMAIN=$FIX_DOMAIN\"" >> "$SERVICE_FILE"
[ -n "$ARGO_AUTH" ] && echo "Environment=\"ARGO_AUTH=$ARGO_AUTH\"" >> "$SERVICE_FILE"
[ -n "$NEZHA_SERVER" ] && echo "Environment=\"NEZHA_SERVER=$NEZHA_SERVER\"" >> "$SERVICE_FILE"
[ -n "$NEZHA_KEY" ] && echo "Environment=\"NEZHA_KEY=$NEZHA_KEY\"" >> "$SERVICE_FILE"

cat >> "$SERVICE_FILE" <<EOF
ExecStart=$NODE_PATH $WORKDIR/nodejs-argo/index.js
Restart=always
RestartSec=10
StandardOutput=append:/var/log/nodejs-argo/output.log
StandardError=append:/var/log/nodejs-argo/error.log

[Install]
WantedBy=multi-user.target
EOF

# 创建日志目录
mkdir -p /var/log/nodejs-argo

# 配置 PM2 日志轮转（防止日志占满磁盘）
if command -v pm2 >/dev/null 2>&1; then
  pm2 install pm2-logrotate >/dev/null 2>&1 || true
  pm2 set pm2-logrotate:max_size 10M >/dev/null 2>&1 || true
  pm2 set pm2-logrotate:retain 7 >/dev/null 2>&1 || true
  pm2 set pm2-logrotate:compress true >/dev/null 2>&1 || true
fi

# 启动服务
systemctl daemon-reload
systemctl enable nodejs-argo >/dev/null 2>&1
systemctl start nodejs-argo

echo "✓ 系统服务配置完成"

# ═══════════════════════════════════════
# 等待服务启动
# ═══════════════════════════════════════

echo ""
echo "⏳ 等待服务启动..."
sleep 5

# ═══════════════════════════════════════
# 显示安装结果
# ═══════════════════════════════════════

echo ""
echo "════════════════════════════════════════"
echo "  ✅ 安装完成！"
echo "════════════════════════════════════════"
echo ""
echo "📊 系统信息:"
echo "  系统: $OS $OS_VERSION"
echo "  Node.js: $(node -v)"
echo "  工作目录: $WORKDIR/nodejs-argo"
echo ""

echo "🔧 管理命令:"
echo "  查看状态: systemctl status nodejs-argo"
echo "  查看日志: journalctl -u nodejs-argo -f"
echo "  重启服务: systemctl restart nodejs-argo"
echo "  停止服务: systemctl stop nodejs-argo"
echo ""

echo "📡 服务状态:"
if systemctl is-active --quiet nodejs-argo; then
  echo "  ✓ 服务运行中"
else
  echo "  ✗ 服务未运行"
fi

if pgrep -f "node.*index.js" >/dev/null; then
  echo "  ✓ Node.js 进程运行中"
else
  echo "  ✗ Node.js 进程未运行"
fi
echo ""

echo "📄 订阅信息:"
SUB_FILE="$WORKDIR/nodejs-argo/tmp/sub.txt"
if [ -f "$SUB_FILE" ]; then
  echo "  订阅文件: $SUB_FILE"
  echo ""
  cat "$SUB_FILE" 2>/dev/null || echo "  (订阅文件为空或无法读取)"
else
  echo "  ⏳ 订阅文件还未生成，请稍后查看"
  echo "  文件位置: $SUB_FILE"
fi

echo ""
echo "════════════════════════════════════════"

ENDSCRIPT
