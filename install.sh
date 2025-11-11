cat > nodejs-argo.sh << 'EOF'
#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 打印带颜色的信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示 Logo
show_logo() {
    clear
    echo -e "${CYAN}"
    cat << "LOGO"
========================================
     Node.js Argo 一键部署脚本
========================================
LOGO
    echo -e "${NC}"
}

# 显示主菜单
show_menu() {
    show_logo
    echo "请选择操作："
    echo ""
    echo "  1) 安装/部署 nodejs-argo"
    echo "  2) 卸载 nodejs-argo"
    echo "  3) 重启服务"
    echo "  4) 查看状态"
    echo "  5) 查看日志"
    echo "  6) 修改配置"
    echo "  0) 退出"
    echo ""
    read -p "请输入选项 [0-6]: " choice
    
    case $choice in
        1) install_all ;;
        2) uninstall_all ;;
        3) restart_service ;;
        4) show_status ;;
        5) show_logs ;;
        6) modify_config ;;
        0) exit 0 ;;
        *) print_error "无效选项"; sleep 2; show_menu ;;
    esac
}

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "请使用 root 权限运行: sudo bash $0"
        exit 1
    fi
}

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        print_error "无法检测系统类型"
        exit 1
    fi
    
    print_info "检测到系统: $OS $VERSION"
}

# 安装 Node.js
install_nodejs() {
    if command -v node &> /dev/null; then
        NODE_VERSION=$(node -v)
        print_success "Node.js 已安装: $NODE_VERSION"
        
        # 检查版本是否 >= 16
        MAJOR_VERSION=$(echo $NODE_VERSION | cut -d'.' -f1 | sed 's/v//')
        if [ "$MAJOR_VERSION" -lt 16 ]; then
            print_warning "Node.js 版本过低，建议升级到 v16 或更高版本"
            read -p "是否重新安装最新版本？(y/n): " REINSTALL
            if [ "$REINSTALL" != "y" ] && [ "$REINSTALL" != "Y" ]; then
                return 0
            fi
        else
            return 0
        fi
    fi
    
    print_info "正在安装 Node.js v20..."
    
    case $OS in
        ubuntu|debian)
            # 更新包管理器
            apt-get update -y
            
            # 安装必要工具
            apt-get install -y curl wget gnupg2 ca-certificates lsb-release apt-transport-https
            
            # 添加 NodeSource 仓库
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            
            # 安装 Node.js
            apt-get install -y nodejs
            ;;
            
        centos|rhel|rocky|almalinux)
            # 安装必要工具
            yum install -y curl wget
            
            # 添加 NodeSource 仓库
            curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
            
            # 安装 Node.js
            yum install -y nodejs
            ;;
            
        fedora)
            dnf install -y curl wget
            curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
            dnf install -y nodejs
            ;;
            
        arch|manjaro)
            pacman -Sy --noconfirm nodejs npm
            ;;
            
        *)
            print_error "不支持的系统类型: $OS"
            print_info "请手动安装 Node.js v16 或更高版本"
            exit 1
            ;;
    esac
    
    # 验证安装
    if command -v node &> /dev/null; then
        print_success "Node.js 安装成功: $(node -v)"
        print_success "npm 版本: $(npm -v)"
    else
        print_error "Node.js 安装失败"
        exit 1
    fi
}

# 安装 PM2
install_pm2() {
    if command -v pm2 &> /dev/null; then
        print_success "PM2 已安装: $(pm2 -v)"
        return 0
    fi
    
    print_info "正在安装 PM2..."
    npm install -g pm2
    
    if command -v pm2 &> /dev/null; then
        print_success "PM2 安装成功: $(pm2 -v)"
    else
        print_error "PM2 安装失败"
        exit 1
    fi
}

# 安装 nodejs-argo
install_nodejs_argo() {
    print_info "正在安装 nodejs-argo..."
    
    # 先卸载旧版本
    npm uninstall -g nodejs-argo 2>/dev/null
    
    # 安装最新版本
    npm install -g nodejs-argo
    
    if [ $? -eq 0 ]; then
        print_success "nodejs-argo 安装成功"
    else
        print_error "nodejs-argo 安装失败"
        print_info "尝试使用国内镜像安装..."
        npm config set registry https://registry.npmmirror.com
        npm install -g nodejs-argo
        
        if [ $? -ne 0 ]; then
            print_error "安装失败，请检查网络连接"
            exit 1
        fi
    fi
}

# 收集用户配置
collect_config() {
    echo ""
    echo "=========================================="
    echo "        请输入配置信息"
    echo "=========================================="
    echo ""
    
    # Argo Token
    read -p "请输入 Argo Token (必填): " ARGO_TOKEN
    while [ -z "$ARGO_TOKEN" ]; do
        print_error "Argo Token 不能为空"
        read -p "请输入 Argo Token: " ARGO_TOKEN
    done
    
    # 端口配置
    read -p "请输入服务端口 (默认 3000): " PORT
    PORT=${PORT:-3000}
    
    # 检查端口是否被占用
    if netstat -tuln 2>/dev/null | grep -q ":$PORT "; then
        print_warning "端口 $PORT 已被占用"
        read -p "请输入其他端口: " PORT
    fi
    
    # Argo 域名（可选）
    read -p "请输入 Argo 域名 (可选，直接回车跳过): " ARGO_DOMAIN
    
    # UUID（可选）
    read -p "请输入 UUID (可选，直接回车自动生成): " UUID
    if [ -z "$UUID" ]; then
        if command -v uuidgen &> /dev/null; then
            UUID=$(uuidgen)
        else
            UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$(shuf -i 1000-9999 -n 1)")
        fi
        print_info "自动生成 UUID: $UUID"
    fi
    
    # 节点名称
    read -p "请输入节点名称 (默认 nodejs-argo): " NODE_NAME
    NODE_NAME=${NODE_NAME:-nodejs-argo}
    
    # 密码保护（可选）
    read -p "请输入访问密码 (可选，直接回车跳过): " PASSWORD
    
    # Vmess/Vless 路径
    read -p "请输入 Vmess/Vless 路径 (默认 /vmess): " VMESS_PATH
    VMESS_PATH=${VMESS_PATH:-/vmess}
    
    echo ""
    print_info "配置信息确认："
    echo "----------------------------------------"
    echo "Argo Token: ${ARGO_TOKEN:0:20}..."
    echo "端口: $PORT"
    echo "Argo 域名: ${ARGO_DOMAIN:-未设置}"
    echo "UUID: $UUID"
    echo "节点名称: $NODE_NAME"
    echo "访问密码: ${PASSWORD:-未设置}"
    echo "Vmess 路径: $VMESS_PATH"
    echo "----------------------------------------"
    echo ""
    
    read -p "确认配置无误？(y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        print_warning "已取消部署"
        return 1
    fi
    
    return 0
}

# 创建配置目录和文件
create_config() {
    CONFIG_DIR="/root/.nodejs-argo"
    mkdir -p "$CONFIG_DIR"
    
    print_info "正在创建配置文件..."
    
    cat > "$CONFIG_DIR/config.json" << JSONEOF
{
  "argo_token": "$ARGO_TOKEN",
  "argo_domain": "$ARGO_DOMAIN",
  "port": $PORT,
  "uuid": "$UUID",
  "node_name": "$NODE_NAME",
  "password": "$PASSWORD",
  "vmess_path": "$VMESS_PATH"
}
JSONEOF
    
    print_success "配置文件创建成功: $CONFIG_DIR/config.json"
}

# 创建启动脚本
create_start_script() {
    print_info "正在创建启动脚本..."
    
    SCRIPT_DIR="/root/.nodejs-argo"
    mkdir -p "$SCRIPT_DIR"
    
    cat > "$SCRIPT_DIR/start.sh" << 'STARTEOF'
#!/bin/bash

# 加载配置
CONFIG_FILE="/root/.nodejs-argo/config.json"

if [ -f "$CONFIG_FILE" ]; then
    export ARGO_TOKEN=$(cat "$CONFIG_FILE" | grep -oP '(?<="argo_token": ")[^"]*')
    export ARGO_DOMAIN=$(cat "$CONFIG_FILE" | grep -oP '(?<="argo_domain": ")[^"]*')
    export PORT=$(cat "$CONFIG_FILE" | grep -oP '(?<="port": )[^,]*')
    export UUID=$(cat "$CONFIG_FILE" | grep -oP '(?<="uuid": ")[^"]*')
    export NODE_NAME=$(cat "$CONFIG_FILE" | grep -oP '(?<="node_name": ")[^"]*')
    export PASSWORD=$(cat "$CONFIG_FILE" | grep -oP '(?<="password": ")[^"]*')
    export VMESS_PATH=$(cat "$CONFIG_FILE" | grep -oP '(?<="vmess_path": ")[^"]*')
fi

# 启动服务
nodejs-argo
STARTEOF
    
    chmod +x "$SCRIPT_DIR/start.sh"
    print_success "启动脚本创建成功"
}

# 启动服务
start_service() {
    print_info "正在启动服务..."
    
    # 停止可能存在的旧进程
    pm2 delete nodejs-argo 2>/dev/null
    
    # 使用 PM2 启动服务
    pm2 start /root/.nodejs-argo/start.sh --name nodejs-argo
    
    if [ $? -eq 0 ]; then
        print_success "服务启动成功"
        
        # 设置开机自启
        pm2 save
        pm2 startup systemd -u root --hp /root 2>/dev/null
        env PATH=$PATH:/usr/bin /usr/lib/node_modules/pm2/bin/pm2 startup systemd -u root --hp /root
        systemctl enable pm2-root 2>/dev/null
        
        print_success "已设置开机自启"
    else
        print_error "服务启动失败"
        return 1
    fi
}

# 显示服务信息
show_service_info() {
    if [ ! -f "/root/.nodejs-argo/config.json" ]; then
        print_error "配置文件不存在"
        return 1
    fi
    
    # 读取配置
    CONFIG_FILE="/root/.nodejs-argo/config.json"
    PORT=$(cat "$CONFIG_FILE" | grep -oP '(?<="port": )[^,]*')
    UUID=$(cat "$CONFIG_FILE" | grep -oP '(?<="uuid": ")[^"]*')
    NODE_NAME=$(cat "$CONFIG_FILE" | grep -oP '(?<="node_name": ")[^"]*')
    ARGO_DOMAIN=$(cat "$CONFIG_FILE" | grep -oP '(?<="argo_domain": ")[^"]*')
    PASSWORD=$(cat "$CONFIG_FILE" | grep -oP '(?<="password": ")[^"]*')
    VMESS_PATH=$(cat "$CONFIG_FILE" | grep -oP '(?<="vmess_path": ")[^"]*')
    
    echo ""
    echo "=========================================="
    echo "        部署完成！"
    echo "=========================================="
    echo ""
    print_success "服务已在后台运行"
    echo ""
    echo "配置信息："
    echo "  - 端口: $PORT"
    echo "  - UUID: $UUID"
    echo "  - 节点名称: $NODE_NAME"
    echo "  - Vmess 路径: $VMESS_PATH"
    [ -n "$ARGO_DOMAIN" ] && echo "  - Argo 域名: $ARGO_DOMAIN"
    [ -n "$PASSWORD" ] && echo "  - 访问密码: $PASSWORD"
    echo ""
    echo "常用命令："
    echo "  - 查看状态: pm2 status"
    echo "  - 查看日志: pm2 logs nodejs-argo"
    echo "  - 重启服务: pm2 restart nodejs-argo"
    echo "  - 停止服务: pm2 stop nodejs-argo"
    echo "  - 删除服务: pm2 delete nodejs-argo"
    echo ""
    echo "配置文件: /root/.nodejs-argo/config.json"
    echo "管理脚本: bash $0"
    echo "=========================================="
    echo ""
}

# 完整安装流程
install_all() {
    show_logo
    check_root
    detect_os
    
    print_info "开始部署 nodejs-argo..."
    echo ""
    
    # 安装依赖
    install_nodejs
    install_pm2
    install_nodejs_argo
    
    # 收集配置
    if ! collect_config; then
        show_menu
        return
    fi
    
    # 创建配置
    create_config
    create_start_script
    
    # 启动服务
    if start_service; then
        show_service_info
    else
        print_error "服务启动失败，请检查日志"
    fi
    
    read -p "按回车键返回主菜单..."
    show_menu
}

# 卸载功能
uninstall_all() {
    show_logo
    check_root
    
    print_warning "即将卸载 nodejs-argo 及相关组件"
    read -p "是否继续？(y/n): " CONFIRM
    
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        print_info "已取消卸载"
        sleep 2
        show_menu
        return
    fi
    
    echo ""
    print_info "请选择卸载级别："
    echo "  1) 仅卸载 nodejs-argo 服务"
    echo "  2) 卸载 nodejs-argo + PM2"
    echo "  3) 完全卸载 (包括 Node.js)"
    echo ""
    read -p "请选择 [1-3]: " LEVEL
    
    # 停止并删除 PM2 服务
    if pm2 list 2>/dev/null | grep -q nodejs-argo; then
        print_info "停止 PM2 服务..."
        pm2 delete nodejs-argo
        pm2 save
        print_success "PM2 服务已停止"
    fi
    
    # 卸载 nodejs-argo
    print_info "卸载 nodejs-argo..."
    npm uninstall -g nodejs-argo 2>/dev/null
    print_success "nodejs-argo 已卸载"
    
    # 删除配置文件
    if [ -d "/root/.nodejs-argo" ]; then
        print_info "删除配置文件..."
        rm -rf /root/.nodejs-argo
        print_success "配置文件已删除"
    fi
    
    # 根据级别继续卸载
    if [ "$LEVEL" = "2" ] || [ "$LEVEL" = "3" ]; then
        if command -v pm2 &> /dev/null; then
            print_info "卸载 PM2..."
            pm2 kill
            npm uninstall -g pm2
            systemctl disable pm2-root 2>/dev/null
            rm -rf /etc/systemd/system/pm2-root.service 2>/dev/null
            systemctl daemon-reload
            print_success "PM2 已卸载"
        fi
    fi
    
    if [ "$LEVEL" = "3" ]; then
        print_warning "即将卸载 Node.js，这可能影响其他依赖 Node.js 的应用"
        read -p "确认卸载 Node.js？(y/n): " CONFIRM_NODE
        
        if [ "$CONFIRM_NODE" = "y" ] || [ "$CONFIRM_NODE" = "Y" ]; then
            print_info "卸载 Node.js..."
            
            case $OS in
                ubuntu|debian)
                    apt-get remove -y nodejs npm
                    apt-get autoremove -y
                    rm -rf /etc/apt/sources.list.d/nodesource.list
                    ;;
                centos|rhel|rocky|almalinux)
                    yum remove -y nodejs npm
                    rm -rf /etc/yum.repos.d/nodesource*.repo
                    ;;
                fedora)
                    dnf remove -y nodejs npm
                    ;;
                arch|manjaro)
                    pacman -Rns --noconfirm nodejs npm
                    ;;
            esac
            
            print_success "Node.js 已卸载"
        fi
    fi
    
    echo ""
    print_success "卸载完成！"
    echo ""
    read -p "按回车键返回主菜单..."
    show_menu
}

# 重启服务
restart_service() {
    show_logo
    print_info "正在重启服务..."
    
    pm2 restart nodejs-argo
    
    if [ $? -eq 0 ]; then
        print_success "服务重启成功"
    else
        print_error "服务重启失败"
    fi
    
    sleep 2
    show_menu
}

# 查看状态
show_status() {
    show_logo
    print_info "服务状态："
    echo ""
    
    pm2 status
    
    echo ""
    echo "详细信息："
    pm2 describe nodejs-argo 2>/dev/null
    
    echo ""
    read -p "按回车键返回主菜单..."
    show_menu
}

# 查看日志
show_logs() {
    show_logo
    print_info "实时日志 (按 Ctrl+C 返回菜单)："
    echo ""
    
    pm2 logs nodejs-argo
    
    show_menu
}

# 修改配置
modify_config() {
    show_logo
    
    if [ ! -f "/root/.nodejs-argo/config.json" ]; then
        print_error "配置文件不存在，请先安装服务"
        sleep 2
        show_menu
        return
    fi
    
    print_info "重新配置服务..."
    
    if collect_config; then
        create_config
        restart_service
    else
        show_menu
    fi
}

# 主函数
main() {
    show_menu
}

# 运行主函数
main

EOF

chmod +x nodejs-argo.sh
