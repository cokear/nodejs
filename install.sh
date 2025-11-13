#!/bin/sh
# nodejs_argo_alpine.sh - Alpine Linux 版本 (支持开机自启动 + 修复哪吒)
# 适用于轻量级容器和 VPS 环境

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
    # v1 方式：NEZHA_SERVER 包含端口，NEZHA_PORT 留空
    if ! echo "$NEZHA_SERVER" | grep -q ":"; then
      printf "请输入端口（默认 443）: "
      read -r NEZHA_PORT_INPUT
      NEZHA_PORT_INPUT=${NEZHA_PORT_INPUT:-443}
      NEZHA_SERVER="${NEZHA_SERVER}:${NEZHA_PORT_INPUT}"
    fi
    NEZHA_PORT=""  # v1 必须留空
    printf "Nezha 密钥 (NZ_CLIENT_SECRET): "
    read -r NEZHA_KEY
    log "✅ 使用哪吒 v1，NEZHA_SERVER=$NEZHA_SERVER, NEZHA_PORT=(留空)"
  else
    NEZHA_VERSION="v0"
    # v0 方式：NEZHA_SERVER 不含端口，NEZHA_PORT 单独指定
    if echo "$NEZHA_SERVER" | grep -q ":"; then
      # 如果包含端口，拆分出来
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
    
    # 创建启动脚本
    START_SCRIPT="$WORKDIR/start_nodejs_argo.sh"
    cat > "$START_SCRIPT" <<EOF
#!/bin/sh
cd $PWD
export $ENV_VARS
screen -dmS nodejs-argo sh -c "$START_CMD"
EOF
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
    cat > "$START_SCRIPT" <<EOF
#!/bin/sh
cd $PWD
export $ENV_VARS
tmux new-session -d -s nodejs-argo "$START_CMD"
EOF
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
    
    # 创建 ecosystem 配置文件
    cat > "$PWD/ecosystem.config.js" <<EOF
module.exports = {
  apps: [{
    name: 'nodejs-argo',
    script: 'index.js',
    cwd: '$PWD',
    env: {
$(echo "$ENV_VARS" | tr ' ' '\n' | sed "s/^/      /;s/=/: '/;s/$/',/")
    },
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '500M'
  }]
};
EOF
    
    # PM2 启动
    pm2 start ecosystem.config.js
    pm2 save
    
    # 配置 PM2 自启动
    pm2 startup | grep -E "sudo|rc-update" | sh || true
    
    log "✅ PM2 自启动已配置"
    ;;
    
  4)
    log "启动: OpenRC (系统服务自启动)"
    SERVICE_FILE="/etc/init.d/nodejs-argo"
    
    # 生成环境变量字符串（去掉引号）
    ENV_EXPORTS=$(echo "$ENV_VARS" | sed "s/\([A-Z_]*\)='\?\([^']*\)'\?/export \1='\2'/g")
    
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="nodejs-argo"
description="NodeJS Argo Service"

command="/usr/bin/node"
command_args="$PWD/index.js"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
directory="$PWD"
output_log="/var/log/nodejs-argo/output.log"
error_log="/var/log/nodejs-argo/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    # 创建日志目录
    mkdir -p /var/log/nodejs-argo
    
    # 设置环境变量
$ENV_EXPORTS
}

start() {
    ebegin "Starting \${name}"
    start-stop-daemon --start \\
        --background \\
        --make-pidfile \\
        --pidfile "\${pidfile}" \\
        --stdout "\${output_log}" \\
        --stderr "\${error_log}" \\
        --exec "\${command}" \\
        -- \${command_args}
    eend \$?
}

stop() {
    ebegin "Stopping \${name}"
    start-stop-daemon --stop \\
        --pidfile "\${pidfile}"
    eend \$?
}

restart() {
    stop
    sleep 2
    start
}
EOF
    chmod +x "$SERVICE_FILE"
    
    # 创建日志目录
    mkdir -p /var/log/nodejs-argo
    
    # 添加到开机自启动
    rc-update add nodejs-argo default
    
    # 启动服务
    rc-service nodejs-argo start
    
    log "✅ OpenRC 服务已添加到开机自启动"
    ;;
esac

log "初始启动完成，等待服务启动..."
sleep 5

# ===== 8) 查找并显示日志 =====
log "查找日志文件..."
FOUND_LOGS=""

# 常见日志位置
for pattern in "$PWD/logs/*.log" "$PWD/*.log" "$PWD/tmp/*.log" "/var/log/nodejs-argo/*.log" "$HOME/.pm2/logs/*nodejs-argo*.log"; do
  for logfile in $pattern; do
    if [ -f "$logfile" ]; then
      FOUND_LOGS="$FOUND_LOGS\n  $logfile"
    fi
  done
done

if [ -n "$FOUND_LOGS" ]; then
  log "发现日志文件:$FOUND_LOGS"
  echo ""
  echo "===== 最近日志内容 ====="
  for logfile in $pattern; do
    if [ -f "$logfile" ]; then
      echo "--- $logfile (最后 20 行) ---"
      tail -20 "$logfile"
      echo ""
    fi
  done
else
  log "未找到日志文件，可能输出到 console"
fi

# ===== 9) 检查进程状态 =====
sleep 2
echo ""
echo "===== 进程状态检查 ====="
if pgrep -f "node.*index.js" >/dev/null; then
  PROCESS_INFO=$(ps aux | grep "node.*index.js" | grep -v grep)
  log "✅ Node.js 进程运行中:"
  echo "$PROCESS_INFO"
else
  log "⚠️  未检测到运行中的 node 进程"
fi

# 检查哪吒进程
if [ -n "$NEZHA_SERVER" ]; then
  echo ""
  echo "===== 哪吒 Agent 进程检查 ====="
  if pgrep -f "nezha\|agent" >/dev/null; then
    NEZHA_INFO=$(ps aux | grep -E "nezha|agent" | grep -v grep)
    log "✅ 哪吒 Agent 运行中:"
    echo "$NEZHA_INFO"
  else
    log "⚠️  未检测到哪吒 Agent 进程"
    log "请检查 tmp 目录中的哪吒二进制文件:"
    ls -lh "$PWD/tmp/" | grep -E "^[a-z]{6}$" || echo "未找到"
  fi
fi

# ===== 10) 输出节点信息快照 =====
echo ""
echo "===== 节点信息快照 ====="
echo "工作目录: $PWD"
echo "PORT: $PORT"
echo "ARGO_PORT: $ARGO_PORT"
echo "UUID: $UUID"
echo "FIX_DOMAIN: ${FIX_DOMAIN:-临时域名}"
if [ -n "$NEZHA_SERVER" ]; then
  echo "NEZHA 版本: $NEZHA_VERSION"
  echo "NEZHA_SERVER: $NEZHA_SERVER"
  echo "NEZHA_PORT: ${NEZHA_PORT:-(留空-使用v1)}"
  echo "NEZHA_KEY: ${NEZHA_KEY:0:10}..."
fi
echo "PROJECT_URL: ${PROJECT_URL}"
echo "UPLOAD_URL: ${UPLOAD_URL}"
echo "后台运行: $(case "$RUNNER" in 1)echo "Screen+Cron";;2)echo "Tmux+Cron";;3)echo "PM2";;4)echo "OpenRC";; esac)"
echo ""

# ===== 11) 健康检查 =====
echo "===== 健康检查 ====="
sleep 3

# 检查端口
if netstat -tuln 2>/dev/null | grep -q ":$PORT "; then
  echo "✅ HTTP 服务端口 $PORT 正在监听"
else
  echo "⚠️  HTTP 服务端口 $PORT 未监听"
fi

if netstat -tuln 2>/dev/null | grep -q ":$ARGO_PORT "; then
  echo "✅ Argo 隧道端口 $ARGO_PORT 正在监听"
else
  echo "⚠️  Argo 隧道端口 $ARGO_PORT 未监听"
fi

# 检查 HTTP 响应
if command -v curl >/dev/null 2>&1; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "✅ HTTP 服务响应正常 (HTTP $HTTP_CODE)"
  else
    echo "⚠️  HTTP 服务响应异常 (HTTP $HTTP_CODE)"
  fi
fi

# ===== 12) 订阅信息 =====
echo ""
echo "===== 订阅信息 ====="
# 等待订阅文件生成
sleep 5

SUB_FILE="$PWD/tmp/sub.txt"
if [ -f "$SUB_FILE" ]; then
  echo "📄 订阅文件位置: $SUB_FILE"
  echo "📋 订阅内容 (Base64):"
  cat "$SUB_FILE"
  echo ""
  echo "📋 订阅内容 (解码):"
  cat "$SUB_FILE" | base64 -d
else
  echo "⚠️  未找到 sub.txt 订阅文件"
  echo "🔍 查找所有 txt 文件:"
  find "$PWD" -name "*.txt" -type f 2>/dev/null | head -10 || echo "未找到任何 txt 文件"
fi

# ===== 13) 自启动验证 =====
echo ""
echo "===== 自启动配置验证 ====="
case "$RUNNER" in
  1|2)
    echo "✅ Crontab 自启动任务:"
    crontab -l 2>/dev/null | grep nodejs-argo || echo "⚠️  未找到"
    ;;
  3)
    echo "✅ PM2 自启动状态:"
    pm2 list 2>/dev/null || echo "⚠️  PM2 未运行"
    ;;
  4)
    echo "✅ OpenRC 自启动状态:"
    rc-status default | grep nodejs-argo || echo "⚠️  未在 default 运行级别"
    echo ""
    echo "✅ 服务状态:"
    rc-service nodejs-argo status || true
    ;;
esac

echo ""
echo "===== 管理命令 ====="
case "$RUNNER" in
  1)
    echo "查看日志: screen -r nodejs-argo"
    echo "分离会话: Ctrl+A 然后按 D"
    echo "停止服务: screen -S nodejs-argo -X quit"
    echo "重启服务: $START_SCRIPT"
    echo "查看自启动: crontab -l | grep nodejs-argo"
    ;;
  2)
    echo "查看日志: tmux attach -t nodejs-argo"
    echo "分离会话: Ctrl+B 然后按 D"
    echo "停止服务: tmux kill-session -t nodejs-argo"
    echo "重启服务: $START_SCRIPT"
    echo "查看自启动: crontab -l | grep nodejs-argo"
    ;;
  3)
    echo "查看日志: pm2 logs nodejs-argo"
    echo "查看状态: pm2 status"
    echo "停止服务: pm2 stop nodejs-argo"
    echo "重启服务: pm2 restart nodejs-argo"
    echo "查看配置: cat $PWD/ecosystem.config.js"
    ;;
  4)
    echo "查看状态: rc-service nodejs-argo status"
    echo "查看日志: tail -f /var/log/nodejs-argo/output.log"
    echo "查看错误: tail -f /var/log/nodejs-argo/error.log"
    echo "停止服务: rc-service nodejs-argo stop"
    echo "重启服务: rc-service nodejs-argo restart"
    echo "查看自启动: rc-status default | grep nodejs-argo"
    echo "查看配置: cat /etc/init.d/nodejs-argo"
    ;;
esac

echo ""
echo "===== 故障排查命令 ====="
echo "查看进程: ps aux | grep node"
echo "查看端口: netstat -tuln | grep -E '$PORT|$ARGO_PORT'"
echo "查看哪吒进程: ps aux | grep -E 'nezha|agent'"
echo "查看 tmp 目录: ls -lh $PWD/tmp/"
echo "手动测试 HTTP: curl -I http://localhost:$PORT"

echo ""
echo "===== 测试重启后自启动 ====="
echo "1. 重启系统: reboot"
echo "2. 重启后等待 15 秒"
echo "3. 验证服务: ps aux | grep node"
echo "4. 验证端口: netstat -tuln | grep $PORT"

echo ""
log "✅ 安装完成！已配置开机自启动（方式: $RUNNER）"
log "如果服务未启动，请查看日志: tail -f /var/log/nodejs-argo/*.log"
