#!/bin/bash

# Константы путей и портов [cite: 1]
WG_CONF="/etc/wireguard/wg0.conf"
UP_SCRIPT="/etc/wireguard/up.sh"
CLIENT_DIR="/root/wg_clients"
SSH_CONF="/etc/ssh/sshd_config"
IPSET_CONF="/etc/ipset/whitelist.conf"
SSH_KEY_DIR="/etc/wireguard/ssh_key" 

# --- АВТОМАТИЧЕСКОЕ ОБНОВЛЕНИЕ БАЗ GEOIP ДЛЯ CRON ---
if [ "$1" == "update_geoip" ]; then
    # (берём из метки в up.sh)
    COUNTRIES=$(grep -oP '(?<=# GeoIP_Countries: ).*' "$UP_SCRIPT" 2>/dev/null)
    
    if [ -n "$COUNTRIES" ]; then
        # Обновляем базы, не трогая правила iptables
        ipset create whitelist hash:net -! 2>/dev/null
        ipset flush whitelist
        for country in $COUNTRIES; do
            if curl -s -f "http://www.ipdeny.com/ipblocks/data/countries/${country,,}.zone" > /tmp/country.zone; then
                while read -r line; do ipset add whitelist "$line" -! 2>/dev/null; done < /tmp/country.zone
            fi
        done
        ipset save whitelist > "$IPSET_CONF"
        # Записываем лог
        echo "$(date '+%d.%m.%Y %H:%M'): GeoIP Updated ($COUNTRIES)" >> /var/log/vps_geoip.log
    fi
    exit 0
fi
# --- 🌍 ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ (Твой оригинал) ---
REAL_IF=$(ip -4 route show default | awk '/default/ {print $5}')
SSH_PORT=$(grep "^Port " $SSH_CONF | awk '{print $2}'); SSH_PORT=${SSH_PORT:-10022}
WG_PORT=$(grep "ListenPort" $WG_CONF 2>/dev/null | awk '{print $3}'); WG_PORT=${WG_PORT:-51820}

# Проверка прав root
[ "$EUID" -ne 0 ] && echo "Запустите через sudo!" && exit 1
CACHED_IP=$(curl -4 -s --connect-timeout 2 ifconfig.me)

# --- ГЛОБАЛЬНАЯ ФУНКЦИЯ СОЗДАНИЯ КОНФИГА С QR
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

# --- ФУНКЦИЯ ВИЗУАЛИЗАЦИИ ИНФРАСТРУКТУРЫ
show_infra() {
    echo -e " \e[1;32m"
    echo "  __     ______   _____   __  __          _   _          _____ ______ _____  "
    echo "  \ \    / /  __ \ / ____| |  \/  |   /\   | \ | |   /\   / ____|  ____|  __ \ "
    echo "   \ \  / /| |__) | (___   | \  / |  /  \  |  \| |  /  \ | |  __| |__  | |__) |"
    echo "    \ \/ / |  ___/ \___ \  | |\/| | / /\ \ | . \` | / /\ \| | |_ |  __| |  _  / "
    echo "     \  /  | |     ____) | | |  | |/ ____ \| |\  |/ ____ \ |__| | |____| | \ \ "
    echo "      \/   |_|    |_____/  |_|  |_/_/    \_\_| \_/_/    \_\_____|______|_|  \_\\"
    echo -e "                          \e[1;34m🔥 СИСТЕМА УПРАВЛЕНИЯ VPS 🔥\e[0m"
	# Ищем активную строку, если её нет или она закомментирована — проверяем значение по умолчанию
PASS_AUTH=$(grep -v "^#" $SSH_CONF | grep "PasswordAuthentication" | awk '{print $2}')
# Если переменная пустая, обычно в SSH по умолчанию стоит 'yes'
[ "${PASS_AUTH:-yes}" == "yes" ] && SSH_STATUS="\e[1;31mВКЛЮЧЕН Pass (⚠️ НЕБЕЗОПАСНО!)\e[0m" || SSH_STATUS="\e[1;32mОТКЛЮЧЕН (ТОЛЬКО КЛЮЧИ)\e[0m"
    GEO_STATUS="\e[1;31mОТКЛЮЧЕН\e[0m"; grep -q "match-set whitelist" $UP_SCRIPT 2>/dev/null && GEO_STATUS="\e[1;32mАКТИВЕН\e[0m"

    GW_IP=$(ip -4 route | grep default | awk '{print $3}')
    R_IP=$(grep -a -oP '(?<=--to-destination )\d+\.\d+\.\d+\.\d+' $UP_SCRIPT 2>/dev/null | head -1)
    [ -z "$R_IP" ] && R_IP="Не определен"
    LAN_VAL=$(grep -a -A 2 "# Client: Router" $WG_CONF 2>/dev/null | grep "AllowedIPs" | awk -F', ' '{print $2}')
    [ -z "$LAN_VAL" ] && LAN_VAL="Не определена"

    echo -e "\n\e[1;34m=== 📋 ТЕКУЩАЯ ИНФРАСТРУКТУРА ===\e[0m"
    echo -e "🌐 VPS IP:      \e[1;32m${CACHED_IP:-...}\e[0m (SSH Port: $SSH_PORT)"
    echo -e "🔑 SSH Pass/Key:    $SSH_STATUS | 🌍 GeoIP: $GEO_STATUS"
    echo -e "🛣️ Gateway IP:  $GW_IP"
    echo -e "🏠 Router IP:   \e[1;33m$R_IP\e[0m (WG Port: $WG_PORT)"
    echo -e "🏢 Home LAN:    \e[1;35m$LAN_VAL\e[0m"
    echo -e "-------------------------------------------"
    echo -e "🔌 АКТИВНЫЕ ПОРТЫ И ЗАЩИТА (RATE LIMIT):"
    grep -a -oP '(?<=--dport )\d+' $UP_SCRIPT 2>/dev/null | sort -u | while read -r p; do
        LIM=$(grep -a "hitcount" $UP_SCRIPT | grep "dport $p" | head -1 | awk -F'--hitcount ' '{print $2}' | awk '{print $1}')
        SEC=$(grep -a "seconds" $UP_SCRIPT | grep "dport $p" | head -1 | awk -F'--seconds ' '{print $2}' | awk '{print $1}')
        [ -z "$LIM" ] && PROT="\e[1;31mOFF\e[0m" || PROT="\e[1;32m$LIM поп./$SEC сек.\e[0m"
        echo -e "  [Port] \e[1;32m$p\e[0m --> \e[1;33mRouter:$p\e[0m (Limit: $PROT)"
    done
   echo -e "\e[1;31m🚀 КЛИЕНТЫ И СКОРОСТЬ:\e[0m"
    grep -a "# Client:" $WG_CONF | awk '{print $3}' | while read -r name; do
        LIMIT_VAL=$(grep -a "# Client:$name" $UP_SCRIPT | grep "rate" | head -1 | awk -F'rate ' '{print $2}' | awk '{print $1}')
        if [ -n "$LIMIT_VAL" ]; then
            printf "  👤 \e[1;32m%-10s\e[0m --> \e[1;36m%s Mbit\e[0m\n" "$name" "$LIMIT_VAL"
        else
            printf "  👤 \e[1;32m%-10s\e[0m --> \e[1;35m♾️ Unlimited\e[0m\n" "$name"
        fi
    done
    echo -e "-------------------------------------------\n"
}

# --- УПРАВЛЕНИЕ БЕЗОПАСНОСТЬЮ (SSH + КЛЮЧИ) ---
manage_security() {

    SSH_KEY_DIR="/etc/wireguard/ssh_key"
    mkdir -p "$SSH_KEY_DIR" && chmod 700 "$SSH_KEY_DIR"

   while true; do
        clear
        # 1. Получаем дату из лога
        LAST_UP=$(tail -n 1 /var/log/vps_geoip.log 2>/dev/null | cut -d: -f1-2)
        [ -z "$LAST_UP" ] && LAST_UP="Никогда"
        
        # 2. Проверяем статус Крона
        CRON_ST=$(crontab -l 2>/dev/null | grep -q "update_geoip" && echo -e "\e[1;32mВКЛ\e[0m" || echo -e "\e[1;31mВЫКЛ\e[0m")

        echo -e "=== 🔐 ЦЕНТР БЕЗОПАСНОСТИ ==="
        echo "1) 🔑 Переключить SSH пароль (Вкл/Выкл)"
        echo "2) 🚀 Изменить SSH порт"
        echo "3) 🛰 Изменить WireGuard порт"
        echo "4) 🌍 Настроить GeoIP (Белый список стран)"
        echo "5) 🛡 ОТКЛЮЧИТЬ Rate Limit"
        echo "6) 🔓 ОТКЛЮЧИТЬ GeoIP фильтрацию"
        echo -e "7) \e[1;32m🔑 УПРАВЛЕНИЕ SSH КЛЮЧАМИ\e[0m"
        # Твой новый пункт 8:
        echo -e "8) 🔄 Автообновление GeoIP [ $CRON_ST ] | Last: \e[1;33m$LAST_UP\e[0m"
        echo "0) 🔙 Назад"
        read -p "Выбор: " S_OPT
        
case $S_OPT in
            1) PASS_AUTH=$(grep "^PasswordAuthentication" $SSH_CONF | awk '{print $2}')
               [ "$PASS_AUTH" == "yes" ] && VAL="no" || VAL="yes"
               sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication $VAL/" $SSH_CONF
               sed -i "s/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication $VAL/" $SSH_CONF
               systemctl restart ssh ;;
            2) read -p "Новый SSH порт: " NEW_SSH
               if [[ "$NEW_SSH" =~ ^[0-9]+$ ]]; then
                   ufw delete allow "$SSH_PORT/tcp" && ufw allow "$NEW_SSH/tcp"
                   sed -i "s/^Port .*/Port $NEW_SSH/" $SSH_CONF
                   SSH_PORT=$NEW_SSH; systemctl restart ssh
               fi ;;
            3) read -p "Новый WG порт: " NEW_WG
               if [[ "$NEW_WG" =~ ^[0-9]+$ ]]; then
                   ufw delete allow "$WG_PORT/udp" && ufw allow "$NEW_WG/udp"
                   sed -i "s/ListenPort = .*/ListenPort = $NEW_WG/" $WG_CONF
                   sed -i "s/Endpoint = \(.*\):.*/Endpoint = \1:$NEW_WG/" $CLIENT_DIR/*.conf
                   WG_PORT=$NEW_WG; systemctl restart wg-quick@wg0
               fi ;;
           4) echo "Введите коды стран через пробел (например: ru by kz):"
           read -p "Страны: " COUNTRIES; [ -z "$COUNTRIES" ] && return
           ipset create whitelist hash:net -! 2>/dev/null
           ipset flush whitelist
           for country in $COUNTRIES; do
               echo "📥 Загрузка базы для ${country^^}..."
               if curl -s -f "http://www.ipdeny.com/ipblocks/data/countries/${country,,}.zone" > /tmp/country.zone; then
                   while read -r line; do ipset add whitelist "$line" -! 2>/dev/null; done < /tmp/country.zone
                   echo "✅ ${country^^} добавлена."
               fi
           done
           mkdir -p /etc/ipset && ipset save whitelist > $IPSET_CONF
           
           # ---(Метка для Крона) ---
           sed -i '/# GeoIP_Countries:/d' "$UP_SCRIPT"
           echo "# GeoIP_Countries: $COUNTRIES" >> "$UP_SCRIPT"
           # ------------------------------------------

           sed -i '/match-set whitelist/d' $UP_SCRIPT
           sed -i '/ipset restore/d' $UP_SCRIPT
           sed -i "8i ipset restore -! < $IPSET_CONF || true" $UP_SCRIPT
           sed -i "9i iptables -I FORWARD -i $REAL_IF -m state --state NEW -m set ! --match-set whitelist src -j DROP # GeoIP" $UP_SCRIPT
           
           ipset restore -! < $IPSET_CONF
           
           iptables -C FORWARD -i $REAL_IF -m state --state NEW -m set ! --match-set whitelist src -j DROP 2>/dev/null || iptables -I FORWARD -i $REAL_IF -m state --state NEW -m set ! --match-set whitelist src -j DROP
           echo "✅ GeoIP фильтр включен.";;

            5) sed -i '/-m recent/d' $UP_SCRIPT; bash $UP_SCRIPT; echo "✅ Защита портов снята." ;;
            6) # Удаляем правила фильтрации из файла up.sh
           sed -i '/match-set whitelist/d' $UP_SCRIPT
           sed -i '/ipset restore/d' $UP_SCRIPT
           # Удаляем само правило из текущей сессии iptables, не трогая очереди tc
           iptables -D FORWARD -i $REAL_IF -m state --state NEW -m set ! --match-set whitelist src -j DROP 2>/dev/null
           ipset destroy whitelist 2>/dev/null
           echo "✅ GeoIP отключен." ;;
            7) # === ПОДМЕНЮ SSH КЛЮЧЕЙ ===
                          while true; do
                   clear
                   echo -e "=== 🔑 УПРАВЛЕНИЕ SSH КЛЮЧАМИ ==="
                   echo "1) 🆕 Сгенерировать новый ключ"
                   echo "2) 📋 Tаблицa ключей ssh (SFTP пути)"
                   echo "3) 📤 Экспорт приватного ключа в консоль"
                   echo "0) 🔙 Назад"
                   read -p "Выбор: " K_OPT
                   case $K_OPT in
                       1) read -p "Имя ключа (напр: work_laptop): " K_NAME
                          [ -z "$K_NAME" ] && continue
                          ssh-keygen -t ed25519 -f "$SSH_KEY_DIR/$K_NAME" -N "" -q
                          cat "$SSH_KEY_DIR/$K_NAME.pub" >> ~/.ssh/authorized_keys
                          chmod 600 ~/.ssh/authorized_keys
                          echo -e "✅ Ключ \e[1;32m$K_NAME\e[0m добавлен на сервер." ;;
                       2) echo -e "\n\e[1;33m=== 📋 ТАБЛИЦА КЛЮЧЕЙ ДЛЯ СКАЧИВАНИЯ (SFTP) ===\e[0m"
                          printf "  \e[1;32m%-15s\e[0m | \e[1;36m%-35s\e[0m\n" "ИМЯ" "ПУТЬ ДЛЯ SFTP"
                          echo "------------------------------------------------------------------"
                          ls "$SSH_KEY_DIR"/*.pub 2>/dev/null | while read pub; do
                              name=$(basename "$pub" .pub)
                              printf "  %-15s | %-35s\n" "$name" "$SSH_KEY_DIR/$name"
                          done ;;
                       3) echo "Доступные приватные ключи:"
                          ls "$SSH_KEY_DIR" 2>/dev/null | grep -v ".pub"
                          read -p "Имя ключа: " E_NAME
                          if [ -f "$SSH_KEY_DIR/$E_NAME" ]; then
                              echo -e "\n\e[1;31m⚠️ СКОПИРУЙ ТЕКСТ И СОХРАНИ В ФАЙЛ НА ПК (vps.key):\e[0m\n"
                              cat "$SSH_KEY_DIR/$E_NAME"
                              echo -e "\n\e[1;31m--------------------------------------------------\e[0m"
                          fi ;;
                       0) break ;;
                   esac
                   read -p "Enter..." temp
               done ;;
8) echo "Автообновление GeoIP (Пн, 03:00):"
               echo "1) Включить"
               echo "2) Выключить"
               read -p "Выбор: " G_OPT
               # Команда ссылается на алиас vps, созданный при установке
               CRON_JOB="0 3 * * 1 /usr/local/bin/vps update_geoip > /dev/null 2>&1"
               
               if [ "$G_OPT" == "1" ]; then
                   (crontab -l 2>/dev/null | grep -v "update_geoip"; echo "$CRON_JOB") | crontab -
                   echo "✅ Автообновление в расписание добавлено."
               elif [ "$G_OPT" == "2" ]; then
                   crontab -l 2>/dev/null | grep -v "update_geoip" | crontab -
                   echo "❌ Автообновление отключено."
               fi ;;
            0) return ;;
        esac
        read -p "Enter..." temp
    done
}
# --- ПРИМЕНЕНИЕ ЛИМИТОВ   ---
apply_mirror_limit() {
    local NAME=$1; local IP=$2; local SPEED=$3
    local ID_CLASS=$(echo $IP | cut -d. -f4)
    # Удаляем exit 0 перед записью новых команд
    sed -i '/^exit 0/d' $UP_SCRIPT
    echo "tc class add dev wg0 parent 1:1 classid 1:$ID_CLASS htb rate ${SPEED}mbit ceil ${SPEED}mbit # Client:$NAME || true" >> $UP_SCRIPT
    echo "tc filter add dev wg0 protocol ip parent 1:0 prio 1 u32 match ip dst $IP flowid 1:$ID_CLASS # Client:$NAME || true" >> $UP_SCRIPT
    echo "tc class add dev ifb0 parent 1:1 classid 1:$ID_CLASS htb rate ${SPEED}mbit ceil ${SPEED}mbit # Client:$NAME || true" >> $UP_SCRIPT
    echo "tc filter add dev ifb0 protocol ip parent 1:0 prio 1 u32 match ip src $IP flowid 1:$ID_CLASS # Client:$NAME || true" >> $UP_SCRIPT
    echo "exit 0" >> $UP_SCRIPT
}

# --- ПОЛНАЯ УСТАНОВКА
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
            echo -e "\e[1;31m⚠️ ОШИБКА: Конфликт подсети!⚠️\e[0m"
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
    echo -e "1) 192.168.1.0/24 (Keenetic)\n2) 192.168.0.0/24 (D-Link/Tp-Link)\n3) 192.168.31.0/24 (Xiaomi)\n4) 192.168.88.0/24 (MikroTik)\n5) 10.0.1.0/24 (Apple)\n6) Вручную"
    read -p "Выбор [1]: " LAN_CHOICE
    case ${LAN_CHOICE:-1} in
        2) USER_LAN="192.168.0.0/24" ;; 3) USER_LAN="192.168.31.0/24" ;; 4) USER_LAN="192.168.88.0/24" ;;
        5) USER_LAN="10.0.1.0/24" ;; 6) read -p "Ввод: " USER_LAN ;; *) USER_LAN="192.168.1.0/24" ;;
    esac

    read -p "4. Порты проброса  (через пробел 80 443 8090): " USER_PORTS
    apt-get update -y && apt-get install -y ufw wireguard fail2ban qrencode curl jq iptables iproute2 ipset
    ufw --force reset
    ufw allow "$SSH_PORT/tcp" && ufw allow "$WG_PORT/udp"
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    echo "y" | ufw enable
    # ... (после установки пакетов и настройки UFW) ...

    # 1. Удаляем все строки Port
    sed -i '/^#\?Port /d' "$SSH_CONF"
    sed -i "1i Port $SSH_PORT" "$SSH_CONF"
    
    # 2. Проверяем конфиг
    if sshd -t; then
        echo "⚙️ Конфиг SSH корректен. Применяем порт $SSH_PORT..."

        # 3. Отключаем сокет-активацию, которая блокирует смену порта
        systemctl stop ssh.socket > /dev/null 2>&1
        systemctl disable ssh.socket > /dev/null 2>&1
        
        # 4. Перезагружаем демоны
        systemctl daemon-reload

        # 5. Перезапускаем классическую службу SSH
        systemctl restart ssh || systemctl restart sshd
        
        # 6. Проверка: реально ли мы переехали на новый порт?
        sleep 2
        if ss -tlpn | grep -q ":$SSH_PORT "; then
            echo -e "\e[1;32m✅ SSH успешно запущен на порту $SSH_PORT\e[0m"
        else
            echo -e "\e[1;31m❌ Порт не применился! Пробую аварийный перезапуск...\e[0m"
            systemctl stop ssh && systemctl start ssh
        fi
    else
        echo -e "\e[1;31m⚠️ Ошибка в конфиге SSH! Проверь синтаксис.\e[0m"
    fi

    # команда vps
    cp "$0" /usr/local/bin/vps
    chmod +x /usr/local/bin/vps
    
    if ! grep -q "alias vps=" ~/.bashrc; then
        echo "alias vps='sudo vps'" >> ~/.bashrc
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
    systemctl enable wg-quick@wg0 && systemctl restart wg-quick@wg0
    clear
echo -e "\e[1;32m=============================================\e[0m"
echo -e "\e[1;32m✅ УСТАНОВКА ЗАВЕРШЕНА! Новый порт SSH: $SSH_PORT ⚠️\e[0m"
echo -e "\e[1;32m=============================================\e[0m"
echo -e "\n\e[1;33m📁 Конфигурационный файл роутера создан скачать по SFTP:\e[0m"
echo -e "\e[1;36m$CLIENT_DIR/Router.conf\e[0m"
echo -e "\n\e[1;33m🚀 Как зайти в меню повторно:\e[0m"
echo -e "Просто введите команду: \e[1;32mvps\e[0m"
echo -e "\e[1;32m=============================================\e[0m"
read -p "Нажмите Enter, чтобы вернуться в меню..." temp
}

# --- УПРАВЛЕНИЕ WEB-ИНТЕРФЕЙСОМ (ВКЛ/ВЫКЛ) ---
manage_web_panel() {
    while true; do
        clear
        # Проверка статуса службы
        ST_WEB=$(systemctl is-active --quiet ttyd && echo -e "\e[1;32mВКЛ\e[0m" || echo -e "\e[1;31mВЫКЛ\e[0m")
        echo -e "=== 🌐 УПРАВЛЕНИЕ WEB-ПАНЕЛЬЮ [ $ST_WEB ] ==="

        if systemctl is-active --quiet ttyd; then
            echo -e "1) 🛑 Полностью ВЫКЛЮЧИТЬ веб-панель"
        else
            echo -e "1) 🚀 ВКЛЮЧИТЬ и настроить доступ"
        fi
        echo "0) 🔙 Назад"
        read -p "Выбор: " W_OPT

        case $W_OPT in
            1) 
                if systemctl is-active --quiet ttyd; then
                    # --- ШАГ: ЗАКРЫТИЕ ПОРТА ПЕРЕД ВЫКЛЮЧЕНИЕМ ---
                    OLD_PORT=$(grep "ExecStart" /etc/systemd/system/ttyd.service 2>/dev/null | grep -oP '(?<=-p )\d+')
                    if [ -n "$OLD_PORT" ]; then
                        ufw delete allow "$OLD_PORT/tcp" > /dev/null 2>&1
                    fi
                    
                    systemctl stop ttyd && systemctl disable ttyd
                    echo "❌ Панель и порты выключены."
                else
                    # --- ШАГ: УСТАНОВКА TTYD (ЕСЛИ НЕТ) ---
                    if [ ! -f /usr/bin/ttyd ]; then
                        echo "📥 Загрузка бинарного файла ttyd..."
                        curl -L -o /usr/bin/ttyd https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64
                        chmod +x /usr/bin/ttyd
                    fi
                    
                    # --- ШАГ: НАСТРОЙКА ДОСТУПА ---
                    read -p "Введите логин для веб [admin]: " WU
                    WU=${WU:-admin}
                    read -p "Введите пароль для веб [admin]: " WP
                    WP=${WP:-admin}

                    read -p "Введите порт для панели [17681]: " W_PORT
                    W_PORT=${W_PORT:-17681}

                    echo -e "\nВыберите режим доступа к панели:"
                    echo "1) Приватный (127.0.0.1) — только через SSH-туннель"
                    echo "2) Публичный (0.0.0.0) — доступ через внешний IP"
                    read -p "Выбор [1]: " W_MODE
                    
                    # Очистка старых правил перед открытием новых
                    OLD_PORT=$(grep "ExecStart" /etc/systemd/system/ttyd.service 2>/dev/null | grep -oP '(?<=-p )\d+')
                    [ -n "$OLD_PORT" ] && ufw delete allow "$OLD_PORT/tcp" > /dev/null 2>&1

                    if [ "$W_MODE" == "2" ]; then
                        W_IP="0.0.0.0"
                        ufw allow "$W_PORT/tcp" > /dev/null 2>&1
                        echo -e "⚠️ \e[1;31mВНИМАНИЕ: Порт $W_PORT открыт в UFW!\e[0m"
                    else
                        W_IP="127.0.0.1"
                        echo -e "✅ Доступ ограничен локальным интерфейсом."
                    fi

                    # --- ШАГ: СОЗДАНИЕ СЛУЖБЫ SYSTEMD ---
                    sudo tee /etc/systemd/system/ttyd.service > /dev/null <<EOF
[Unit]
Description=Web SSH Service
After=network.target

[Service]
# Принудительная установка окружения терминала
Environment="TERM=xterm-256color"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Запуск с флагом -c (Credentials)
ExecStart=/usr/bin/ttyd -i $W_IP -p $W_PORT -W -c "$WU:$WP" /bin/bash /usr/local/bin/vps
Restart=always
User=root
WorkingDirectory=/root

[Install]
WantedBy=multi-user.target
EOF

                    # --- ШАГ: ЗАПУСК СИСТЕМЫ ---
                    systemctl daemon-reload
                    systemctl enable ttyd
                    systemctl restart ttyd
                    
                    EXTERNAL_IP=$(curl -s ifconfig.me)
                    if [ "$W_IP" == "0.0.0.0" ]; then
                        echo -e "\n\e[1;32m✅ ПУБЛИЧНАЯ ПАНЕЛЬ ЗАПУЩЕНА!\e[0m"
                        echo -e "🌍 Ссылка: \e[1;36mhttp://$EXTERNAL_IP:$W_PORT\e[0m"
                    else
                        echo -e "\n\e[1;32m✅ ЛОКАЛЬНАЯ ПАНЕЛЬ ЗАПУЩЕНА!\e[0m"
                        echo -e "🔒 Ссылка: \e[1;36mhttp://127.0.0.1:$W_PORT\e[0m"
                        echo -e "ℹ️  Используйте туннель: \e[1;33mssh -L $W_PORT:127.0.0.1:$W_PORT root@$EXTERNAL_IP\e[0m"
                    fi
                fi 
                ;;
            0) break ;;
            *) echo "❌ Неверный выбор" ;;
        esac
        read -p "Нажми Enter..." temp
    done
}
show_tech_menu() {
    while true; do
        clear
        echo -e "=== ⚙️ ТЕХНИЧЕСКОЕ ОБСЛУЖИВАНИЕ ==="
        echo "1) 🔄 Рестарт SSH"
        echo "2) 🚀 Рестарт WireGuard (wg0)"
        echo "3) ▶️  Запуск WireGuard (wg0)"
        echo "4) 📊 Состояние WireGuard (wg show)"
        echo "5) 📂 Показать файлы в /etc/wireguard"
        echo "6) 📱 ПОКАЗАТЬ QR Выбранного пользователя"
        echo "7) 🌀 REBOOT (Перезагрузка всей системы)"
        echo -e "8) 🌐 \e[1;32mУПРАВЛЕНИЕ WEB-ПАНЕЛЬЮ\e[0m"
        echo "0) 🔙 Назад"
        read -p "Выбор: " T_OPT

        case $T_OPT in
            1) systemctl restart ssh && echo "✅ SSH перезапущен." ;;
            2) systemctl restart wg-quick@wg0 && echo "✅ WireGuard перезапущен." ;;
            3) systemctl start wg-quick@wg0 && echo "✅ WireGuard запущен." ;;
            4) echo -e "\n\e[1;32m--- Статус WireGuard ---\e[0m"; wg show; echo "------------------------" ;;
            5) echo -e "\n\e[1;33m--- 📂 ОСНОВНЫЕ КОНФИГИ (/etc/wireguard) ---\e[0m"
                      ls -F /etc/wireguard | grep -v "/"
                      echo -e "\n\e[1;36m--- 🔑 SSH КЛЮЧИ ($SSH_KEY_DIR) ---\e[0m"
                      [ -d "$SSH_KEY_DIR" ] && ls -F "$SSH_KEY_DIR" || echo "Папка не найдена"
                      echo -e "\n\e[1;35m--- 👤 КОНФИГИ КЛИЕНТОВ ($CLIENT_DIR) ---\e[0m"
                      [ -d "$CLIENT_DIR" ] && ls -F "$CLIENT_DIR" || echo "Папка не найдена"
                      echo -e "\n\e[1;33m------------------------------------------\e[0m" ;;
            6) grep -a "# Client:" $WG_CONF | awk '{print $3}'
               read -p "Имя юзера для QR: " QN
               [ -f "$CLIENT_DIR/$QN.conf" ] && qrencode -t ansiutf8 < "$CLIENT_DIR/$QN.conf" || echo "❌ Файл не найден!" ;;
            7) read -p "⚠️ ПЕРЕЗАГРУЗИТЬ VPS? (y/n): " CONFIRM
               [ "$CONFIRM" == "y" ] && reboot ;;
            8) manage_web_panel ;;
            0) break ;;
        esac
        read -p "Enter..." temp
    done
}
while true; do
    clear; show_infra
    echo "=== 🛡️ VPS MANAGER v.13.46  ==="
    echo -e "1) 🛠 ПОЛНАЯ УСТАНОВКА\n2) 🔐 ЦЕНТР БЕЗОПАСНОСТИ\n3) 🔌 ДОБАВИТЬ ПОРТ\n4) ❌ УДАЛИТЬ ПОРТ\n5) 👥 ДОБАВИТЬ ЮЗЕРА (QR)\n6) 🗑 УДАЛИТЬ ЮЗЕРА\n7) 🏎 ИЗМЕНИТЬ ЛИМИТ\n8) ⚙️ ТЕХ. ОБСЛУЖИВАНИЕ\n0) 🚪 ВЫХОД"
    read -p "Действие: " M
    case $M in
        1) full_setup ;;
        2) manage_security ;;
        3) read -p "Порт: " N_PORT; [ -z "$N_PORT" ] && continue
           echo "🛡 Защита (Rate Limit): 1)Стандарт 2)Строго 3)Выкл"; read -p "Выбор [1]: " P_PROT
           case $P_PROT in 2) H=5; S=120 ;; 3) H=0; S=0 ;; *) H=15; S=60 ;; esac
           ufw allow "$N_PORT"
           sed -i '/^exit 0/d' $UP_SCRIPT
           R_IP=$(grep -a -oP '(?<=--to-destination )\d+\.\d+\.\d+\.\d+' $UP_SCRIPT | head -1)
           if [ "$H" -ne 0 ]; then
               echo "iptables -I FORWARD -i $REAL_IF -p tcp --dport $N_PORT -m state --state NEW -m recent --set --name PORT_$N_PORT" >> $UP_SCRIPT
               echo "iptables -I FORWARD -i $REAL_IF -p tcp --dport $N_PORT -m state --state NEW -m recent --update --seconds $S --hitcount $H --name PORT_$N_PORT -j DROP" >> $UP_SCRIPT
           fi
           echo "iptables -t nat -A PREROUTING -i $REAL_IF -p tcp --dport $N_PORT -j DNAT --to-destination $R_IP:$N_PORT # Port:$N_PORT" >> $UP_SCRIPT
           echo "iptables -t nat -A PREROUTING -i $REAL_IF -p udp --dport $N_PORT -j DNAT --to-destination $R_IP:$N_PORT # Port:$N_PORT" >> $UP_SCRIPT
           echo "exit 0" >> $UP_SCRIPT
           systemctl restart wg-quick@wg0 ;;
        4) read -p "Порт для удаления: " D_PORT; [ -z "$D_PORT" ] && continue
           sed -i "/# Port:$D_PORT$/d" $UP_SCRIPT && ufw delete allow "$D_PORT" && systemctl restart wg-quick@wg0 ;;
        5) read -p "Имя: " NAME; [ -z "$NAME" ] && continue
           read -p "Лимит (Мбит 0 безлимит) [0]: " SPEED
           SPEED=${SPEED:-0} 

           BASE=$(grep -a "Address" $WG_CONF | head -1 | awk '{print $3}' | cut -d. -f1-3)
           LAST=$(grep -a "AllowedIPs" $WG_CONF | tail -1 | awk '{print $3}' | cut -d. -f4 | cut -d/ -f1)
           [ -z "$LAST" ] && LAST=1
           NEW_IP="${BASE}.$((LAST + 1))"
           S_PUB=$(grep -a "PrivateKey" $WG_CONF | awk '{print $3}' | wg pubkey)

           # 1. Генерируем конфиг
           generate_peer_config "$NAME" "$NEW_IP" "9.9.9.9" "$S_PUB" "false" ""
           
           # 2. Применяем лимит
           if [[ "$SPEED" =~ ^[0-9]+$ ]] && [ "$SPEED" -gt 0 ]; then
               apply_mirror_limit "$NAME" "$NEW_IP" "$SPEED"
           fi

           # 3. Перезапуск с проверкой результата
           echo -e "\n⏳ Перезапуск WireGuard..."
           if systemctl restart wg-quick@wg0; then
               echo -e "✅ Юзер $NAME успешно создан! (Speed: ${SPEED/0/Unlimited})"
               # QR только если всё запустилось успешно
               qrencode -t ansiutf8 < "$CLIENT_DIR/$NAME.conf"
           else
               echo -e "\e[1;31m❌ ОШИБКА: WireGuard не смог запуститься!\e[0m"
               echo -e "Скорее всего, в конфиге остался пустой [Peer]. Удали его вручную в nano."
           fi
           read -p "Нажми Enter для выхода в меню..." temp ;;
        6) echo -e "\e[1;33mАктивные пользователи:\e[0m"
           grep -a "# Client:" $WG_CONF | awk '{print $3}' | sort -u
           read -p "Имя для удаления: " D_NAME; [ -z "$D_NAME" ] && continue
           
           # 1. Находим строку с именем и удаляем блок вместе с [Peer]
           LINE_NUM=$(grep -n "# Client: $D_NAME" $WG_CONF | cut -d: -f1)
           if [ -n "$LINE_NUM" ]; then
               START_LINE=$((LINE_NUM - 1))
               # Удаляем от [Peer] до первой пустой строки
               sed -i "${START_LINE},/^$/d" $WG_CONF
           fi

           # 2. Авто-чистка: удаляем любые одинокие [Peer] в конце файла
           sed -i '/^\[Peer\]$/ { $d; N; /^[[:space:]]*$/d; }' $WG_CONF 2>/dev/null
           
           # 3. Чистим лимиты и файлы
           sed -i "/# Client:$D_NAME/d" $UP_SCRIPT
           rm -f "$CLIENT_DIR/$D_NAME.conf"
           
           echo -e "⏳ Перезапуск сети..."
           if systemctl restart wg-quick@wg0; then
               echo -e "✅ Пользователь $D_NAME удален. Конфиг идеально чист."
           else
               # Удаляем все пустые [Peer] принудительно
               sed -i '/^\[Peer\]$/d' $WG_CONF
               systemctl restart wg-quick@wg0
               echo -e "⚠️ Были найдены пустые секции, они удалены автоматически."
           fi
           read -p "Enter..." temp ;;
        7) grep -a "# Client:" $WG_CONF | awk '{print $3}'
           read -p "Имя: " C_NAME; [ -z "$C_NAME" ] && continue
           C_IP=$(grep -a -A 2 "# Client: $C_NAME" $WG_CONF | grep "AllowedIPs" | awk '{print $3}' | cut -d/ -f1)
           read -p "Новый лимит: " NEW_S; sed -i "/# Client:$C_NAME/d" $UP_SCRIPT
           [ "$NEW_S" -ne 0 ] && apply_mirror_limit "$C_NAME" "$C_IP" "$NEW_S" && systemctl restart wg-quick@wg0 ;;
         8) show_tech_menu ;;
        0) exit 0 ;;
    esac
 done
