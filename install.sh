#!/bin/bash
# nodejs_argo_universal.sh - 通用版本（支持多系统 + 哪吒 + 开机自启动）
# 支持系统：
# - Debian/Ubuntu (systemd/sysvinit)
# - Alpine Linux (OpenRC)
# - CentOS/RHEL/Rocky/Alma (systemd)
# - Arch Linux (systemd)
# - OpenWRT (procd)

set -e

LOGFILE="/var/log/nodejs_argo_install.log"
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || LOGFILE="/tmp/nodejs_argo_install.log"

log() {
  msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" | tee -a "$LOGFILE"
}

log "开始 NodeJS Argo 通用安装脚本"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 🔍 系统检测
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

detect_system() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
  elif [ -f /etc/alpine-release ]; then
    OS="alpine"
    OS_VERSION=$(cat /etc/alpine-release)
  else
    OS=$(uname -s)
    OS_VERSION=$(uname -r)
  fi
  
  # 检测初始化系统
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    INIT_SYSTEM="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
  elif command -v service >/dev/null 2>&1; then
    INIT_SYSTEM="sysvinit"
  elif [ -d /etc/init.d ] && [ -x /etc/init.d/rcS ]; then
    INIT_SYSTEM="procd"  # OpenWRT
  else
    INIT_SYSTEM="unknown"
  fi
  
  log "检测到系统: $OS $OS_VERSION"
  log "初始化系统: $INIT_SYSTEM"
}

detect_system

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 📦 包管理器检测
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum update -y"
    PKG_INSTALL="yum install -y"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf update -y"
    PKG_INSTALL="dnf install -y"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    PKG_UPDATE="pacman -Sy"
    PKG_INSTALL="pacman -S --noconfirm"
  elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
    PKG_UPDATE="opkg update"
    PKG_INSTALL="opkg install"
  else
    log "错误: 未检测到支持的包管理器"
    exit 1
  fi
  
  log "包管理器: $PKG_MANAGER"
}

detect_package_manager

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 🎬 选择操作
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

printf "请选择操作 1) 安装 2) 卸载（默认 1）: "
read -r ACTION
ACTION=${ACTION:-1}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 🗑️ 卸载流程
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "$ACTION" = "2" ]; then
  log "开始卸载流程"

  # 停止服务（根据初始化系统）
  case "$INIT_SYSTEM" in
    systemd)
      systemctl stop nodejs-argo 2>/dev/null || true
      systemctl disable nodejs-argo 2>/dev/null || true
      rm -f /etc/systemd/system/nodejs-argo.service
      systemctl daemon-reload
      ;;
    openrc)
      rc-service nodejs-argo stop 2>/dev/null || true
      rc-update del nodejs-argo default 2>/dev/null || true
      rm -f /etc/init.d/nodejs-argo
      ;;
    sysvinit)
      service nodejs-argo stop 2>/dev/null || true
      update-rc.d -f nodejs-argo remove 2>/dev/null || true
      chkconfig nodejs-argo off 2>/dev/null || true
      rm -f /etc/init.d/nodejs-argo
      ;;
    procd)
      /etc/init.d/nodejs-argo stop 2>/dev/null || true
      /etc/init.d/nodejs-argo disable 2>/dev/null || true
      rm -f /etc/init.d/nodejs-argo
      ;;
  esac

  # 停止 PM2
  if command -v pm2 >/dev/null 2>&1; then
    pm2 list 2>/dev/null | grep -q nodejs-argo && pm2 delete nodejs-argo || true
    pm2 save
    pm2 unstartup 2>/dev/null || true
  fi

  # 停止 screen/tmux
  screen -S nodejs-argo -X quit 2>/dev/null || true
  tmux kill-session -t nodejs-argo 2>/dev/null || true

  # 删除 crontab
  (crontab -l 2>/dev/null | grep -v "nodejs-argo") | crontab - || true

  # 停止进程
  pkill -f "node.*index.js" || true

  # 删除安装目录
  rm -rf /opt/nodejs-argo

  log "卸载完成"
  exit 0
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 📝 配置参数
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "开始配置安装参数"

printf "工作目录（默认 /opt/nodejs-argo）: "
read -r WORKDIR
WORKDIR=${WORKDIR:-/opt/nodejs-argo}
mkdir -p "$WORKDIR"
cd "$WORKDIR"
log "工作目录: $WORKDIR"

printf "HTTP 服务端口 PORT（默认 3000）: "
read -r PORT
PORT=${PORT:-3000}

printf "Argo 隧道端口 ARGO_PORT（默认 8001）: "
read -r ARGO_PORT
ARGO_PORT=${ARGO_PORT:-8001}

printf "UUID（默认 865c9c45-145e-40f4-aa59-1aa5ac212f5e）: "
read -r UUID
UUID=${UUID:-865c9c45-145e-40f4-aa59-1aa5ac212f5e}

printf "是否使用固定隧道？输入固定域名，若不使用请直接回车: "
read -r FIX_DOMAIN
FIX_DOMAIN=${FIX_DOMAIN:-}
ARGO_AUTH=""
if [ -n "$FIX_DOMAIN" ]; then
  printf "固定隧道鉴权 ARGO_AUTH: "
  read -r ARGO_AUTH
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 🔧 哪吒配置
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

printf "NEZHA 服务地址（格式: nz.example.com:443），若不配置直接回车: "
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
    log "✅ 使用哪吒 v1"
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
    log "✅ 使用哪吒 v0"
  fi
fi

printf "UPLOAD_URL 订阅上传地址（可选）: "
read -r UPLOAD_URL
printf "PROJECT_URL 项目域名地址（默认 https://www.google.com）: "
read -r PROJECT_URL
PROJECT_URL=${PROJECT_URL:-https://www.google.com}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 📦 安装依赖
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

install_dependencies() {
  log "安装系统依赖..."
  $PKG_UPDATE
  
  case "$PKG_MANAGER" in
    apt)
      $PKG_INSTALL curl ca-certificates git jq screen tmux bash net-tools procps
      ;;
    apk)
      $PKG_INSTALL curl ca-certificates git jq screen tmux bash nodejs npm openrc dcron net-tools
      rc-update add dcron default 2>/dev/null || true
      rc-update add local default 2>/dev/null || true
      ;;
    yum|dnf)
      $PKG_INSTALL curl ca-certificates git jq screen tmux bash net-tools procps-ng
      ;;
    pacman)
      $PKG_INSTALL curl ca-certificates git jq screen tmux bash net-tools procps-ng
      ;;
    opkg)
      $PKG_INSTALL curl ca-certificates git-http jq screen tmux bash
      ;;
  esac
}

install_nodejs() {
  if command -v node >/dev/null 2>&1; then
    log "Node.js 已安装: $(node -v)"
    return
  fi
  
  log "安装 Node.js..."
  
  case "$PKG_MANAGER" in
    apt)
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      $PKG_INSTALL nodejs
      ;;
    apk)
      # Alpine 已在前面安装
      ;;
    yum|dnf)
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
      $PKG_INSTALL nodejs
      ;;
    pacman)
      $PKG_INSTALL nodejs npm
      ;;
    opkg)
      $PKG_INSTALL node node-npm
      ;;
  esac
  
  log "Node.js 安装完成: $(node -v)"
}

install_dependencies
install_nodejs

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 📂 获取项目
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ ! -d nodejs-argo ]; then
  log "克隆项目仓库..."
  git clone https://github.com/cokear/nodejs.git nodejs-argo
fi
cd nodejs-argo

if [ -f package.json ]; then
  log "安装 npm 依赖..."
  npm install --production
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 🔧 构建环境变量
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ENV_VARS="PORT=${PORT} ARGO_PORT=${ARGO_PORT} UUID=${UUID}"

if [ -n "$FIX_DOMAIN" ]; then
  ENV_VARS="$ENV_VARS ARGO_DOMAIN=${FIX_DOMAIN}"
  [ -n "$ARGO_AUTH" ] && ENV_VARS="$ENV_VARS ARGO_AUTH='${ARGO_AUTH}'"
fi

if [ -n "$NEZHA_SERVER" ]; then
  ENV_VARS="$ENV_VARS NEZHA_SERVER=${NEZHA_SERVER}"
  [ -n "$NEZHA_PORT" ] && ENV_VARS="$ENV_VARS NEZHA_PORT=${NEZHA_PORT}"
  [ -n "$NEZHA_KEY" ] && ENV_VARS="$ENV_VARS NEZHA_KEY=${NEZHA_KEY}"
fi

ENV_VARS="$ENV_VARS UPLOAD_URL='${UPLOAD_URL:-}' PROJECT_URL=${PROJECT_URL}"

log "环境变量配置完成"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 🚀 选择运行方式
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

printf "后台运行方式：1) screen+cron 2) tmux+cron 3) pm2 4) 系统服务（推荐）（默认 4）: "
read -r RUNNER
RUNNER=${RUNNER:-4}

START_CMD="node index.js"

case "$RUNNER" in
  1|2)
    # Screen/Tmux + Cron
    SESSION_TYPE=$([ "$RUNNER" = "1" ] && echo "screen" || echo "tmux")
    START_SCRIPT="$WORKDIR/start_nodejs_argo.sh"
    
    cat > "$START_SCRIPT" <<EOF
#!/bin/bash
cd $PWD
export $ENV_VARS
$([ "$RUNNER" = "1" ] && echo "screen -dmS nodejs-argo sh -c '$START_CMD'" || echo "tmux new-session -d -s nodejs-argo '$START_CMD'")
EOF
    chmod +x "$START_SCRIPT"
    
    (crontab -l 2>/dev/null | grep -v "nodejs-argo"; echo "@reboot sleep 10 && $START_SCRIPT") | crontab -
    
    # 立即启动
    if [ "$RUNNER" = "1" ]; then
      screen -dmS nodejs-argo sh -c "export $ENV_VARS; $START_CMD"
    else
      tmux new-session -d -s nodejs-argo "export $ENV_VARS; $START_CMD"
    fi
    
    log "✅ 已配置 $SESSION_TYPE + cron 自启动"
    ;;
    
  3)
    # PM2
    if ! command -v pm2 >/dev/null 2>&1; then
      npm install -g pm2
    fi
    
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
    
    pm2 start ecosystem.config.js
    pm2 save
    pm2 startup | grep -E "sudo|rc-update" | sh || true
    
    log "✅ PM2 自启动已配置"
    ;;
    
  4)
    # 系统服务
    log "配置系统服务..."
    ENV_EXPORTS=$(echo "$ENV_VARS" | sed "s/\([A-Z_]*\)='\?\([^']*\)'\?/export \1='\2'/g")
    
    case "$INIT_SYSTEM" in
      systemd)
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
ExecStart=/usr/bin/node $PWD/index.js
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
        log "✅ Systemd 服务已配置"
        ;;
        
      openrc)
        SERVICE_FILE="/etc/init.d/nodejs-argo"
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
    mkdir -p /var/log/nodejs-argo
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
    start-stop-daemon --stop --pidfile "\${pidfile}"
    eend \$?
}
EOF
        chmod +x "$SERVICE_FILE"
        mkdir -p /var/log/nodejs-argo
        rc-update add nodejs-argo default
        rc-service nodejs-argo start
        log "✅ OpenRC 服务已配置"
        ;;
        
      sysvinit)
        SERVICE_FILE="/etc/init.d/nodejs-argo"
        cat > "$SERVICE_FILE" <<EOF
#!/bin/bash
### BEGIN INIT INFO
# Provides:          nodejs-argo
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: NodeJS Argo Service
### END INIT INFO

PIDFILE=/var/run/nodejs-argo.pid
WORKDIR=$PWD
LOGDIR=/var/log/nodejs-argo

start() {
    mkdir -p \$LOGDIR
    cd \$WORKDIR
    $ENV_EXPORTS
    nohup /usr/bin/node index.js >> \$LOGDIR/output.log 2>> \$LOGDIR/error.log &
    echo \$! > \$PIDFILE
    echo "NodeJS Argo started"
}

stop() {
    if [ -f \$PIDFILE ]; then
        kill \$(cat \$PIDFILE)
        rm -f \$PIDFILE
        echo "NodeJS Argo stopped"
    fi
}

case "\$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 2; start ;;
    *) echo "Usage: \$0 {start|stop|restart}"; exit 1 ;;
esac
EOF
        chmod +x "$SERVICE_FILE"
        mkdir -p /var/log/nodejs-argo
        
        if command -v update-rc.d >/dev/null 2>&1; then
          update-rc.d nodejs-argo defaults
        elif command -v chkconfig >/dev/null 2>&1; then
          chkconfig --add nodejs-argo
          chkconfig nodejs-argo on
        fi
        
        service nodejs-argo start
        log "✅ SysVinit 服务已配置"
        ;;
        
      procd)
        SERVICE_FILE="/etc/init.d/nodejs-argo"
        cat > "$SERVICE_FILE" <<EOF
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/node $PWD/index.js
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param env $ENV_VARS
    procd_close_instance
}
EOF
        chmod +x "$SERVICE_FILE"
        /etc/init.d/nodejs-argo enable
        /etc/init.d/nodejs-argo start
        log "✅ Procd 服务已配置（OpenWRT）"
        ;;
    esac
    ;;
esac

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ✅ 健康检查
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "等待服务启动..."
sleep 5

echo ""
echo "===== 系统信息 ====="
echo "操作系统: $OS $OS_VERSION"
echo "初始化系统: $INIT_SYSTEM"
echo "包管理器: $PKG_MANAGER"
echo "Node.js: $(node -v)"
echo ""

echo "===== 服务状态 ====="
if pgrep -f "node.*index.js" >/dev/null; then
  echo "✅ Node.js 进程运行中"
  ps aux | grep "node.*index.js" | grep -v grep
else
  echo "⚠️  Node.js 进程未运行"
fi

if [ -n "$NEZHA_SERVER" ]; then
  echo ""
  if pgrep -f "nezha\|agent\|[a-z]{6}" >/dev/null; then
    echo "✅ 哪吒 Agent 运行中"
  else
    echo "⚠️  哪吒 Agent 未运行"
  fi
fi

echo ""
echo "===== 端口检查 ====="
if command -v netstat >/dev/null 2>&1; then
  netstat -tuln 2>/dev/null | grep -E ":$PORT |:$ARGO_PORT " || echo "⚠️  端口未监听"
elif command -v ss >/dev/null 2>&1; then
  ss -tuln | grep -E ":$PORT |:$ARGO_PORT " || echo "⚠️  端口未监听"
fi

echo ""
echo "===== 订阅信息 ====="
sleep 5
SUB_FILE="$PWD/tmp/sub.txt"
if [ -f "$SUB_FILE" ]; then
  echo "📄 订阅文件: $SUB_FILE"
  cat "$SUB_FILE" | base64 -d 2>/dev/null || cat "$SUB_FILE"
else
  echo "⚠️  订阅文件未生成"
fi

echo ""
echo "===== 管理命令 ====="
case "$INIT_SYSTEM" in
  systemd)
    echo "查看状态: systemctl status nodejs-argo"
    echo "查看日志: journalctl -u nodejs-argo -f"
    echo "重启服务: systemctl restart nodejs-argo"
    ;;
  openrc)
    echo "查看状态: rc-service nodejs-argo status"
    echo "查看日志: tail -f /var/log/nodejs-argo/output.log"
    echo "重启服务: rc-service nodejs-argo restart"
    ;;
  sysvinit)
    echo "查看状态: service nodejs-argo status"
    echo "查看日志: tail -f /var/log/nodejs-argo/output.log"
    echo "重启服务: service nodejs-argo restart"
    ;;
  procd)
    echo "查看状态: /etc/init.d/nodejs-argo status"
    echo "查看日志: logread | grep nodejs"
    echo "重启服务: /etc/init.d/nodejs-argo restart"
    ;;
esac

echo ""
log "✅ 安装完成！系统: $OS, 初始化: $INIT_SYSTEM"
