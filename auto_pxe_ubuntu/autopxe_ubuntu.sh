#!/bin/bash
set -euo pipefail

# ==================== 智能配置初始化 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/autopxe_ubuntu"
ISO_FILE=""

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err() {
  echo -e "${RED}[ERROR] $*${NC}"
  exit 1
}
step() { echo -e "${BLUE}[STEP] $*${NC}"; }

# ==================== 核心功能函数 ====================

# 1. 自动寻找 ISO 文件
find_iso() {
  step "正在扫描当前目录下的 Ubuntu ISO 镜像..."
  # 匹配 ubuntu-*.iso (支持 desktop, server, live-server 等命名)
  # 排除 md5/sha 文件
  local candidates=()
  while IFS= read -r -d '' file; do
    candidates+=("$file")
  done < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -iname "ubuntu-*.iso" -print0 2>/dev/null)

  if [ ${#candidates[@]} -eq 0 ]; then
    err "未在当前目录 ($SCRIPT_DIR) 找到任何 Ubuntu ISO 文件。\n请确保文件名格式如: ubuntu-24.04-desktop-amd64.iso"
  elif [ ${#candidates[@]} -gt 1 ]; then
    warn "发现多个 ISO 文件，将使用最新修改的一个:"
    for f in "${candidates[@]}"; do echo "  - $f"; done
    # 按修改时间排序，取最新的
    ISO_FILE=$(ls -t "${candidates[@]}" | head -n1)
  else
    ISO_FILE="${candidates[0]}"
  fi

  info "✅ 已选定 ISO: $(basename "$ISO_FILE")"
}

# 2. 自动识别 ISO 版本和类型
detect_iso_type() {
  step "分析 ISO 镜像版本和类型..."

  # 挂载临时检查 (只读)
  local temp_mount="$WORK_DIR/temp_iso_check"
  mkdir -p "$temp_mount"
  if ! mount -o loop "$ISO_FILE" "$temp_mount" 2>/dev/null; then
    # 如果挂载失败，尝试从文件名推断
    warn "无法挂载 ISO 进行深度检查，尝试从文件名推断..."
    umount "$temp_mount" 2>/dev/null || true
    rmdir "$temp_mount"
    parse_filename_for_type
    return
  fi

  # 检查版本号 (从 .disk/info 或 casper/filesystem.manifest)
  local version="unknown"
  if [ -f "$temp_mount/.disk/info" ]; then
    version=$(head -n1 "$temp_mount/.disk/info" | grep -oP '\d+\.\d+' | head -n1)
  fi

  # 检查类型 (Desktop vs Server)
  # Desktop 通常有 casper/vmlinuz, Server (24.04+) 也有 casper, 旧版 Server 在 install/
  local kernel_path=""
  local initrd_path=""
  local boot_param_type=""
  local iso_type_name=""

  if [ -f "$temp_mount/casper/vmlinuz" ]; then
    kernel_path="casper/vmlinuz"
    initrd_path="casper/initrd"
    # 判断是 Desktop 还是 Live-Server
    if [ -f "$temp_mount/casper/filesystem.squashfs" ]; then
      # 进一步检查 manifest 或文件名
      if [[ "$ISO_FILE" == *"server"* ]]; then
        iso_type_name="Ubuntu Server (Live)"
        boot_param_type="server"
      else
        iso_type_name="Ubuntu Desktop"
        boot_param_type="desktop"
      fi
    else
      iso_type_name="Ubuntu (Legacy/Live)"
      boot_param_type="desktop"
    fi
  elif [ -f "$temp_mount/install/vmlinuz" ]; then
    # 旧版 Server (如 20.04 server 有时在 install)
    kernel_path="install/vmlinuz"
    initrd_path="install/initrd.gz"
    iso_type_name="Ubuntu Server (Legacy)"
    boot_param_type="server"
  else
    umount "$temp_mount"
    rmdir "$temp_mount"
    err "无法在 ISO 中找到有效的内核文件 (casper/vmlinuz 或 install/vmlinuz)。镜像可能损坏或不支持。"
  fi

  # 卸载临时挂载点
  umount "$temp_mount"
  rmdir "$temp_mount"

  # 导出全局变量供后续使用
  export DETECTED_VERSION="${version:-24.04}"
  export DETECTED_TYPE="$iso_type_name"
  export KERNEL_PATH="$kernel_path"
  export INITRD_PATH="$initrd_path"
  export BOOT_PARAM_TYPE="$boot_param_type"

  info "✅ 识别结果: 版本 ~$DETECTED_VERSION | 类型: $DETECTED_TYPE"
  info "   内核路径: $KERNEL_PATH"
}

parse_filename_for_type() {
  # 降级方案：仅从文件名推断
  if [[ "$ISO_FILE" == *"server"* ]]; then
    export DETECTED_TYPE="Ubuntu Server (推测)"
    export BOOT_PARAM_TYPE="server"
    export KERNEL_PATH="casper/vmlinuz" # 假设新版
    export INITRD_PATH="casper/initrd"
  else
    export DETECTED_TYPE="Ubuntu Desktop (推测)"
    export BOOT_PARAM_TYPE="desktop"
    export KERNEL_PATH="casper/vmlinuz"
    export INITRD_PATH="casper/initrd"
  fi
  export DETECTED_VERSION="未知 (从文件名推断)"
}

# 3. 自动获取网络配置
get_network_config() {
  step "自动检测网络环境..."

  # 获取非 lo 的第一个有 IP 的网卡
  INTERFACE=$(ip -br link | grep -v lo | awk '{print $1}' | head -n1)
  if [ -z "$INTERFACE" ]; then
    err "未检测到可用的网络接口。"
  fi
  info "使用网卡: $INTERFACE"

  # 获取本机 IP
  SERVER_IP=$(ip -4 addr show "$INTERFACE" | grep inet | awk '{print $2}' | cut -d/ -f1)
  if [ -z "$SERVER_IP" ]; then
    warn "网卡 $INTERFACE 没有 IPv4 地址。尝试使用 192.168.110.1 作为默认服务 IP (请确保手动配置了静态 IP)"
    SERVER_IP="192.168.110.1"
    NETMASK="255.255.255.0"
    ROUTER_IP="192.168.110.1"
    # 计算 DHCP 范围
    DHCP_RANGE_START="192.168.110.100"
    DHCP_RANGE_END="192.168.110.200"
    return
  fi

  # 获取子网掩码和前缀长度
  CIDR=$(ip -4 addr show "$INTERFACE" | grep inet | awk '{print $2}' | cut -d/ -f2)

  # 计算网络地址和广播地址 (简单逻辑：假设是常见的 /24, /16, /25)
  # 这里使用 ipcalc 逻辑的简化 bash 实现，或者依赖 ip 命令
  # 为了稳健，我们提取前三个段作为网段 (适用于 /24)
  # 更严谨的做法是使用 python 或 bc，但为了保持纯 bash，我们做合理假设

  # 获取网关 (Router)
  ROUTER_IP=$(ip route | grep "^default via" | grep "$INTERFACE" | awk '{print $3}' | head -n1)
  if [ -z "$ROUTER_IP" ]; then
    # 如果没有默认网关，假设网关是网段的第一个 IP (.1)
    NETWORK_PREFIX=$(echo "$SERVER_IP" | cut -d. -f1-3)
    ROUTER_IP="$NETWORK_PREFIX.1"
    warn "未检测到默认网关，假设网关为: $ROUTER_IP"
  fi

  # 转换 CIDR 到 Netmask (简单支持 /24, /16, /25)
  case $CIDR in
  8) NETMASK="255.0.0.0" ;;
  16) NETMASK="255.255.0.0" ;;
  24) NETMASK="255.255.255.0" ;;
  25) NETMASK="255.255.255.128" ;;
  *)
    warn "不支持的子网掩码 /$CIDR，强制使用 /24 逻辑计算 DHCP 范围"
    NETMASK="255.255.255.0"
    CIDR=24
    ;;
  esac

  # 动态计算 DHCP 范围 (避开网关和本机 IP)
  # 假设网段前三位不变
  NETWORK_PREFIX=$(echo "$SERVER_IP" | cut -d. -f1-3)

  # 简单的冲突避免逻辑
  LOCAL_LAST=$(echo "$SERVER_IP" | cut -d. -f4)
  GATEWAY_LAST=$(echo "$ROUTER_IP" | cut -d. -f4)

  # 设置起始和结束 (尽量在 100-200 之间，避开常见静态 IP)
  DHCP_START_LAST=100
  DHCP_END_LAST=200

  # 如果本机 IP 或网关在 100-200 之间，稍微偏移 (简化处理，实际生产环境建议手动指定)
  # 这里为了脚本简洁，假设用户会将服务器 IP 设为 .1 或 .2，所以 100-200 是安全的

  DHCP_RANGE_START="$NETWORK_PREFIX.$DHCP_START_LAST"
  DHCP_RANGE_END="$NETWORK_PREFIX.$DHCP_END_LAST"

  info "✅ 网络配置自动生成:"
  info "   本机 IP: $SERVER_IP/$CIDR"
  info "   网关: $ROUTER_IP"
  info "   DHCP 范围: $DHCP_RANGE_START - $DHCP_RANGE_END"
}

# ==================== 系统准备与清理 ====================

auto_install_deps() {
  step "检查并安装依赖..."
  sudo apt update -qq
  sudo apt install -y dnsmasq nginx syslinux-common pxelinux grub-efi-amd64-signed shim-signed nfs-kernel-server net-tools
}

disable_systemd_resolved() {
  info "临时释放端口 53..."
  sudo systemctl stop systemd-resolved 2>/dev/null || true
  sudo systemctl mask systemd-resolved 2>/dev/null || true
}

enable_systemd_resolved() {
  info "恢复 systemd-resolved..."
  sudo systemctl unmask systemd-resolved 2>/dev/null || true
  sudo systemctl start systemd-resolved 2>/dev/null || true
}

force_clean_ports() {
  info "清理端口占用 (53, 67, 69, 80)..."
  for port in 53 67 69 80; do
    local pids=$(sudo lsof -i :$port -P -n 2>/dev/null | grep -v PID | awk '{print $2}' | sort -u | tr '\n' ' ')
    if [ -n "$pids" ]; then
      warn "端口 $port 被占用 ($pids)，正在终止..."
      echo $pids | xargs sudo kill -9 2>/dev/null || true
    fi
  done
  sleep 1
}

cleanup() {
  info "🧹 正在清理环境..."
  enable_systemd_resolved

  sudo systemctl stop dnsmasq 2>/dev/null || true
  sudo systemctl stop nfs-kernel-server 2>/dev/null || true
  sudo systemctl stop nginx 2>/dev/null || true

  # 清理 NFS
  sudo sed -i '/autopxe_ubuntu/d' /etc/exports
  sudo rm -f /etc/exports.d/pxe-autopxe.exports
  sudo exportfs -ra 2>/dev/null || true

  # 清理 Nginx
  sudo rm -f /etc/nginx/sites-enabled/pxe-autopxe.conf

  # 恢复 default nginx
  if [ -f /etc/nginx/sites-available/default ] && [ ! -L /etc/nginx/sites-enabled/default ]; then
    sudo ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
  fi

  # 卸载 ISO
  if mountpoint -q "$WORK_DIR/iso" 2>/dev/null; then
    sudo umount "$WORK_DIR/iso"
  fi

  # 保留 WORK_DIR 以便调试，但清空运行时文件？
  # 根据需求，脚本结束后清理临时运行状态，但保留 ISO 和目录结构方便下次用
  # 这里选择只清理生成的配置和挂载，保留目录
  rm -rf "$WORK_DIR/tftpboot"/*
  rm -f "$WORK_DIR/dnmasq.conf" "$WORK_DIR/pxe.conf"

  info "✅ 清理完成。目录 $WORK_DIR 已保留。"
}

trap cleanup EXIT

# ==================== 主流程 ====================

main() {
  echo -e "${BLUE}=============================================${NC}"
  echo -e "${BLUE}   Smart AutoPXE for Ubuntu (Universal)      ${NC}"
  echo -e "${BLUE}=============================================${NC}"

  # 1. 准备工作目录
  if [ ! -d "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR"
    info "创建工作目录: $WORK_DIR"
  fi

  # 2. 寻找 ISO
  find_iso

  # 3. 识别 ISO 类型
  detect_iso_type

  # 4. 获取网络配置
  get_network_config

  # 5. 安装依赖 & 环境检查
  auto_install_deps
  force_clean_ports
  disable_systemd_resolved

  # 停止旧服务以防万一
  sudo systemctl stop dnsmasq nfs-kernel-server nginx 2>/dev/null || true
  sudo rm -rf /etc/dnsmasq.d/*

  # 6. 准备文件结构
  step "部署 PXE 引导文件..."
  mkdir -p "$WORK_DIR"/{iso,tftpboot/pxelinux.cfg,tftpboot/grub/x86_64-efi,tftpboot/EFI/boot}

  # 挂载 ISO
  if ! mountpoint -q "$WORK_DIR/iso"; then
    sudo mount -o loop "$ISO_FILE" "$WORK_DIR/iso" || err "ISO 挂载失败"
  fi

  # 复制内核 (根据识别结果)
  info "复制内核文件 ($KERNEL_PATH)..."
  if [ ! -f "$WORK_DIR/iso/$KERNEL_PATH" ]; then
    # 尝试备用路径 (某些旧版 server)
    if [ -f "$WORK_DIR/iso/install/vmlinuz" ]; then
      KERNEL_PATH="install/vmlinuz"
      INITRD_PATH="install/initrd.gz"
      warn "自动切换到备用内核路径: $KERNEL_PATH"
    else
      err "即使在备用路径也找不到内核！ISO 结构异常。"
    fi
  fi

  sudo cp -f "$WORK_DIR/iso/$KERNEL_PATH" "$WORK_DIR/tftpboot/vmlinuz"
  sudo cp -f "$WORK_DIR/iso/$INITRD_PATH" "$WORK_DIR/tftpboot/initrd"

  # 复制引导加载程序
  sudo cp -f /usr/lib/PXELINUX/pxelinux.0 "$WORK_DIR/tftpboot/"
  sudo cp -f /usr/lib/syslinux/modules/bios/ldlinux.c32 "$WORK_DIR/tftpboot/"

  # UEFI 文件 (通用)
  if [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
    sudo cp -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed "$WORK_DIR/tftpboot/grubx64.efi"
    sudo cp -f /usr/lib/shim/shimx64.efi.signed "$WORK_DIR/tftpboot/bootx64.efi"
    sudo cp -r /usr/lib/grub/x86_64-efi/* "$WORK_DIR/tftpboot/grub/x86_64-efi/"
  else
    warn "未找到签名的 UEFI 引导文件，UEFI 启动可能失败。请安装 grub-efi-amd64-signed"
  fi

  # 7. 生成配置文件
  step "生成引导配置 (自适应 $DETECTED_TYPE)..."

  # --- BIOS Config ---
  # 关键：根据版本和类型调整参数
  # 24.04+ Desktop/Server Live: boot=casper netboot=nfs
  # 22.04 Server (Legacy): maybe different? Usually casper works for live iso.
  # 如果是真正的 minimal iso (non-live)，参数不同。这里假设都是 Live ISO (22.04+/24.04+)

  local append_args=""
  if [[ "$BOOT_PARAM_TYPE" == "desktop" ]]; then
    # Desktop 通常进入试用模式，然后安装
    append_args="boot=casper netboot=nfs nfsroot=$SERVER_IP:$WORK_DIR/iso ip=dhcp quiet splash ---"
  else
    # Server Live ISO
    # 24.04+ 推荐添加 autoinstall 如果需要自动化，这里先给手动模式
    append_args="boot=casper netboot=nfs nfsroot=$SERVER_IP:$WORK_DIR/iso ip=dhcp ---"
  fi

  cat >"$WORK_DIR/tftpboot/pxelinux.cfg/default" <<EOF
DEFAULT install
LABEL install
    KERNEL vmlinuz
    APPEND initrd=initrd $append_args
EOF

  # --- UEFI Config ---
  cat >"$WORK_DIR/tftpboot/grub.cfg" <<EOF
set default="0"
set timeout=5
menuentry "Install $DETECTED_TYPE ($DETECTED_VERSION)" {
    set root=(tftp,$SERVER_IP)
    linux /vmlinuz $append_args
    initrd /initrd
}
EOF
  sudo cp -f "$WORK_DIR/tftpboot/grub.cfg" "$WORK_DIR/tftpboot/EFI/boot/grubx64.cfg"
  sudo cp -f "$WORK_DIR/tftpboot/grub.cfg" "$WORK_DIR/tftpboot/grub/grub.cfg"

  # 8. 配置 NFS
  step "配置 NFS 共享..."
  local NFS_ENTRY="$WORK_DIR/iso *(ro,sync,no_root_squash,no_subtree_check)"
  if [ -d "/etc/exports.d" ]; then
    echo "$NFS_ENTRY" | sudo tee /etc/exports.d/pxe-autopxe.exports
  else
    # 备份并追加
    sudo cp /etc/exports /etc/exports.bak
    echo "$NFS_ENTRY" | sudo tee -a /etc/exports
  fi
  sudo exportfs -ra
  sudo systemctl restart nfs-kernel-server

  # 9. 配置 Nginx (预留 preseed 接口，虽然本次是手动安装)
  step "配置 Nginx..."
  cat >"$WORK_DIR/pxe.conf" <<EOF
server {
    listen 80;
    server_name $SERVER_IP;
    location / {
        root $WORK_DIR;
        autoindex on;
    }
}
EOF
  sudo ln -sf "$WORK_DIR/pxe.conf" /etc/nginx/sites-enabled/pxe-autopxe.conf
  sudo rm -f /etc/nginx/sites-enabled/default # 避免端口 80 冲突
  sudo systemctl restart nginx

  # 10. 配置 Dnsmasq
  step "配置 DHCP/TFTP (dnsmasq)..."
  cat >"$WORK_DIR/dnsmasq.conf" <<EOF
interface=$INTERFACE
bind-interfaces
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,$NETMASK,1h
dhcp-option=3,$ROUTER_IP
dhcp-option=6,$ROUTER_IP,$DNS_SERVERS

# BIOS
dhcp-match=set:bios,option:client-arch,0
dhcp-boot=tag:bios,pxelinux.0,$SERVER_IP

# UEFI x86_64
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-boot=tag:efi-x86_64,bootx64.efi,$SERVER_IP

enable-tftp
tftp-root=$WORK_DIR/tftpboot
log-dhcp
EOF

  # 测试配置
  if ! sudo dnsmasq --test -C "$WORK_DIR/dnsmasq.conf"; then
    err "Dnsmasq 配置测试失败!"
  fi

  # 启动
  echo -e "${GREEN}=============================================${NC}"
  echo -e "${GREEN}✅ PXE 服务已就绪! ${NC}"
  echo -e "📦 镜像: $(basename "$ISO_FILE")"
  echo -e "💻 类型: $DETECTED_TYPE"
  echo -e "🌐 服务 IP: $SERVER_IP"
  echo -e "🔌 网卡: $INTERFACE"
  echo -e "📡 DHCP 范围: $DHCP_RANGE_START - $DHCP_RANGE_END"
  echo -e "---------------------------------------------"
  echo -e "👉 请将目标电脑设置为网络启动 (PXE)"
  echo -e "👉 目标电脑将获得 IP 并进入 $DETECTED_TYPE 安装界面"
  echo -e "⚠️  按 Ctrl+C 停止服务并清理环境"
  echo -e "${GREEN}=============================================${NC}"

  # 前台运行 dnsmasq
  sudo dnsmasq -k -C "$WORK_DIR/dnsmasq.conf"
}

# 执行
main
