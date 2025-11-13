#!/bin/bash
# nodejs-argo 管理脚本 Part 1/3
# 支持系统: Alpine, Ubuntu/Debian

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOGFILE="/var/log/nodejs_argo_install.log"
mkdir -p "$(dirname "$LOGFILE")"

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOGFILE"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOGFILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOGFILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOGFILE"
}

log_title() {
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=========================================${NC}"
}

# 检测系统类型
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
        VERSION=$(cat /etc/alpine-release)
    else
        log_error "无法检测系统类型"
        exit 1
    fi
    log_info "检测到系统: $OS $VERSION"
}

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# ==================== 卸载相关函数 ====================

# 停止并删除systemd服务
remove_systemd_service() {
    if [ -f /etc/systemd/system/nodejs-argo.service ]; then
        log_info "停止并删除 systemd 服务..."
        systemctl stop nodejs-argo.service 2>/dev/null || true
        systemctl disable nodejs-argo.service 2>/dev/null || true
        rm -f /etc/systemd/system/nodejs-argo.service
        systemctl daemon-reload
        log_info "✅ systemd 服务已删除"
    fi
}

# 停止并删除OpenRC服务
remove_openrc_service() {
    if [ -f /etc/init.d/nodejs-argo ]; then
        log_info "停止并删除 OpenRC 服务..."
        rc-service nodejs-argo stop 2>/dev/null || true
        rc-update del nodejs-argo default 2>/dev/null || true
        rm -f /etc/init.d/nodejs-argo
        log_info "✅ OpenRC 服务已删除"
    fi
}

# 停止 PM2
remove_pm2_service() {
    if command -v pm2 >/dev/null 2>&1; then
        if pm2 list 2>/dev/null | grep -q nodejs-argo; then
            log_info "停止 PM2 应用 nodejs-argo"
            pm2 stop nodejs-argo 2>/dev/null || true
            pm2 delete nodejs-argo 2>/dev/null || true
            pm2 save 2>/dev/null || true
            pm2 unstartup 2>/dev/null || true
            log_info "✅ PM2 服务已删除"
        fi
    fi
}

# 停止 screen
remove_screen_service() {
    if screen -ls 2>/dev/null | grep -q "nodejs-argo"; then
        log_info "结束 screen 会话 nodejs-argo"
        screen -S nodejs-argo -X quit 2>/dev/null || true
        log_info "✅ Screen 会话已结束"
    fi
}

# 停止 tmux
remove_tmux_service() {
    if command -v tmux >/dev/null 2>&1; then
        if tmux ls 2>/dev/null | grep -q "nodejs-argo"; then
            log_info "结束 tmux 会话 nodejs-argo"
            tmux kill-session -t nodejs-argo 2>/dev/null || true
            log_info "✅ Tmux 会话已结束"
        fi
    fi
}

# 删除 crontab 自启动
remove_crontab() {
    if command -v crontab >/dev/null 2>&1; then
        log_info "删除 crontab 自启动任务"
        crontab -l 2>/dev/null | grep -v "nodejs-argo" | crontab - 2>/dev/null || true
        log_info "✅ Crontab 任务已清理"
    fi
}

# 卸载 nodejs-argo npm 包
uninstall_npm_package() {
    log_info "卸载 nodejs-argo npm 包..."
    if command -v npm >/dev/null 2>&1; then
        if npm list -g nodejs-argo &> /dev/null; then
            npm uninstall -g nodejs-argo
            log_info "✅ nodejs-argo npm 包已卸载"
        else
            log_warn "nodejs-argo 未通过 npm 全局安装"
        fi
    fi
}

# 清理残留文件
cleanup_files() {
    log_info "清理残留文件..."
    
    # 停止进程
    pkill -f "nodejs-argo" 2>/dev/null || true
    pkill -f "node.*index.js" 2>/dev/null || true
    pkill -f "nezha" 2>/dev/null || true
    pkill -f "agent" 2>/dev/null || true
    
    # 移除安装目录
    for dir in /opt/nodejs-argo /root/nodejs-argo /home/*/nodejs-argo; do
        if [ -d "$dir" ]; then
            log_info "删除目录: $dir"
            rm -rf "$dir"
        fi
    done
    
    # 清理 npm 全局目录
    for dir in /usr/local/lib/node_modules/nodejs-argo /usr/lib/node_modules/nodejs-argo; do
        if [ -d "$dir" ]; then
            log_info "删除目录: $dir"
            rm -rf "$dir"
        fi
    done
    
    # 清理二进制链接
    for bin in /usr/local/bin/nodejs-argo /usr/bin/nodejs-argo; do
        if [ -f "$bin" ] || [ -L "$bin" ]; then
            log_info "删除文件: $bin"
            rm -f "$bin"
        fi
    done
    
    # 移除服务文件
    rm -f /etc/init.d/nodejs-argo
    rm -f /etc/local.d/nodejs-argo.start
    
    # 移除日志
    if [ -d /var/log/nodejs-argo ]; then
        log_info "删除日志目录: /var/log/nodejs-argo"
        rm -rf /var/log/nodejs-argo
    fi
    
    log_info "✅ 残留文件已清理"
}

# 询问是否卸载Node.js
ask_uninstall_nodejs() {
    echo
    read -p "是否同时卸载 Node.js 和 npm? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        case $OS in
            alpine)
                log_info "卸载 Node.js 和 npm (Alpine)..."
                apk del nodejs npm 2>/dev/null || true
                ;;
            ubuntu|debian)
                log_info "卸载 Node.js 和 npm (Ubuntu/Debian)..."
                apt-get remove -y nodejs npm 2>/dev/null || true
                apt-get autoremove -y 2>/dev/null || true
                ;;
        esac
        log_info "✅ Node.js 和 npm 已卸载"
    else
        log_info "保留 Node.js 和 npm"
    fi
}

# 执行卸载
do_uninstall() {
    log_title "开始卸载 nodejs-argo"
    
    check_root
    detect_system
    
    # 停止所有服务
    case $OS in
        alpine)
            remove_openrc_service
            ;;
        ubuntu|debian)
            remove_systemd_service
            ;;
    esac
    
    remove_pm2_service
    remove_screen_service
    remove_tmux_service
    remove_crontab
    
    # 卸载 npm 包
    uninstall_npm_package
    
    # 清理文件
    cleanup_files
    
    # 询问是否卸载Node.js
    ask_uninstall_nodejs
    
    echo
    log_title "nodejs-argo 卸载完成！"
    echo
}

# ==================== 安装相关函数 ====================

# 收集配置参数
collect_config() {
    log_title "配置参数设置"
    
    # 工作目录
    read -p "工作目录（默认 /opt/nodejs-argo）: " WORKDIR
    WORKDIR=${WORKDIR:-/opt/nodejs-argo}
    
    # HTTP 服务端口
    read -p "HTTP 服务端口 PORT（默认 3000）: " PORT
    PORT=${PORT:-3000}
    
    # Argo 隧道端口
    read -p "Argo 隧道端口 ARGO_PORT（默认 8001）: " ARGO_PORT
    ARGO_PORT=${ARGO_PORT:-8001}
    
    # UUID
    read -p "UUID（默认 865c9c45-145e-40f4-aa59-1aa5ac212f5e）: " UUID
    UUID=${UUID:-865c9c45-145e-40f4-aa59-1aa5ac212f5e}
    
    # 固定隧道
    read -p "是否使用固定隧道？输入固定域名（如 frr.example.com），留空则使用临时域名: " FIX_DOMAIN
    FIX_DOMAIN=${FIX_DOMAIN:-}
    ARGO_AUTH=""
    if [ -n "$FIX_DOMAIN" ]; then
        read -p "固定隧道鉴权 ARGO_AUTH: " ARGO_AUTH
    fi
    
    # 哪吒配置
    echo
    log_info "=== 配置哪吒监控（可选）==="
    read -p "NEZHA 服务地址（格式: nz.example.com:443 或 nz.example.com），留空跳过: " NEZHA_SERVER
    NEZHA_SERVER=${NEZHA_SERVER:-}
    NEZHA_PORT=""
    NEZHA_KEY=""
    NEZHA_VERSION=""
    
    if [ -n "$NEZHA_SERVER" ]; then
        read -p "选择哪吒版本：1) v1（推荐） 2) v0（默认 1）: " NEZHA_VERSION_CHOICE
        NEZHA_VERSION_CHOICE=${NEZHA_VERSION_CHOICE:-1}
        
        if [ "$NEZHA_VERSION_CHOICE" = "1" ]; then
            NEZHA_VERSION="v1"
            if ! echo "$NEZHA_SERVER" | grep -q ":"; then
                read -p "请输入端口（默认 443）: " NEZHA_PORT_INPUT
                NEZHA_PORT_INPUT=${NEZHA_PORT_INPUT:-443}
                NEZHA_SERVER="${NEZHA_SERVER}:${NEZHA_PORT_INPUT}"
            fi
            NEZHA_PORT=""
            read -p "Nezha 密钥 (NZ_CLIENT_SECRET): " NEZHA_KEY
            log_info "✅ 使用哪吒 v1，NEZHA_SERVER=$NEZHA_SERVER"
        else
            NEZHA_VERSION="v0"
            if echo "$NEZHA_SERVER" | grep -q ":"; then
                NEZHA_PORT=$(echo "$NEZHA_SERVER" | cut -d: -f2)
                NEZHA_SERVER=$(echo "$NEZHA_SERVER" | cut -d: -f1)
            else
                read -p "请输入端口（默认 5555）: " NEZHA_PORT
                NEZHA_PORT=${NEZHA_PORT:-5555}
            fi
            read -p "Nezha Agent 密钥: " NEZHA_KEY
            log_info "✅ 使用哪吒 v0，NEZHA_SERVER=$NEZHA_SERVER, NEZHA_PORT=$NEZHA_PORT"
        fi
    fi
    
    # 其他配置
    read -p "UPLOAD_URL 订阅上传地址（可选，留空跳过）: " UPLOAD_URL
    UPLOAD_URL=${UPLOAD_URL:-}
    
    read -p "PROJECT_URL 项目域名地址（默认 https://www.google.com）: " PROJECT_URL
    PROJECT_URL=${PROJECT_URL:-https://www.google.com}
    
    # 后台运行方式
    echo
    log_info "选择后台运行方式"
    case $OS in
        alpine)
            read -p "后台运行方式：1) screen+cron 2) tmux+cron 3) pm2 4) openrc（默认 4）: " RUNNER
            RUNNER=${RUNNER:-4}
            ;;
        ubuntu|debian)
            read -p "后台运行方式：1) screen+cron 2) tmux+cron 3) pm2 4) systemd（默认 4）: " RUNNER
            RUNNER=${RUNNER:-4}
            ;;
    esac
    
    echo
    log_info "配置摘要:"
    log_info "  工作目录: $WORKDIR"
    log_info "  HTTP 端口: $PORT"
    log_info "  Argo 端口: $ARGO_PORT"
    log_info "  UUID: $UUID"
    log_info "  固定域名: ${FIX_DOMAIN:-临时域名}"
    if [ -n "$NEZHA_SERVER" ]; then
        log_info "  哪吒版本: $NEZHA_VERSION"
        log_info "  哪吒服务器: $NEZHA_SERVER"
        [ -n "$NEZHA_PORT" ] && log_info "  哪吒端口: $NEZHA_PORT"
    fi
    log_info "  项目地址: $PROJECT_URL"
    [ -n "$UPLOAD_URL" ] && log_info "  上传地址: $UPLOAD_URL"
    echo
}

# 安装依赖 (Alpine)
install_deps_alpine() {
    log_info "安装依赖与 Node.js 环境 (Alpine)..."
    apk update
    apk add --no-cache \
        curl ca-certificates git jq screen tmux bash \
        nodejs npm openrc dcron net-tools
    
    rc-update add dcron default 2>/dev/null || true
    rc-update add local default 2>/dev/null || true
    
    log_info "✅ 依赖安装完成"
}

# 安装依赖 (Ubuntu/Debian)
install_deps_ubuntu() {
    log_info "安装依赖与 Node.js 环境 (Ubuntu/Debian)..."
    apt-get update
    apt-get install -y curl ca-certificates git jq screen tmux net-tools cron
    
    if ! command -v node &> /dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        apt-get install -y nodejs
    else
        log_info "Node.js 已安装: $(node -v)"
    fi
    
    systemctl enable cron 2>/dev/null || true
    systemctl start cron 2>/dev/null || true
    
    log_info "✅ 依赖安装完成"
}

# 安装 nodejs-argo
install_nodejs_argo() {
    log_info "开始安装 nodejs-argo..."
    
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    
    if ! command -v npm &> /dev/null; then
        log_error "npm 未安装"
        exit 1
    fi
    
    log_info "npm 版本: $(npm -v)"
    log_info "node 版本: $(node -v)"
    
    npm install -g nodejs-argo
    
    if [ $? -eq 0 ]; then
        log_info "✅ nodejs-argo 安装成功"
    else
        log_error "nodejs-argo 安装失败"
        exit 1
    fi
    
    NODEJS_ARGO_BIN=$(which nodejs-argo 2>/dev/null || echo "/usr/local/bin/nodejs-argo")
    log_info "nodejs-argo 路径: $NODEJS_ARGO_BIN"
}

# ========== Part 1 结束 ==========
# ========== Part 2 开始 ==========
# 构建环境变量
build_env_vars() {
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
    if [ -n "$UPLOAD_URL" ]; then
        ENV_VARS="$ENV_VARS UPLOAD_URL='${UPLOAD_URL}'"
    fi
    ENV_VARS="$ENV_VARS PROJECT_URL=${PROJECT_URL}"
    
    log_info "环境变量: $ENV_VARS"
}

# 创建 Screen + Cron 服务
setup_screen_service() {
    log_info "配置 Screen + Cron 自启动..."
    
    START_SCRIPT="$WORKDIR/start_nodejs_argo.sh"
    cat > "$START_SCRIPT" <<EOF
#!/bin/bash
cd $WORKDIR
export $ENV_VARS
screen -dmS nodejs-argo $NODEJS_ARGO_BIN
EOF
    chmod +x "$START_SCRIPT"
    
    # 添加到 crontab
    (crontab -l 2>/dev/null | grep -v "nodejs-argo"; echo "@reboot sleep 10 && $START_SCRIPT") | crontab -
    
    # 立即启动
    screen -dmS nodejs-argo bash -c "export $ENV_VARS; $NODEJS_ARGO_BIN"
    
    log_info "✅ Screen + Cron 已配置"
}

# 创建 Tmux + Cron 服务
setup_tmux_service() {
    log_info "配置 Tmux + Cron 自启动..."
    
    START_SCRIPT="$WORKDIR/start_nodejs_argo.sh"
    cat > "$START_SCRIPT" <<EOF
#!/bin/bash
cd $WORKDIR
export $ENV_VARS
tmux new-session -d -s nodejs-argo $NODEJS_ARGO_BIN
EOF
    chmod +x "$START_SCRIPT"
    
    # 添加到 crontab
    (crontab -l 2>/dev/null | grep -v "nodejs-argo"; echo "@reboot sleep 10 && $START_SCRIPT") | crontab -
    
    # 立即启动
    tmux new-session -d -s nodejs-argo "export $ENV_VARS; $NODEJS_ARGO_BIN"
    
    log_info "✅ Tmux + Cron 已配置"
}

# 创建 PM2 服务
setup_pm2_service() {
    log_info "配置 PM2 自启动..."
    
    # 安装 PM2
    if ! command -v pm2 >/dev/null 2>&1; then
        log_info "安装 PM2..."
        npm install -g pm2
    fi
    
    # 创建 ecosystem 配置文件
    cat > "$WORKDIR/ecosystem.config.js" <<EOF
module.exports = {
  apps: [{
    name: 'nodejs-argo',
    script: '$NODEJS_ARGO_BIN',
    cwd: '$WORKDIR',
    env: {
      PORT: $PORT,
      ARGO_PORT: $ARGO_PORT,
      UUID: '$UUID',
EOF

    # 添加可选环境变量
    if [ -n "$FIX_DOMAIN" ]; then
        echo "      ARGO_DOMAIN: '$FIX_DOMAIN'," >> "$WORKDIR/ecosystem.config.js"
    fi
    if [ -n "$ARGO_AUTH" ]; then
        echo "      ARGO_AUTH: '$ARGO_AUTH'," >> "$WORKDIR/ecosystem.config.js"
    fi
    if [ -n "$NEZHA_SERVER" ]; then
        echo "      NEZHA_SERVER: '$NEZHA_SERVER'," >> "$WORKDIR/ecosystem.config.js"
    fi
    if [ -n "$NEZHA_PORT" ]; then
        echo "      NEZHA_PORT: '$NEZHA_PORT'," >> "$WORKDIR/ecosystem.config.js"
    fi
    if [ -n "$NEZHA_KEY" ]; then
        echo "      NEZHA_KEY: '$NEZHA_KEY'," >> "$WORKDIR/ecosystem.config.js"
    fi
    if [ -n "$UPLOAD_URL" ]; then
        echo "      UPLOAD_URL: '$UPLOAD_URL'," >> "$WORKDIR/ecosystem.config.js"
    fi
    
    cat >> "$WORKDIR/ecosystem.config.js" <<EOF
      PROJECT_URL: '$PROJECT_URL'
    },
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '500M'
  }]
};
EOF
    
    # PM2 启动
    pm2 start "$WORKDIR/ecosystem.config.js"
    pm2 save
    
    # 配置 PM2 自启动
    pm2 startup | grep -E "sudo|rc-update" | sh || true
    
    log_info "✅ PM2 已配置"
}

# 创建 Systemd 服务 (Ubuntu/Debian)
setup_systemd_service() {
    log_info "配置 Systemd 服务..."
    
    # 创建日志目录
    mkdir -p /var/log/nodejs-argo
    
    SERVICE_FILE="/etc/systemd/system/nodejs-argo.service"
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=NodeJS Argo Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORKDIR
Environment="PORT=$PORT"
Environment="ARGO_PORT=$ARGO_PORT"
Environment="UUID=$UUID"
EOF

    # 添加可选环境变量
    if [ -n "$FIX_DOMAIN" ]; then
        echo "Environment=\"ARGO_DOMAIN=$FIX_DOMAIN\"" >> "$SERVICE_FILE"
    fi
    if [ -n "$ARGO_AUTH" ]; then
        echo "Environment=\"ARGO_AUTH=$ARGO_AUTH\"" >> "$SERVICE_FILE"
    fi
    if [ -n "$NEZHA_SERVER" ]; then
        echo "Environment=\"NEZHA_SERVER=$NEZHA_SERVER\"" >> "$SERVICE_FILE"
    fi
    if [ -n "$NEZHA_PORT" ]; then
        echo "Environment=\"NEZHA_PORT=$NEZHA_PORT\"" >> "$SERVICE_FILE"
    fi
    if [ -n "$NEZHA_KEY" ]; then
        echo "Environment=\"NEZHA_KEY=$NEZHA_KEY\"" >> "$SERVICE_FILE"
    fi
    if [ -n "$UPLOAD_URL" ]; then
        echo "Environment=\"UPLOAD_URL=$UPLOAD_URL\"" >> "$SERVICE_FILE"
    fi
    
    cat >> "$SERVICE_FILE" <<EOF
Environment="PROJECT_URL=$PROJECT_URL"
ExecStart=$NODEJS_ARGO_BIN
Restart=always
RestartSec=10
StandardOutput=append:/var/log/nodejs-argo/output.log
StandardError=append:/var/log/nodejs-argo/error.log

[Install]
WantedBy=multi-user.target
EOF
    
    # 重载并启动服务
    systemctl daemon-reload
    systemctl enable nodejs-argo.service
    systemctl start nodejs-argo.service
    
    log_info "✅ Systemd 服务已配置"
}

# 创建 OpenRC 服务 (Alpine)
setup_openrc_service() {
    log_info "配置 OpenRC 服务..."
    
    # 创建日志目录
    mkdir -p /var/log/nodejs-argo
    
    SERVICE_FILE="/etc/init.d/nodejs-argo"
    
    cat > "$SERVICE_FILE" <<'EOFX'
#!/sbin/openrc-run

name="nodejs-argo"
description="NodeJS Argo Service"
EOFX

    echo "command=\"$NODEJS_ARGO_BIN\"" >> "$SERVICE_FILE"
    
    cat >> "$SERVICE_FILE" <<EOF
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
directory="$WORKDIR"
output_log="/var/log/nodejs-argo/output.log"
error_log="/var/log/nodejs-argo/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    export PORT=$PORT
    export ARGO_PORT=$ARGO_PORT
    export UUID=$UUID
EOF

    # 添加可选环境变量
    if [ -n "$FIX_DOMAIN" ]; then
        echo "    export ARGO_DOMAIN=$FIX_DOMAIN" >> "$SERVICE_FILE"
    fi
    if [ -n "$ARGO_AUTH" ]; then
        echo "    export ARGO_AUTH='$ARGO_AUTH'" >> "$SERVICE_FILE"
    fi
    if [ -n "$NEZHA_SERVER" ]; then
        echo "    export NEZHA_SERVER=$NEZHA_SERVER" >> "$SERVICE_FILE"
    fi
    if [ -n "$NEZHA_PORT" ]; then
        echo "    export NEZHA_PORT=$NEZHA_PORT" >> "$SERVICE_FILE"
    fi
    if [ -n "$NEZHA_KEY" ]; then
        echo "    export NEZHA_KEY=$NEZHA_KEY" >> "$SERVICE_FILE"
    fi
    if [ -n "$UPLOAD_URL" ]; then
        echo "    export UPLOAD_URL='$UPLOAD_URL'" >> "$SERVICE_FILE"
    fi
    
    cat >> "$SERVICE_FILE" <<EOF
    export PROJECT_URL=$PROJECT_URL
}
EOF
    
    chmod +x "$SERVICE_FILE"
    
    # 添加到开机自启动
    rc-update add nodejs-argo default
    
    # 启动服务
    rc-service nodejs-argo start
    
    log_info "✅ OpenRC 服务已配置"
}

# 健康检查
check_service_status() {
    log_title "服务状态检查"
    
    log_info "等待服务启动..."
    sleep 5
    
    echo
    log_info "=== 进程状态 ==="
    if pgrep -f "nodejs-argo" >/dev/null; then
        log_info "✅ nodejs-argo 进程运行中"
        ps aux | grep "nodejs-argo" | grep -v grep
    else
        log_warn "⚠️  未检测到 nodejs-argo 进程"
    fi
    
    # 检查哪吒进程
    if [ -n "$NEZHA_SERVER" ]; then
        echo
        log_info "=== 哪吒 Agent 状态 ==="
        if pgrep -f "nezha\|agent" >/dev/null; then
            log_info "✅ 哪吒 Agent 运行中"
            ps aux | grep -E "nezha|agent" | grep -v grep
        else
            log_warn "⚠️  未检测到哪吒 Agent 进程"
        fi
    fi
    
    # 检查端口
    echo
    log_info "=== 端口监听状态 ==="
    if command -v netstat >/dev/null 2>&1; then
        if netstat -tuln 2>/dev/null | grep -q ":$PORT "; then
            log_info "✅ HTTP 端口 $PORT 正在监听"
        else
            log_warn "⚠️  HTTP 端口 $PORT 未监听"
        fi
        
        if netstat -tuln 2>/dev/null | grep -q ":$ARGO_PORT "; then
            log_info "✅ Argo 端口 $ARGO_PORT 正在监听"
        else
            log_warn "⚠️  Argo 端口 $ARGO_PORT 未监听"
        fi
    fi
    
    # HTTP 健康检查
    echo
    log_info "=== HTTP 服务检查 ==="
    if command -v curl >/dev/null 2>&1; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
            log_info "✅ HTTP 服务响应正常 (HTTP $HTTP_CODE)"
        else
            log_warn "⚠️  HTTP 服务响应异常 (HTTP $HTTP_CODE)"
        fi
    fi
}

# 显示配置信息
show_config_info() {
    log_title "配置信息"
    echo "工作目录: $WORKDIR"
    echo "HTTP 端口: $PORT"
    echo "Argo 端口: $ARGO_PORT"
    echo "UUID: $UUID"
    echo "固定域名: ${FIX_DOMAIN:-临时域名}"
    if [ -n "$NEZHA_SERVER" ]; then
        echo "哪吒版本: $NEZHA_VERSION"
        echo "哪吒服务器: $NEZHA_SERVER"
        [ -n "$NEZHA_PORT" ] && echo "哪吒端口: $NEZHA_PORT"
    fi
    echo "项目地址: $PROJECT_URL"
    [ -n "$UPLOAD_URL" ] && echo "上传地址: $UPLOAD_URL"
    echo ""
}

# 显示管理命令
show_management_commands() {
    log_title "管理命令"
    
    case $RUNNER in
        1)
            echo "【Screen 会话管理】"
            echo "  查看日志: screen -r nodejs-argo"
            echo "  分离会话: Ctrl+A 然后按 D"
            echo "  停止服务: screen -S nodejs-argo -X quit"
            echo "  重启服务: $WORKDIR/start_nodejs_argo.sh"
            echo "  查看自启: crontab -l | grep nodejs-argo"
            ;;
        2)
            echo "【Tmux 会话管理】"
            echo "  查看日志: tmux attach -t nodejs-argo"
            echo "  分离会话: Ctrl+B 然后按 D"
            echo "  停止服务: tmux kill-session -t nodejs-argo"
            echo "  重启服务: $WORKDIR/start_nodejs_argo.sh"
            echo "  查看自启: crontab -l | grep nodejs-argo"
            ;;
        3)
            echo "【PM2 管理】"
            echo "  查看状态: pm2 status"
            echo "  查看日志: pm2 logs nodejs-argo"
            echo "  实时日志: pm2 logs nodejs-argo --lines 100"
            echo "  停止服务: pm2 stop nodejs-argo"
            echo "  重启服务: pm2 restart nodejs-argo"
            echo "  删除服务: pm2 delete nodejs-argo"
            echo "  查看配置: cat $WORKDIR/ecosystem.config.js"
            ;;
        4)
            if [ "$OS" = "alpine" ]; then
                echo "【OpenRC 服务管理】"
                echo "  查看状态: rc-service nodejs-argo status"
                echo "  启动服务: rc-service nodejs-argo start"
                echo "  停止服务: rc-service nodejs-argo stop"
                echo "  重启服务: rc-service nodejs-argo restart"
                echo "  查看日志: tail -f /var/log/nodejs-argo/output.log"
                echo "  查看错误: tail -f /var/log/nodejs-argo/error.log"
                echo "  查看自启: rc-status default | grep nodejs-argo"
                echo "  查看配置: cat /etc/init.d/nodejs-argo"
            else
                echo "【Systemd 服务管理】"
                echo "  查看状态: systemctl status nodejs-argo"
                echo "  启动服务: systemctl start nodejs-argo"
                echo "  停止服务: systemctl stop nodejs-argo"
                echo "  重启服务: systemctl restart nodejs-argo"
                echo "  查看日志: journalctl -u nodejs-argo -f"
                echo "  查看全部: journalctl -u nodejs-argo --no-pager"
                echo "  查看文件: tail -f /var/log/nodejs-argo/output.log"
                echo "  查看自启: systemctl is-enabled nodejs-argo"
                echo "  查看配置: cat /etc/systemd/system/nodejs-argo.service"
            fi
            ;;
    esac
    
    echo
    echo "【故障排查】"
    echo "  查看进程: ps aux | grep nodejs-argo"
    echo "  查看端口: netstat -tuln | grep -E '$PORT|$ARGO_PORT'"
    echo "  查看哪吒: ps aux | grep -E 'nezha|agent'"
    echo "  手动测试: curl -I http://localhost:$PORT"
    echo "  查看日志: cat $LOGFILE"
    echo
}

# ========== Part 2 结束 ==========
# ========== Part 3 开始 ==========

# 显示日志文件
show_logs() {
    log_title "日志文件"
    
    log_info "查找日志文件..."
    
    # 等待日志生成
    sleep 3
    
    # 常见日志位置
    LOG_LOCATIONS=(
        "$WORKDIR/logs/*.log"
        "$WORKDIR/*.log"
        "$WORKDIR/tmp/*.log"
        "/var/log/nodejs-argo/*.log"
        "$HOME/.pm2/logs/*nodejs-argo*.log"
    )
    
    FOUND_LOGS=""
    for pattern in "${LOG_LOCATIONS[@]}"; do
        for logfile in $pattern; do
            if [ -f "$logfile" ]; then
                FOUND_LOGS="$FOUND_LOGS\n  $logfile"
            fi
        done
    done
    
    if [ -n "$FOUND_LOGS" ]; then
        echo -e "发现日志文件:$FOUND_LOGS"
        echo
        echo "===== 最近日志内容 (最后 20 行) ====="
        for pattern in "${LOG_LOCATIONS[@]}"; do
            for logfile in $pattern; do
                if [ -f "$logfile" ]; then
                    echo "--- $logfile ---"
                    tail -20 "$logfile" 2>/dev/null
                    echo
                fi
            done
        done
    else
        log_warn "未找到应用日志文件"
    fi
}

# 显示订阅信息
show_subscription_info() {
    log_title "订阅信息"
    
    # 等待订阅文件生成
    sleep 5
    
    SUB_FILE="$WORKDIR/tmp/sub.txt"
    if [ -f "$SUB_FILE" ]; then
        echo "📄 订阅文件位置: $SUB_FILE"
        echo
        echo "📋 订阅内容 (Base64):"
        cat "$SUB_FILE"
        echo
        echo
        echo "📋 订阅内容 (解码):"
        cat "$SUB_FILE" | base64 -d 2>/dev/null || cat "$SUB_FILE"
        echo
    else
        log_warn "未找到订阅文件 sub.txt"
        echo "🔍 查找其他 txt 文件:"
        find "$WORKDIR" -name "*.txt" -type f 2>/dev/null | head -10 || echo "  未找到"
    fi
}

# 执行安装
do_install() {
    log_title "开始安装 nodejs-argo"
    
    check_root
    detect_system
    
    # 收集配置
    collect_config
    
    # 安装依赖
    case $OS in
        alpine)
            install_deps_alpine
            ;;
        ubuntu|debian)
            install_deps_ubuntu
            ;;
        *)
            log_error "不支持的系统: $OS"
            exit 1
            ;;
    esac
    
    # 安装 nodejs-argo
    install_nodejs_argo
    
    # 构建环境变量
    build_env_vars
    
    # 配置后台运行方式
    case $RUNNER in
        1)
            setup_screen_service
            ;;
        2)
            setup_tmux_service
            ;;
        3)
            setup_pm2_service
            ;;
        4)
            if [ "$OS" = "alpine" ]; then
                setup_openrc_service
            else
                setup_systemd_service
            fi
            ;;
    esac
    
    # 检查服务状态
    check_service_status
    
    # 显示配置信息
    show_config_info
    
    # 显示管理命令
    show_management_commands
    
    # 显示日志
    show_logs
    
    # 显示订阅信息
    show_subscription_info
    
    # 完成提示
    echo
    log_title "✅ 安装完成！"
    echo
    log_info "如需重启系统测试自启动:"
    log_info "  1. 执行: reboot"
    log_info "  2. 重启后等待 15 秒"
    log_info "  3. 验证服务: ps aux | grep nodejs-argo"
    log_info "  4. 验证端口: netstat -tuln | grep $PORT"
    echo
}

# ==================== 主菜单 ====================

show_menu() {
    clear
    log_title "nodejs-argo 管理脚本"
    echo
    echo "1) 安装 nodejs-argo"
    echo "2) 卸载 nodejs-argo"
    echo "3) 退出"
    echo
}

# 主函数
main() {
    # 如果有命令行参数，直接执行
    if [ $# -gt 0 ]; then
        case $1 in
            install|-i|--install)
                do_install
                ;;
            uninstall|-u|--uninstall)
                do_uninstall
                ;;
            *)
                echo "用法: $0 [install|uninstall]"
                echo "  install   - 安装 nodejs-argo"
                echo "  uninstall - 卸载 nodejs-argo"
                echo
                echo "或直接运行脚本进入交互式菜单"
                exit 1
                ;;
        esac
    else
        # 交互式菜单
        while true; do
            show_menu
            read -p "请选择操作 [1-3]: " choice
            case $choice in
                1)
                    do_install
                    echo
                    read -p "按回车键继续..."
                    ;;
                2)
                    do_uninstall
                    echo
                    read -p "按回车键继续..."
                    ;;
                3)
                    log_info "退出脚本"
                    exit 0
                    ;;
                *)
                    log_error "无效选择，请重新输入"
                    sleep 2
                    ;;
            esac
        done
    fi
}

# 执行主函数
main "$@"

# ========== Part 3 结束 ==========
