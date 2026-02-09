
#!/bin/bash

# Константы путей и портов
WG_CONF="/etc/wireguard/wg0.conf"
UP_SCRIPT="/etc/wireguard/up.sh"
CLIENT_DIR="/root/wg_clients"
SSH_CONF="/etc/ssh/sshd_config"

# Динамическое определение текущих портов 
SSH_PORT=$(grep "^Port " $SSH_CONF | awk '{print $2}'); SSH_PORT=${SSH_PORT:-10022}
WG_PORT=$(grep "ListenPort" $WG_CONF 2>/dev/null | awk '{print $3}'); WG_PORT=${WG_PORT:-51820}

# Проверка прав root 
[ "$EUID" -ne 0 ] && echo "Запустите через sudo!" && exit 1

# Определяем IP сервера
echo "Определяем IP сервера..."
CACHED_IP=$(curl -4 -s --connect-timeout 2 ifconfig.me)

# --- ГЛОБАЛЬНАЯ ФУНКЦИЯ СОЗДАНИЯ КОНФИГА (С QR и подписями)  ---
generate_peer_config() {
    local NAME=$1; local IP=$2; local DNS_SRV=$3; local PUB_K=$4; local IS_ROUTER=$5; local USER_LAN=$6
    local CP=$(wg genkey); local CB=$(echo "$CP" | wg pubkey)
    echo -e "\n[Peer]\n# Client: $NAME\nPublicKey = $CB\nAllowedIPs = $([ "$IS_ROUTER" == "true" ] && echo "$IP/32, $USER_LAN" || echo "$IP/32")" >> $WG_CONF
    mkdir -p $CLIENT_DIR
    cat <<EOF > $CLIENT_DIR/$NAME.conf
[Interface]
PrivateKey = $CP
Address = $IP/24
DNS = $DNS_SRV
[Peer]
PublicKey = $PUB_K
Endpoint = $CACHED_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
}

# --- ФУНКЦИЯ ВИЗУАЛИЗАЦИИ ИНФРАСТРУКТУРЫ (СО СТАТУСОМ ПАРОЛЯ)  ---
show_infra() {
    PASS_AUTH=$(grep "^PasswordAuthentication" $SSH_CONF | awk '{print $2}')
    [ "$PASS_AUTH" == "yes" ] && SSH_STATUS="\e[1;31mВКЛЮЧЕН (⚠️ НЕБЕЗОПАСНО!)\e[0m" || SSH_STATUS="\e[1;32mОТКЛЮЧЕН (ТОЛЬКО КЛЮЧИ)\e[0m"

    GW_IP=$(ip -4 route | grep default | awk '{print $3}')
    R_IP=$(grep -a -oP '(?<=--to-destination )\d+\.\d+\.\d+\.\d+' $UP_SCRIPT 2>/dev/null | head -1)
    [ -z "$R_IP" ] && R_IP="Не определен"
    LAN_VAL=$(grep -a -A 2 "# Client: Router" $WG_CONF 2>/dev/null | grep "AllowedIPs" | awk -F', ' '{print $2}')
    [ -z "$LAN_VAL" ] && LAN_VAL="Не определена"

    echo -e "\n\e[1;34m=== ТЕКУЩАЯ ИНФРАСТРУКТУРА ===\e[0m"
    echo -e "VPS IP:      \e[1;32m${CACHED_IP:-...}\e[0m (SSH Port: $SSH_PORT)"
    echo -e "SSH Вход:    $SSH_STATUS"
    echo -e "Gateway IP:  $GW_IP"
    echo -e "Router IP:   \e[1;33m$R_IP\e[0m (WG Port: $WG_PORT)"
    echo -e "Home LAN:    \e[1;35m$LAN_VAL\e[0m"
    echo -e "-------------------------------------------"
    echo -e "АКТИВНЫЕ ПОРТЫ И ЗЕРКАЛЬНЫЕ ЛИМИТЫ (DL/UL):"
    grep -a -oP '(?<=--dport )\d+' $UP_SCRIPT 2>/dev/null | sort -u | while read -r p; do
        echo -e "  [Port] \e[1;32m$p\e[0m --> \e[1;33mRouter:$p\e[0m"
    done
    echo -e "\e[1;31mАКТИВНЫЕ ЛИМИТЫ ЮЗЕРОВ:\e[0m"
    grep -a "rate" $UP_SCRIPT 2>/dev/null | grep -a "dev wg0" | grep -a "# Client:" | sed 's/.*rate //; s/ceil.*# / --> /' | while read -r line; do
        echo -e "  [Speed] \e[1;36m$line\e[0m"
    done
    echo -e "-------------------------------------------\n"
}

# --- УПРАВЛЕНИЕ БЕЗОПАСНОСТЬЮ (SSH + WG)  ---
manage_security() {
    clear
    echo -e "=== 🔐 ЦЕНТР БЕЗОПАСНОСТИ ==="
    echo "1) Переключить SSH пароль (Вкл/Выкл)"
    echo "2) Изменить SSH порт (сейчас: $SSH_PORT)"
    echo "3) Изменить WireGuard порт (сейчас: $WG_PORT)"
    echo "0) Назад"
    read -p "Выбор: " S_OPT

    case $S_OPT in
        1) echo -e "\n1) ВКЛЮЧИТЬ\n2) ОТКЛЮЧИТЬ"
           read -p "Выбор: " P_VAL
           EXTRA_CONFS="/etc/ssh/sshd_config.d/*.conf"
           if [ "${P_VAL:-1}" == "2" ]; then
               sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' $SSH_CONF
               sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' $SSH_CONF
               [ -d "/etc/ssh/sshd_config.d" ] && sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' $EXTRA_CONFS 2>/dev/null
               echo "✅ Пароли выключены."
           else
               sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' $SSH_CONF
               sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' $SSH_CONF
               echo "✅ Пароли включены."
           fi
           systemctl restart ssh ;;
        2) read -p "Новый SSH порт: " NEW_SSH
           if [[ "$NEW_SSH" =~ ^[0-9]+$ ]]; then
               ufw delete allow "$SSH_PORT/tcp"
               ufw allow "$NEW_SSH/tcp"
               sed -i "s/^Port .*/Port $NEW_SSH/" $SSH_CONF
               SSH_PORT=$NEW_SSH
               systemctl restart ssh
               echo "✅ SSH теперь на порту $NEW_SSH."
           fi ;;
        3) read -p "Новый WG порт: " NEW_WG
           if [[ "$NEW_WG" =~ ^[0-9]+$ ]]; then
               ufw delete allow "$WG_PORT/udp"
               ufw allow "$NEW_WG/udp"
               sed -i "s/ListenPort = .*/ListenPort = $NEW_WG/" $WG_CONF
               sed -i "s/Endpoint = \(.*\):.*/Endpoint = \1:$NEW_WG/" $CLIENT_DIR/*.conf
               WG_PORT=$NEW_WG
               systemctl restart wg-quick@wg0
               echo "✅ WG порт изменен на $NEW_WG. Конфиги юзеров обновлены."
           fi ;;
    esac
    read -p "Enter..." temp
}

# --- ПРИМЕНЕНИЕ ЛИМИТОВ (Учитываем exit 0)  ---
apply_mirror_limit() {
    local NAME=$1; local IP=$2; local SPEED=$3
    local ID_CLASS=$(echo $IP | cut -d. -f4)
    sed -i '/^exit 0/d' $UP_SCRIPT
    echo "tc class add dev wg0 parent 1:1 classid 1:$ID_CLASS htb rate ${SPEED}mbit ceil ${SPEED}mbit # Client:$NAME || true" >> $UP_SCRIPT
    echo "tc filter add dev wg0 protocol ip parent 1:0 prio 1 u32 match ip dst $IP flowid 1:$ID_CLASS # Client:$NAME || true" >> $UP_SCRIPT
    echo "tc class add dev ifb0 parent 1:1 classid 1:$ID_CLASS htb rate ${SPEED}mbit ceil ${SPEED}mbit # Client:$NAME || true" >> $UP_SCRIPT
    echo "tc filter add dev ifb0 protocol ip parent 1:0 prio 1 u32 match ip src $IP flowid 1:$ID_CLASS # Client:$NAME || true" >> $UP_SCRIPT
    echo "exit 0" >> $UP_SCRIPT
}

# --- ПОЛНАЯ УСТАНОВКА (С ПОДПИСЯМИ ПОДСЕТЕЙ)  ---
full_setup() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    REAL_IF=$(ip -4 route show default | awk '/default/ {print $5}')
    clear
    echo "=== 🛠 ПОЛНАЯ УСТАНОВКА СИСТЕМЫ ==="

    while true; do
        echo -e "\n--- 1. Подсеть VPN ---"
        echo -e "1) 10.252.1.0/24\n2) 10.0.0.0/24\n3) 10.8.0.0/24\n4) 172.16.0.0/24\n5) 192.168.10.0/24\n6) 10.10.10.0/24\n7) 172.20.0.0/24"
        read -p "Выбор [1]: " WG_SUB_CHOICE
        case ${WG_SUB_CHOICE:-1} in
            2) WG_SUBNET="10.0.0.0/24" ;; 3) WG_SUBNET="10.8.0.0/24" ;; 4) WG_SUBNET="172.16.0.0/24" ;;
            5) WG_SUBNET="192.168.10.0/24" ;; 6) WG_SUBNET="10.10.10.0/24" ;; 7) WG_SUBNET="172.20.0.0/24" ;;
            *) WG_SUBNET="10.252.1.0/24" ;;
        esac
        WG_BASE=$(echo $WG_SUBNET | cut -d. -f1-3)
        if ip route | grep -v "wg0" | grep -q "$WG_BASE"; then
            echo -e "\e[1;31m⚠️ ОШИБКА: Конфликт подсети!\e[0m"
            continue
        fi
        break
    done

    echo -e "\n--- 2. Выберите DNS ---"
    echo -e "1) Quad9 (9.9.9.9)\n2) Google (8.8.8.8)\n3) Cloudflare (1.1.1.1)\n4) AdGuard (94.140.14.14)\n5) Cisco\n6) CleanBrowsing\n7) Mullvad"
    read -p "Выбор [1]: " DNS_CHOICE
    case ${DNS_CHOICE:-1} in
        2) USER_DNS="8.8.8.8" ;; 3) USER_DNS="1.1.1.1" ;; 4) USER_DNS="94.140.14.14" ;;
        5) USER_DNS="208.67.222.222" ;; 6) USER_DNS="185.228.168.9" ;; 7) USER_DNS="194.242.2.2" ;;
        *) USER_DNS="9.9.9.9" ;;
    esac

    echo -e "\n--- 3. Выберите домашнюю подсеть ---"
    echo -e "1) 192.168.1.0/24  (Keenetic / ASUS / TP-Link)"
    echo -e "2) 192.168.0.0/24  (D-Link / TP-Link)"
    echo -e "3) 192.168.31.0/24 (Xiaomi)"
    echo -e "4) 192.168.88.0/24 (MikroTik)"
    echo -e "5) 10.0.1.0/24     (Apple / Custom)"
    echo -e "6) Вручную"
    read -p "Выбор [1]: " LAN_CHOICE
    case ${LAN_CHOICE:-1} in
        2) USER_LAN="192.168.0.0/24" ;; 3) USER_LAN="192.168.31.0/24" ;; 4) USER_LAN="192.168.88.0/24" ;;
        5) USER_LAN="10.0.1.0/24" ;; 6) read -p "Ввод: " USER_LAN ;; *) USER_LAN="192.168.1.0/24" ;;
    esac

    read -p "4. Порты проброса (через пробел): " USER_PORTS
    apt-get update -y && apt-get install -y ufw wireguard fail2ban qrencode curl jq iptables iproute2
    ufw --force reset
    ufw allow "$SSH_PORT/tcp" && ufw allow "$WG_PORT/udp"
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    echo "y" | ufw enable
    sed -i "/^Port /d" $SSH_CONF && echo "Port $SSH_PORT" >> $SSH_CONF
    systemctl restart ssh

    # --- ИСПРАВЛЕННЫЙ ALIAS (Smart Alias v.13.50)  ---
    REAL_PATH=$(realpath "$0")
    if ! grep -q "alias vps=" ~/.bashrc; then
        echo "alias vps='sudo $REAL_PATH'" >> ~/.bashrc
    fi

    SERVER_IP="${WG_BASE}.1"; ROUTER_IP="${WG_BASE}.2"; IPHONE_IP="${WG_BASE}.3"
    cat <<EOF > $UP_SCRIPT
#!/bin/bash
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s $WG_SUBNET -o $REAL_IF -j MASQUERADE
iptables -t nat -A POSTROUTING -d $ROUTER_IP -o wg0 -j MASQUERADE
iptables -A FORWARD -i wg0 -j ACCEPT
iptables -A FORWARD -o wg0 -j ACCEPT
tc qdisc del dev wg0 root 2>/dev/null || true
tc qdisc del dev wg0 ingress 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true
ip link set dev ifb0 down 2>/dev/null; ip link delete ifb0 2>/dev/null
modprobe act_mirred 2>/dev/null; modprobe ifb numifbs=1 2>/dev/null
ip link add name ifb0 type ifb 2>/dev/null; ip link set dev ifb0 up 2>/dev/null
tc qdisc add dev wg0 handle ffff: ingress || true
tc filter add dev wg0 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 || true
tc qdisc add dev wg0 root handle 1: htb default 10 || true
tc class add dev wg0 parent 1: classid 1:1 htb rate 1gbit || true
tc qdisc add dev ifb0 root handle 1: htb default 10 || true
tc class add dev ifb0 parent 1: classid 1:1 htb rate 1gbit || true
EOF

    for port in $USER_PORTS; do
        ufw allow "$port"
        echo "iptables -t nat -A PREROUTING -i $REAL_IF -p tcp --dport $port -j DNAT --to-destination $ROUTER_IP:$port # Port:$port" >> $UP_SCRIPT
        echo "iptables -t nat -A PREROUTING -i $REAL_IF -p udp --dport $port -j DNAT --to-destination $ROUTER_IP:$port # Port:$port" >> $UP_SCRIPT
    done
    echo "exit 0" >> $UP_SCRIPT
    chmod +x $UP_SCRIPT

    SERVER_PRIV=$(wg genkey); SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)
    cat <<EOF > $WG_CONF
[Interface]
Address = $SERVER_IP/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIV
PostUp = $UP_SCRIPT
PostDown = iptables -t nat -F; iptables -P FORWARD ACCEPT; ip link delete ifb0 2>/dev/null
EOF
    generate_peer_config "Router" "$ROUTER_IP" "$USER_DNS" "$SERVER_PUB" "true" "$USER_LAN"
    generate_peer_config "iPhone" "$IPHONE_IP" "$USER_DNS" "$SERVER_PUB" "false" ""
    systemctl enable wg-quick@wg0 && systemctl restart wg-quick@wg0
    echo -e "✅ Установка завершена!"
    echo -e "\e[1;33m⚠️ Чтобы команда 'vps' заработала прямо сейчас, введите: source ~/.bashrc\e[0m"
    read -p "Enter..." temp
}

# --- ГЛАВНОЕ МЕНЮ  ---
while true; do
    clear; show_infra
    echo "=== 🛡️ VPS MANAGER v.13.50 (Full Labels) ==="
    echo -e "1) ПОЛНАЯ УСТАНОВКА\n2) 🔐 БЕЗОПАСНОСТЬ (SSH/Порты)\n3) ДОБАВИТЬ ПОРТ\n4) УДАЛИТЬ ПОРТ\n5) ДОБАВИТЬ ЮЗЕРА (QR)\n6) УДАЛИТЬ ЮЗЕРА\n7) ИЗМЕНИТЬ ЛИМИТ\n0) ВЫХОД"
    read -p "Действие: " M
    case $M in
        1) full_setup ;;
        2) manage_security ;;
        3) read -p "Порт: " N_PORT; [ -z "$N_PORT" ] && continue
           ufw allow "$N_PORT"
           sed -i '/^exit 0/d' $UP_SCRIPT
           R_IP=$(grep -a -oP '(?<=--to-destination )\d+\.\d+\.\d+\.\d+' $UP_SCRIPT | head -1)
           echo "iptables -t nat -A PREROUTING -i $REAL_IF -p tcp --dport $N_PORT -j DNAT --to-destination $R_IP:$N_PORT # Port:$N_PORT" >> $UP_SCRIPT
           echo "iptables -t nat -A PREROUTING -i $REAL_IF -p udp --dport $N_PORT -j DNAT --to-destination $R_IP:$N_PORT # Port:$N_PORT" >> $UP_SCRIPT
           echo "exit 0" >> $UP_SCRIPT
           systemctl restart wg-quick@wg0 ;;
        4) read -p "Порт для удаления: " D_PORT; [ -z "$D_PORT" ] && continue
           sed -i "/# Port:$D_PORT$/d" $UP_SCRIPT && ufw delete allow "$D_PORT" && systemctl restart wg-quick@wg0 ;;
        5) read -p "Имя: " NAME; [ -z "$NAME" ] && continue
           read -p "Лимит (Мбит): " SPEED
           BASE=$(grep -a "Address" $WG_CONF | head -1 | awk '{print $3}' | cut -d. -f1-3)
           LAST=$(grep -a "AllowedIPs" $WG_CONF | tail -1 | awk '{print $3}' | cut -d. -f4 | cut -d/ -f1)
           NEW_IP="${BASE}.$((LAST + 1))"; S_PUB=$(grep -a "PrivateKey" $WG_CONF | awk '{print $3}' | wg pubkey)
           generate_peer_config "$NAME" "$NEW_IP" "9.9.9.9" "$S_PUB" "false" ""
           [ "$SPEED" -ne 0 ] && apply_mirror_limit "$NAME" "$NEW_IP" "$SPEED"
           systemctl restart wg-quick@wg0
           qrencode -t ansiutf8 < $CLIENT_DIR/$NAME.conf && read -p "Done. Enter..." temp ;;
        6) grep -a "# Client:" $WG_CONF | awk '{print $3}'
           read -p "Имя для удаления: " D_NAME; [ -z "$D_NAME" ] && continue
           sed -i "/# Client: $D_NAME/,+3d" $WG_CONF && sed -i "/# Client:$D_NAME/d" $UP_SCRIPT && rm -f $CLIENT_DIR/$D_NAME.conf && systemctl restart wg-quick@wg0 ;;
        7) grep -a "# Client:" $WG_CONF | awk '{print $3}'
           read -p "Имя: " C_NAME; [ -z "$C_NAME" ] && continue
           C_IP=$(grep -a -A 2 "# Client: $C_NAME" $WG_CONF | grep "AllowedIPs" | awk '{print $3}' | cut -d/ -f1)
           read -p "Новый лимит: " NEW_S; sed -i "/# Client:$C_NAME/d" $UP_SCRIPT
           [ "$NEW_S" -ne 0 ] && apply_mirror_limit "$C_NAME" "$C_IP" "$NEW_S" && systemctl restart wg-quick@wg0 ;;
        0) exit 0 ;;
    esac
done
