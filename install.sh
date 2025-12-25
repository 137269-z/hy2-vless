#!/bin/bash

# ================= 配置区域 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 内部固定端口 (VLESS 监听此端口，Tunnel 转发到此端口)
LOCAL_PORT=10081

# ================= 1. 环境检查 =================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

arch=$(uname -m)
if [[ $arch == "x86_64" ]]; then
    ARCH_VAL="amd64"
elif [[ $arch == "aarch64" ]]; then
    ARCH_VAL="arm64"
else
    echo -e "${RED}不支持的架构: $arch${PLAIN}"
    exit 1
fi

clear
echo -e "${GREEN}============================================${PLAIN}"
echo -e "${GREEN}   NAT VPS 全能脚本: VLESS(Tunnel) + Hy2    ${PLAIN}"
echo -e "${GREEN}   Sing-box 核心 | 支持交互式配置 | 自动安装 ${PLAIN}"
echo -e "${GREEN}============================================${PLAIN}"
echo ""

# ================= 2. 交互式配置 (核心) =================

# --- 2.1 设置 Hy2 端口 ---
echo -e "${YELLOW}[1/4] 设置 Hysteria 2 UDP 端口${PLAIN}"
echo -e "提示：NAT 小鸡请务必查看商家给了你哪些端口可用！"
read -p "请输入端口号: " HY2_PORT
if [[ -z "$HY2_PORT" ]]; then
    echo -e "${RED}端口不能为空！脚本退出。${PLAIN}"
    exit 1
fi
echo -e "已设置 Hy2 端口: ${GREEN}$HY2_PORT${PLAIN}\n"

# --- 2.2 设置 UUID ---
echo -e "${YELLOW}[2/4] 设置 UUID (密码)${PLAIN}"
read -p "请输入自定义 UUID (直接回车则随机生成): " USER_UUID
if [[ -z "$USER_UUID" ]]; then
    USER_UUID=$(cat /proc/sys/kernel/random/uuid)
    echo -e "已自动生成 UUID: ${GREEN}$USER_UUID${PLAIN}"
else
    echo -e "已使用自定义 UUID: ${GREEN}$USER_UUID${PLAIN}"
fi
echo ""

# --- 2.3 设置 CF Tunnel ---
echo -e "${YELLOW}[3/4] 设置 Cloudflare Tunnel Token${PLAIN}"
echo -e "模式 A (固定)：输入 CF 后台获取的 Token (推荐)。"
echo -e "模式 B (临时)：直接回车，使用 TryCloudflare 临时域名 (重启会变)。"
read -p "请输入 Token: " CF_TOKEN

if [[ -n "$CF_TOKEN" ]]; then
    # --- 2.4 设置域名 (仅固定模式需要) ---
    echo -e "\n${YELLOW}[4/4] 设置绑定域名${PLAIN}"
    echo -e "请输入你在 Tunnel Public Hostname 绑定的完整域名 (如 vps.abc.com)"
    echo -e "脚本需要它来生成分享链接："
    read -p "请输入域名: " CF_DOMAIN
    if [[ -z "$CF_DOMAIN" ]]; then
        echo -e "${RED}固定隧道模式必须填写域名！${PLAIN}"
        exit 1
    fi
    TUNNEL_MODE="fixed"
else
    TUNNEL_MODE="temp"
    echo -e "\n已选择: ${GREEN}临时隧道模式${PLAIN}"
fi

echo -e "\n${GREEN}配置收集完毕，开始安装...${PLAIN}\n"
sleep 2

# ================= 3. 安装组件 =================
apt update -y && apt install -y curl wget tar jq openssl iptables

# --- 安装 Sing-box ---
echo -e "${YELLOW}>>> 安装 Sing-box...${PLAIN}"
TAG=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
[ -z "$TAG" ] && TAG="v1.8.0" # Fallback
TAG_NO_V=${TAG#v}
wget -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG_NO_V}-linux-${ARCH_VAL}.tar.gz"
tar -zxvf sing-box.tar.gz
mv sing-box-*/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf sing-box*

# --- 生成自签名证书 (Hy2 必须) ---
mkdir -p /etc/sing-box
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout /etc/sing-box/private.key \
    -out /etc/sing-box/cert.pem \
    -subj "/CN=www.bing.com" >/dev/null 2>&1

# --- 写入 Sing-box 配置 ---
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": $LOCAL_PORT,
      "users": [{ "uuid": "$USER_UUID", "flow": "" }]
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$USER_UUID" }],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      },
      "ignore_client_bandwidth": false
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

# --- 启动 Sing-box ---
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable sing-box && systemctl restart sing-box

# ================= 4. 配置 Cloudflare Tunnel =================
echo -e "${YELLOW}>>> 安装 Cloudflared...${PLAIN}"
wget -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_VAL}"
chmod +x /usr/local/bin/cloudflared

# 停止旧服务
systemctl stop cloudflared 2>/dev/null
cloudflared service uninstall 2>/dev/null

if [[ "$TUNNEL_MODE" == "fixed" ]]; then
    echo -e "${YELLOW}>>> 正在注册固定隧道...${PLAIN}"
    cloudflared service install "$CF_TOKEN"
    systemctl start cloudflared
    echo -e "${GREEN}固定隧道已启动！${PLAIN}"
else
    echo -e "${YELLOW}>>> 正在启动临时隧道...${PLAIN}"
    # 临时模式后台运行
    nohup cloudflared tunnel --url http://127.0.0.1:$LOCAL_PORT > /tmp/cf.log 2>&1 &
    echo -e "正在获取域名 (等待 8 秒)..."
    sleep 8
    CF_DOMAIN=$(grep -o 'https://.*\.trycloudflare.com' /tmp/cf.log | head -n 1 | sed 's/https:\/\///')
fi

# 获取公网 IP (用于 Hy2)
PUBLIC_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)

# ================= 5. 输出结果 =================
clear
echo -e "${GREEN}===========================================${PLAIN}"
echo -e "${GREEN}           安装成功！节点配置如下            ${PLAIN}"
echo -e "${GREEN}===========================================${PLAIN}"
echo ""

echo -e "${YELLOW}--- 节点 1: VLESS (Cloudflare Tunnel) ---${PLAIN}"
if [[ -z "$CF_DOMAIN" ]]; then
    echo -e "${RED}获取域名失败，请检查 Tunnel Token 或网络状态。${PLAIN}"
else
    echo -e "地址(Address): ${GREEN}$CF_DOMAIN${PLAIN}"
    echo -e "端口(Port):    ${GREEN}443${PLAIN}"
    echo -e "UUID:          ${GREEN}$USER_UUID${PLAIN}"
    echo -e "传输方式:      ${GREEN}WS${PLAIN}"
    echo -e "TLS:           ${GREEN}开启${PLAIN}"
    echo -e "链接: vless://$USER_UUID@$CF_DOMAIN:443?encryption=none&security=tls&type=ws&host=$CF_DOMAIN&path=%2F#Tunnel-VLESS"
fi

echo -e ""
echo -e "${YELLOW}--- 节点 2: Hysteria 2 (直连极速) ---${PLAIN}"
echo -e "地址(Address): ${GREEN}$PUBLIC_IP${PLAIN}"
echo -e "端口(Port):    ${GREEN}$HY2_PORT${PLAIN}"
echo -e "密码(Auth):    ${GREEN}$USER_UUID${PLAIN}"
echo -e "跳过证书验证:  ${GREEN}是 (AllowInsecure)${PLAIN}"
echo -e "链接: hysteria2://$USER_UUID@$PUBLIC_IP:$HY2_PORT?peer=www.bing.com&insecure=1&sni=www.bing.com#Direct-Hy2"

echo -e ""
echo -e "${GREEN}提示：NAT VPS 必须确保 UDP $HY2_PORT 端口已放行！${PLAIN}"
