#!/bin/bash
# nodejs_argo_universal.sh - 通用版本（支持多系统 + 哪吒 + 开机自启动）
# 修复版 v2.0 - 增强 Ubuntu 兼容性
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

log "开始 NodeJS Argo 通用安装脚本 v2.0"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 🔐 权限检查
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限运行此脚本"
  echo "使用方法: sudo bash $0"
  exit 1
fi

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
  elif command -v service >/dev/null 2>&1 && [ -f /etc/init.d/cron ]; then
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
    pm2 save --force 2>/dev/null || true
    pm2 unstartup 2>/dev/null || true
  fi

  # 停止 screen/tmux
  screen -S nodejs-argo -X quit 2>/dev/null || true
  tmux kill-session -t nodejs-argo 2>/dev/null || true

  # 删除 crontab
  (crontab -l 2>/dev/null | grep -v "nodejs-argo") | crontab - 2>/dev/null || true

  # 停止进程
  pkill -f "node.*index.js" 2>/dev/null || true

  # 删除安装目录
  rm -rf /opt/nodejs-argo
  rm -rf /var/log/nodejs-argo

  log "✅ 卸载完成"
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
  
  $PKG_UPDATE || {
    log "⚠️  包管理器更新失败，尝试继续..."
  }
  
  case "$PKG_MANAGER" in
    apt)
      # 设置非交互模式
      export DEBIAN_FRONTEND=noninteractive
      
      # 修复可能的 dpkg 问题
      dpkg --configure -a 2>/dev/null || true
      
      $PKG_INSTALL \
        curl \
        ca-certificates \
        git \
        jq \
        screen \
        tmux \
        bash \
        net-tools \
        procps \
        build-essential \
        python3 \
        gnupg2 \
        software-properties-common \
        apt-transport-https || {
        log "❌ 依赖安装失败"
        exit 1
      }
      ;;
    apk)
      $PKG_INSTALL \
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
      rc-update add dcron default 2>/dev/null || true
      rc-update add local default 2>/dev/null || true
      ;;
    yum|dnf)
      $PKG_INSTALL \
        curl \
        ca-certificates \
        git \
        jq \
        screen \
        tmux \
        bash \
        net-tools \
        procps-ng \
        gcc \
        gcc-c++ \
        make \
        python3
      ;;
    pacman)
      $PKG_INSTALL \
        curl \
        ca-certificates \
        git \
        jq \
        screen \
        tmux \
        bash \
        net-tools \
        procps-ng \
        base-devel \
        python
      ;;
    opkg)
      $PKG_INSTALL curl ca-certificates git-http jq screen tmux bash
      ;;
  esac
  
  log "✅ 系统依赖安装完成"
}

install_nodejs() {
  # 检查是否已安装合适版本的 Node.js
  if command -v node >/dev/null 2>&1; then
    NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [ "$NODE_VERSION" -ge 16 ]; then
      log "✅ Node.js 已安装: $(node -v)"
      return 0
    else
      log "⚠️  Node.js 版本过低 ($(node -v))，准备升级..."
    fi
  fi
  
  log "开始安装 Node.js..."
  
  case "$PKG_MANAGER" in
    apt)
      # 方法1: 尝试 NodeSource（最新稳定版）
      log "方法1: 尝试从 NodeSource 安装..."
      
      # 清理旧的 NodeSource 配置
      rm -f /etc/apt/sources.list.d/nodesource.list* 2>/dev/null || true
      rm -f /usr/share/keyrings/nodesource.gpg 2>/dev/null || true
      
      # 下载并执行 NodeSource 安装脚本
      if curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh 2>/dev/null; then
        chmod +x /tmp/nodesource_setup.sh
        if bash /tmp/nodesource_setup.sh; then
          if apt-get install -y nodejs; then
            log "✅ NodeSource 安装成功"
            rm -f /tmp/nodesource_setup.sh
            node -v && npm -v
            return 0
          fi
        fi
      fi
      
      log "⚠️  NodeSource 安装失败，尝试方法2..."
      
      # 方法2: 使用 NVM（最可靠）
      log "方法2: 使用 NVM 安装..."
      
      export NVM_DIR="/root/.nvm"
      
