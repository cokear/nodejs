#!/bin/sh
# nodejs_argo_alpine.sh - 使用 npm 全局安装版本

set -e

LOGFILE="/var/log/nodejs_argo_install.log"
mkdir -p "$(dirname "$LOGFILE")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log "开始 NodeJS Argo 安装 (npm 全局安装版)"

# ===== 选择操作 =====
printf "请选择操作 1) 安装 2) 卸载（默认 1）: "
read -r ACTION
ACTION=${ACTION:-1}

if [ "$ACTION" = "2" ]; then
  log "开始卸载流程"
  
  # 停止服务
  rc-service nodejs-argo stop || true
  rc-update del nodejs-argo default || true
  
  # 卸载 npm 包
  npm uninstall -g nodejs-argo
  
  # 删除配置文件
  rm -rf /etc/nodejs-argo
  rm -f /etc/init.d/nodejs-argo
  
  log "卸载完成"
  exit 0
fi

log "开始安装流程"

# ===== 安装依赖 =====
log "安装系统依赖..."
apk update
apk add --no-cache \
  curl \
  ca-certificates \
  nodejs \
  npm \
  openrc \
  net-tools

# ===== 全局安装 nodejs-argo =====
log "从 npm 全局安装 nodejs-argo..."
npm install -g nodejs-argo

# ===== 配置参数 =====
printf "HTTP 服务端口 PORT（默认 3000）: "
read -r PORT
PORT=${PORT:-3000}

printf "Argo 隧道端口 ARGO_PORT（默认 8001）: "
read -r ARGO_PORT
ARGO_PORT=${ARGO_PORT:-8001}

printf "UUID（默认 865c9c45-145e-40f4-aa59-1aa5ac212f5e）: "
read -r UUID
UUID=${UUID:-865c9c45-145e-40f4-aa59-1aa5ac212f5e}

printf "固定域名（可选，直接回车跳过）: "
read -r FIX_DOMAIN

if [ -n "$FIX_DOMAIN" ]; then
  printf "ARGO_AUTH: "
  read -r ARGO_AUTH
fi

printf "NEZHA 服务地址（可选）: "
read -r NEZHA_SERVER

if [ -n "$NEZHA_SERVER" ]; then
  printf "NEZHA_PORT（默认 443）: "
  read -r NEZHA_PORT
  NEZHA_PORT=${NEZHA_PORT:-443}
  
  printf "NEZHA_KEY: "
  read -r NEZHA_KEY
fi

# ===== 创建配置文件 =====
CONFIG_DIR="/etc/nodejs-argo"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_DIR/config.env" <<EOF
PORT=${PORT}
ARGO_PORT=${ARGO_PORT}
UUID=${UUID}
ARGO_DOMAIN=${FIX_DOMAIN}
ARGO_AUTH=${ARGO_AUTH}
NEZHA_SERVER=${NEZHA_SERVER}
NEZHA_PORT=${NEZHA_PORT}
NEZHA_KEY=${NEZHA_KEY}
EOF

log "配置文件已保存到: $CONFIG_DIR/config.env"

# ===== 创建 OpenRC 服务 =====
SERVICE_FILE="/etc/init.d/nodejs-argo"

cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run

name="nodejs-argo"
description="NodeJS Argo Service"

command="/usr/bin/nodejs-argo"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/nodejs-argo/output.log"
error_log="/var/log/nodejs-argo/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    mkdir -p /var/log/nodejs-argo
    
    # 加载配置文件
    if [ -f /etc/nodejs-argo/config.env ]; then
        set -a
        . /etc/nodejs-argo/config.env
        set +a
    fi
}

start() {
    ebegin "Starting ${name}"
    start-stop-daemon --start \
        --background \
        --make-pidfile \
        --pidfile "${pidfile}" \
        --stdout "${output_log}" \
        --stderr "${error_log}" \
        --exec "${command}"
    eend $?
}

stop() {
    ebegin "Stopping ${name}"
    start-stop-daemon --stop \
        --pidfile "${pidfile}"
    eend $?
}
EOF

chmod +x "$SERVICE_FILE"

# ===== 启动服务 =====
mkdir -p /var/log/nodejs-argo

rc-update add nodejs-argo default
rc-service nodejs-argo start

log "✅ 安装完成！"

# ===== 等待服务启动 =====
sleep 5

# ===== 状态检查 =====
echo ""
echo "===== 服务状态 ====="
rc-service nodejs-argo status || true

echo ""
echo "===== 进程检查 ====="
ps aux | grep nodejs-argo | grep -v grep || echo "⚠️  未找到进程"

echo ""
echo "===== 端口检查 ====="
netstat -tuln | grep -E "${PORT}|${ARGO_PORT}" || echo "⚠️  端口未监听"

echo ""
echo "===== 管理命令 ====="
echo "查看日志: tail -f /var/log/nodejs-argo/output.log"
echo "查看错误: tail -f /var/log/nodejs-argo/error.log"
echo "查看状态: rc-service nodejs-argo status"
echo "停止服务: rc-service nodejs-argo stop"
echo "重启服务: rc-service nodejs-argo restart"
echo "编辑配置: vi /etc/nodejs-argo/config.env"

log "安装脚本执行完成"
