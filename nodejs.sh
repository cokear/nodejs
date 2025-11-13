#!/bin/sh
# nodejs_argo_alpine.sh - NodeJS Argo 一键安装脚本（Alpine Linux）
# 支持安装和卸载

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
  
  # 检查并停止服务
  if [ -f /etc/init.d/nodejs-argo ]; then
    log "停止并删除服务..."
    rc-service nodejs-argo stop 2>/dev/null || log "服务未运行"
    rc-update del nodejs-argo default 2>/dev/null || log "服务未在启动项中"
    rm -f /etc/init.d/nodejs-argo
    log "✓ 服务已删除"
  else
    log "⚠️  服务配置文件不存在，跳过"
  fi
  
  # 检查并停止进程
  if pgrep -f nodejs-argo > /dev/null; then
    log "发现运行中的进程，正在停止..."
    pkill -9 -f nodejs-argo || true
    log "✓ 进程已停止"
  else
    log "⚠️  未发现运行中的进程"
  fi
  
  # 卸载 npm 包
  if npm list -g nodejs-argo > /dev/null 2>&1; then
    log "卸载 npm 全局包..."
    npm uninstall -g nodejs-argo
    log "✓ npm 包已卸载"
  else
    log "⚠️  npm 包未安装或已被删除"
  fi
  
  # 删除配置文件和日志
  if [ -d /etc/nodejs-argo ]; then
    log "删除配置目录..."
    rm -rf /etc/nodejs-argo
    log "✓ 配置目录已删除"
  fi
  
  if [ -d /var/log/nodejs-argo ]; then
    log "删除日志目录..."
    rm -rf /var/log/nodejs-argo
    log "✓ 日志目录已删除"
  fi
  
  # 清理工作目录（如果存在）
  if [ -d /opt/nodejs-argo ]; then
    log "删除工作目录..."
    rm -rf /opt/nodejs-argo
    log "✓ 工作目录已删除"
  fi
  
  log "========================================="
  log "✅ 卸载完成！已清理："
  log "  - OpenRC 服务"
  log "  - 运行进程"
  log "  - npm 全局包"
  log "  - 配置文件 (/etc/nodejs-argo)"
  log "  - 日志文件 (/var/log/nodejs-argo)"
  log "  - 工作目录 (/opt/nodejs-argo)"
  log "========================================="
  
  exit 0
fi

log "开始安装流程"

# ===== 检查是否已安装 =====
if npm list -g nodejs-argo > /dev/null 2>&1; then
  log "⚠️  检测到 nodejs-argo 已安装"
  printf "是否重新安装？(y/N): "
  read -r REINSTALL
  if [ "$REINSTALL" = "y" ] || [ "$REINSTALL" = "Y" ]; then
    log "卸载旧版本..."
    npm uninstall -g nodejs-argo
  else
    log "取消安装"
    exit 0
  fi
fi

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

# 验证安装
if ! command -v nodejs-argo > /dev/null 2>&1; then
  log "❌ 安装失败：找不到 nodejs-argo 命令"
  log "请检查 npm 包名是否正确"
  exit 1
fi

log "✓ nodejs-argo 已成功安装到: $(which nodejs-argo)"

# ===== 配置参数 =====
log "配置环境变量..."

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

cat > "$SERVICE_FILE" <<'EOFSERVICE'
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
        export PORT ARGO_PORT UUID ARGO_DOMAIN ARGO_AUTH NEZHA_SERVER NEZHA_PORT NEZHA_KEY
    fi
    
    # 检查命令是否存在
    if ! command -v nodejs-argo > /dev/null 2>&1; then
        eerror "nodejs-argo command not found"
        return 1
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
        --pidfile "${pidfile}" \
        --retry 15
    eend $?
}

status() {
    if [ -f "${pidfile}" ]; then
        PID=$(cat "${pidfile}")
        if kill -0 "$PID" 2>/dev/null; then
            einfo "${name} is running (PID: $PID)"
            return 0
        else
            eerror "${name} is not running but pidfile exists"
            return 1
        fi
    else
        eerror "${name} is not running"
        return 3
    fi
}
EOFSERVICE

chmod +x "$SERVICE_FILE"
log "OpenRC 服务已创建"

# ===== 启动服务 =====
mkdir -p /var/log/nodejs-argo

log "添加服务到启动项..."
rc-update add nodejs-argo default

log "启动服务..."
rc-service nodejs-argo start

log "✅ 安装完成！"

# ===== 等待服务启动 =====
sleep 5

# ===== 状态检查 =====
echo ""
echo "========================================="
echo "===== 服务状态 ====="
rc-service nodejs-argo status || echo "⚠️  服务状态检查失败"

echo ""
echo "===== 进程检查 ====="
if pgrep -f nodejs-argo > /dev/null; then
  ps aux | grep nodejs-argo | grep -v grep
else
  echo "⚠️  未找到运行进程"
fi

echo ""
echo "===== 端口检查 ====="
netstat -tuln | grep -E "${PORT}|${ARGO_PORT}" || echo "⚠️  端口未监听"

echo ""
echo "===== 配置信息 ====="
cat /etc/nodejs-argo/config.env

echo ""
echo "===== 日志预览（最后20行）====="
if [ -f /var/log/nodejs-argo/output.log ]; then
  tail -20 /var/log/nodejs-argo/output.log
else
  echo "日志文件尚未生成"
fi

echo ""
echo "===== 管理命令 ====="
echo "查看实时日志: tail -f /var/log/nodejs-argo/output.log"
echo "查看错误日志: tail -f /var/log/nodejs-argo/error.log"
echo "查看服务状态: rc-service nodejs-argo status"
echo "停止服务: rc-service nodejs-argo stop"
echo "启动服务: rc-service nodejs-argo start"
echo "重启服务: rc-service nodejs-argo restart"
echo "编辑配置: vi /etc/nodejs-argo/config.env"
echo "重新加载配置: rc-service nodejs-argo restart"
echo "卸载程序: sh $0 (选择选项 2)"
echo "========================================="

log "安装脚本执行完成"
