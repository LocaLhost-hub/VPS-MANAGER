#!/bin/bash

# ЦВЕТА
green='\e[1;32m'
red='\e[1;31m'
yellow='\e[1;33m'
blue='\e[1;34m'
cyan='\e[1;36m'
plain='\e[0m'

# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
if ! command -v curl >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y curl >/dev/null 2>&1
fi

REAL_IF=$(ip -4 route show default | awk '/default/ {print $5}')
SSH_CONF="/etc/ssh/sshd_config"
WG_CONF="/etc/wireguard/wg0.conf"
UP_SCRIPT="/etc/wireguard/up.sh"
CLIENT_DIR="/root/wg_clients"
SSH_KEY_DIR="/etc/wireguard/ssh_key"
REPO_URL="https://raw.githubusercontent.com/LocaLhost-hub/VPS-MANAGER/main/bench.sh"
SSH_NOTIFY_SCRIPT="/usr/local/bin/vps_ssh_notify.sh"

SSH_PORT=$(grep "^Port " "$SSH_CONF" 2>/dev/null | awk '{print $2}'); SSH_PORT=${SSH_PORT:-10022}
WG_PORT=$(grep "ListenPort" "$WG_CONF" 2>/dev/null | awk '{print $3}'); WG_PORT=${WG_PORT:-51820}

[ "$EUID" -ne 0 ] && echo "Запустите через sudo!" && exit 1

# --- ОБРАБОТЧИК АВТООБНОВЛЕНИЯ GEOIP (ДЛЯ CRON) ---
if [ "$1" == "update_geoip" ]; then
    IPSET_CONF="/etc/ipset/whitelist.conf"
    LOG_FILE="/var/log/vps_geoip.log"
    COUNTRIES=$(grep "^# GeoIP_Countries:" "$UP_SCRIPT" 2>/dev/null | cut -d: -f2- | xargs)

    if [ -z "$COUNTRIES" ]; then
        echo "$(date '+%Y-%m-%d %H:%M'): GeoIP не настроен, пропуск." >> "$LOG_FILE"
        exit 0
    fi

    mkdir -p /etc/ipset
    ipset create whitelist hash:net -! 2>/dev/null
    ipset destroy whitelist_new 2>/dev/null
    ipset create whitelist_new hash:net -!

    UPDATED=0
    for country in $COUNTRIES; do
        c=$(echo "$country" | tr '[:upper:]' '[:lower:]')
        if curl -s -f --connect-timeout 10 "http://www.ipdeny.com/ipblocks/data/countries/${c}.zone" > /tmp/country_cron.zone; then
            while read -r line; do
                [ -n "$line" ] && ipset add whitelist_new "$line" -! 2>/dev/null
            done < /tmp/country_cron.zone
            UPDATED=1
        fi
    done
    rm -f /tmp/country_cron.zone

    if [ "$UPDATED" -eq 1 ]; then
        ipset swap whitelist_new whitelist
        ipset destroy whitelist_new 2>/dev/null
        ipset save whitelist > "$IPSET_CONF"
        echo "$(date '+%Y-%m-%d %H:%M'): Обновлено ($COUNTRIES)" >> "$LOG_FILE"
    else
        ipset destroy whitelist_new 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M'): Ошибка загрузки списков ($COUNTRIES)" >> "$LOG_FILE"
    fi
    exit 0
fi

# --- ОБРАБОТЧИК АВТОБЭКАПА В TELEGRAM (ДЛЯ CRON) ---
if [ "$1" == "backup_tg" ]; then
    BACKUP_DIR="/root/vps_backups"
    mkdir -p "$BACKUP_DIR"
    ARCHIVE="$BACKUP_DIR/vps_backup_$(date '+%Y-%m-%d_%H-%M-%S').tar.gz"
    PATHS=()
    [ -d /etc/wireguard ] && PATHS+=("/etc/wireguard")
    [ -d /root/wg_clients ] && PATHS+=("/root/wg_clients")
    [ -d /etc/ipset ] && PATHS+=("/etc/ipset")
    [ -f /root/.tg_config ] && PATHS+=("/root/.tg_config")

    if [ ${#PATHS[@]} -gt 0 ]; then
        tar -czf "$ARCHIVE" "${PATHS[@]}" 2>/dev/null
        if [ -f /root/.tg_config ]; then
            source /root/.tg_config
            if [ -n "$TOKEN" ] && [ -n "$ADMIN_ID" ]; then
                HOST_IP=$(curl -4 -s --connect-timeout 3 eth0.me || hostname)
                curl -s -F document=@"$ARCHIVE" \
                     -F caption="💾 Автобэкап VPS ($HOST_IP) — $(date '+%Y-%m-%d %H:%M')" \
                     "https://api.telegram.org/bot${TOKEN}/sendDocument?chat_id=${ADMIN_ID}" >/dev/null 2>&1
            fi
        fi
        ls -1t "$BACKUP_DIR"/vps_backup_*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
    fi
    exit 0
fi

CACHED_IP=$(curl -4 -s --connect-timeout 3 eth0.me || curl -4 -s --connect-timeout 3 ifconfig.me)

# Применение изменений пиров WireGuard без разрыва текущих соединений
reload_wg_peers() {
    if ip link show wg0 >/dev/null 2>&1; then
        wg syncconf wg0 <(wg-quick strip wg0)
    else
        systemctl restart wg-quick@wg0
    fi
}

# Форматирование байт в человекочитаемый вид
format_bytes() {
    local bytes=${1:-0}
    if [ "$bytes" -ge 1073741824 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1fG", b/1073741824}'
    elif [ "$bytes" -ge 1048576 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1fM", b/1048576}'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.0fK", b/1024}'
    else
        echo "${bytes}B"
    fi
}

generate_peer_config() {
    local NAME=$1; local IP=$2; local DNS_SRV=$3; local PUB_K=$4; local IS_ROUTER=$5
    local CP=$(wg genkey); local CB=$(echo "$CP" | wg pubkey)
    [ -n "$(tail -c 1 "$WG_CONF" 2>/dev/null)" ] && echo "" >> "$WG_CONF"

    echo "# Client: $NAME" >> "$WG_CONF"
    echo "[Peer]" >> "$WG_CONF"
    echo "PublicKey = $CB" >> "$WG_CONF"
    echo "AllowedIPs = $IP/32" >> "$WG_CONF"

    mkdir -p "$CLIENT_DIR"
    cat <<EOF > "$CLIENT_DIR/$NAME.conf"
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

show_infra() {
    clear
    echo -e " \e[1;32m"
    echo "  __     ______   _____   __  __          _   _          _____ ______ _____  "
    echo "  \ \    / /  __ \ / ____| |  \/  |   /\   | \ | |   /\   / ____|  ____|  __ \ "
    echo "   \ \  / /| |__) | (___   | \  / |  /  \  |  \| |  /  \ | |  __| |__  | |__) |"
    echo "    \ \/ / |  ___/ \___ \  | |\/| | / /\ \ | . \` | / /\ \| | |_ |  __| |  _  / "
    echo "     \  /  | |     ____) | | |  | |/ ____ \| |\  |/ ____ \ |__| | |____| | \ \ "
    echo "      \/   |_|    |_____/  |_|  |_/_/    \_\_| \_/_/    \_\_____|______|_|  \_\\"
    echo -e "                          \e[1;34m🔥 СИСТЕМА УПРАВЛЕНИЯ VPS v3.3 🔥\e[0m"

    GW_IP=$(ip -4 route show default | awk '/default/ {print $3}')
    VPN_NET=$(grep "^Address" "$WG_CONF" 2>/dev/null | awk '{print $3}' | head -1)

    CURRENT_SSH_PORT=$(grep "^Port " "$SSH_CONF" 2>/dev/null | awk '{print $2}')
    CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
    CURRENT_WG_PORT=$(grep "ListenPort" "$WG_CONF" 2>/dev/null | awk '{print $3}')
    CURRENT_WG_PORT=${CURRENT_WG_PORT:-51820}

    LOAD_AVG=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    RAM_INFO=$(free -m 2>/dev/null | awk '/Mem:/ {printf "%d/%dMB", $3, $2}')
    DISK_INFO=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')

    BBR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [ "$BBR_CC" == "bbr" ] && BBR_STATUS="\e[1;32mON\e[0m" || BBR_STATUS="\e[1;30mOFF\e[0m"

    if grep -q "clamp-mss-to-pmtu" "$UP_SCRIPT" 2>/dev/null; then
        MSS_STATUS="\e[1;32mON\e[0m"
    else
        MSS_STATUS="\e[1;30mOFF\e[0m"
    fi

    if grep -q "match-set whitelist" "$UP_SCRIPT" 2>/dev/null && [ -s /etc/ipset/whitelist.conf ]; then
        GEO_STATUS="\e[1;32mON (Вкл)\e[0m"
    else
        GEO_STATUS="\e[1;30mOFF (Выкл)\e[0m"
    fi

    if grep -qE "^iptables.*-A POSTROUTING.*-o wg0 -j MASQUERADE" "$UP_SCRIPT" 2>/dev/null; then
        REALIP_STATUS="\e[1;31mOFF (NAT)\e[0m"
    else
        REALIP_STATUS="\e[1;32mON (Real)\e[0m"
    fi

    if systemctl is-active --quiet ttyd; then
        SERV_CFG="/etc/systemd/system/ttyd.service"
        if grep -q "\-i 127.0.0.1" "$SERV_CFG" 2>/dev/null; then
             WEB_STATUS="\e[1;34m🔒 Local\e[0m"
        elif grep -q "\-C /root/cert" "$SERV_CFG" 2>/dev/null; then
             WEB_STATUS="\e[1;32m🔐 SSL\e[0m"
        else
             WEB_STATUS="\e[1;33m🌍 HTTP\e[0m"
        fi
    else
        WEB_STATUS="\e[1;31m❌ OFF\e[0m"
    fi

    PASS_AUTH=$(grep -v "^#" "$SSH_CONF" 2>/dev/null | grep "PasswordAuthentication" | awk '{print $2}')
    if [ "${PASS_AUTH:-yes}" == "yes" ]; then
        SSH_TXT="\e[1;31m🔓 PASS\e[0m"
    else
        SSH_TXT="\e[1;32m🔐 KEYS\e[0m"
    fi

    echo -e "\n\e[1;34m=== 📊 СВОДКА СЕРВЕРА ===\e[0m"
    printf " 📡 %-25s %-25s\n" "WAN: ${CACHED_IP:-...}" "GATEWAY: ${GW_IP:-ND}"
    printf " 🕸️ %-25s %-25s\n" "VPN: ${VPN_NET:-ND}"   "WG PORT: $CURRENT_WG_PORT"
    printf " 🖥️ WEB: %-34b 🌍 GEOIP: %-20b ⚡ BBR: %-12b 📏 MSS: %b\n" "$WEB_STATUS" "$GEO_STATUS" "$BBR_STATUS" "$MSS_STATUS"
    printf " 🛡️ SSH: %-34b PORT: %-10s 🌐 IP: %b\n" "$SSH_TXT" "$CURRENT_SSH_PORT" "$REALIP_STATUS"
    printf " 💻 CPU: %-12s 🧠 RAM: %-16s 💾 DISK: %s\n" "${LOAD_AVG:-0}" "${RAM_INFO:-ND}" "${DISK_INFO:-ND}"

    declare -A map_ports
    if [ -f "$UP_SCRIPT" ]; then
        while read -r line; do
            if [[ "$line" =~ --dport\ ([0-9]+).*--to-destination\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+) ]]; then
                 ext_port="${BASH_REMATCH[1]}"
                 dest_ip="${BASH_REMATCH[2]}"
                 int_port="${BASH_REMATCH[3]}"
                 if grep -q "dport $ext_port.*hitcount" "$UP_SCRIPT"; then p_icon="🛡️"; else p_icon=""; fi
                 if [ "$ext_port" == "$int_port" ]; then
                     entry="${ext_port}${p_icon}"
                 else
                     entry="${ext_port}:${int_port}${p_icon}"
                 fi
                 if [ -z "${map_ports[$dest_ip]}" ]; then 
                    map_ports[$dest_ip]="$entry"
                 else 
                    if [[ "${map_ports[$dest_ip]}" != *"$entry"* ]]; then 
                        map_ports[$dest_ip]="${map_ports[$dest_ip]}, $entry"
                    fi
                 fi
            fi
        done < "$UP_SCRIPT"
    fi

    # Сбор статусов онлайн и трафика из wg show wg0 dump
    declare -A map_online
    declare -A map_traffic
    NOW_TS=$(date +%s)
    if ip link show wg0 >/dev/null 2>&1; then
        while IFS=$'\t' read -r pub psk ep aips hs rx tx ka; do
            [ -z "$aips" ] && continue
            p_ip=$(echo "$aips" | cut -d',' -f1 | cut -d'/' -f1)
            if [ -n "$hs" ] && [ "$hs" -gt 0 ] && [ $((NOW_TS - hs)) -lt 180 ]; then
                map_online[$p_ip]="🟢"
            else
                map_online[$p_ip]="⚪"
            fi
            total_b=$(( ${rx:-0} + ${tx:-0} ))
            map_traffic[$p_ip]=$(format_bytes "$total_b")
        done < <(wg show wg0 dump 2>/dev/null | tail -n +2)
    fi

    echo -e "\n\e[1;34m=== 👥 СПИСОК КЛИЕНТОВ ===\e[0m"
    printf "\e[1;33m %-2s %-13s  %-15s  %-20s  %-10s  %-8s\e[0m\n" "ST" "CLIENT" "IP" "PORTS" "LIMIT" "TRAFFIC"
    echo " -----------------------------------------------------------------------------"

    if [ -f "$WG_CONF" ]; then
        current_name=""
        while read -r line; do
            if [[ "$line" =~ ^#\ Client:\ (.*) ]]; then
                current_name="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^(#PAUSED#)?AllowedIPs\ =\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                if [ -n "$current_name" ]; then
                    paused_tag="${BASH_REMATCH[1]}"
                    ip="${BASH_REMATCH[2]}"
                    if [ -n "$paused_tag" ]; then
                        st="⏸️"
                    else
                        st="${map_online[$ip]:-⚪}"
                    fi
                    traf="${map_traffic[$ip]:-0B}"
                    ports="${map_ports[$ip]}"
                    [ -z "$ports" ] && ports_d="\e[1;30m-\e[0m" || ports_d="\e[1;32m$ports\e[0m"
                    limit=$(grep -a "# Client:$current_name" "$UP_SCRIPT" 2>/dev/null | grep "rate" | head -1 | awk -F'rate ' '{print $2}' | awk '{print $1}' | sed 's/mbit//')

                    [ -z "$limit" ] && speed_d="\e[1;35m♾️ Unlim\e[0m" || speed_d="\e[1;33m📉 ${limit}Mb\e[0m"

                    # Подсветка если есть привязанные подсети (Site-to-Site)
                    lan_mark=""
                    [[ "$line" == *","* ]] && lan_mark="*"

                    printf " %s \e[1;37m%-13s\e[0m  %-15s  %-31b  %-19b  \e[1;36m%-8s\e[0m\n" "$st" "${current_name}${lan_mark}" "$ip" "$ports_d" "$speed_d" "$traf"
                    current_name=""
                fi
            fi
        done < "$WG_CONF"
    fi
    echo " -----------------------------------------------------------------------------"
    echo ""
}

manage_security() {
    mkdir -p "$SSH_KEY_DIR" && chmod 700 "$SSH_KEY_DIR"

    while true; do
        clear
        LAST_UP=$(tail -n 1 /var/log/vps_geoip.log 2>/dev/null | cut -d: -f1-2)
        [ -z "$LAST_UP" ] && LAST_UP="Никогда"
        CRON_ST=$(crontab -l 2>/dev/null | grep -q "update_geoip" && echo -e "\e[1;32mВКЛ\e[0m" || echo -e "\e[1;31mВЫКЛ\e[0m")

        if grep -qE "^iptables.*-A POSTROUTING.*-o wg0 -j MASQUERADE" "$UP_SCRIPT" 2>/dev/null; then
            REAL_IP_ST="\e[1;31mВЫКЛ (NAT)\e[0m"
        else
            REAL_IP_ST="\e[1;32mВКЛ\e[0m"
        fi

        if grep -q "clamp-mss-to-pmtu" "$UP_SCRIPT" 2>/dev/null; then
            MSS_ST="\e[1;32mВКЛ\e[0m"
        else
            MSS_ST="\e[1;31mВЫКЛ\e[0m"
        fi

        if grep -q "vps_ssh_notify.sh" /etc/pam.d/sshd 2>/dev/null; then
            SSH_ALERT_ST="\e[1;32mВКЛ\e[0m"
        else
            SSH_ALERT_ST="\e[1;31mВЫКЛ\e[0m"
        fi

        echo -e "=== 🔐 ЦЕНТР БЕЗОПАСНОСТИ ==="
        echo "1) 🔑 Переключить SSH пароль (Вкл/Выкл)"
        echo "2) 🚀 Изменить SSH порт"
        echo "3) 🛰 Изменить WireGuard порт"
        echo "4) 🌍 Настроить GeoIP (Белый список стран)"
        echo "5) 🛡 ОТКЛЮЧИТЬ Anti-DDoS"
        echo "6) 🔓 ОТКЛЮЧИТЬ GeoIP фильтрацию"
        echo -e "7) \e[1;32m🔑 УПРАВЛЕНИЕ SSH КЛЮЧАМИ\e[0m"
        echo -e "8) 🔄 Автообновление GeoIP [ $CRON_ST ] | Last: \e[1;33m$LAST_UP\e[0m"
        echo "9) 🚑 Разбанить IP"
        echo -e "10) 🌐 Реальные IP клиентов [ $REAL_IP_ST ]"
        echo -e "11) 📏 MSS Clamping (MTU фикс) [ $MSS_ST ]"
        echo -e "12) 📨 SSH-алерты в Telegram [ $SSH_ALERT_ST ]"
        echo "0) 🔙 Назад"
        read -p "Выбор: " S_OPT

        case $S_OPT in
            1) PASS_AUTH=$(grep "^PasswordAuthentication" "$SSH_CONF" | awk '{print $2}')
               [ "$PASS_AUTH" == "yes" ] && VAL="no" || VAL="yes"
               sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication $VAL/" "$SSH_CONF"
               sed -i "s/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication $VAL/" "$SSH_CONF"
               systemctl restart ssh ;;
            2) read -p "Новый SSH порт: " NEW_SSH
               if [[ "$NEW_SSH" =~ ^[0-9]+$ ]]; then
                   ufw delete allow "$SSH_PORT/tcp" && ufw allow "$NEW_SSH/tcp"
                   sed -i "s/^Port .*/Port $NEW_SSH/" "$SSH_CONF"
                   SSH_PORT=$NEW_SSH
                   systemctl restart ssh

                   echo "🛡 Обновляем Fail2Ban..."
                   cat <<EOF > /etc/fail2ban/jail.d/sshd-custom.local
[sshd]
enabled = true
port = $NEW_SSH
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF
                   systemctl restart fail2ban
                   echo "✅ Порт изменен, защита обновлена."
               fi ;;
            3) read -p "Новый WG порт: " NEW_WG
               if [[ "$NEW_WG" =~ ^[0-9]+$ ]]; then
                   ufw delete allow "$WG_PORT/udp" && ufw allow "$NEW_WG/udp"
                   sed -i "s/ListenPort = .*/ListenPort = $NEW_WG/" "$WG_CONF"
                   sed -i "s/Endpoint = \(.*\):.*/Endpoint = \1:$NEW_WG/" "$CLIENT_DIR"/*.conf 2>/dev/null
                   WG_PORT=$NEW_WG; systemctl restart wg-quick@wg0
               fi ;;
            4)
               IPSET_CONF="/etc/ipset/whitelist.conf"
               REAL_IF=$(ip -4 route show default | awk '/default/ {print $5}')

               echo "Введите коды стран через пробел (например: ru by kz):"
               read -p "Страны: " COUNTRIES; [ -z "$COUNTRIES" ] && continue

               mkdir -p /etc/ipset
               ipset create whitelist hash:net -! 2>/dev/null
               ipset flush whitelist

               for country in $COUNTRIES; do
                   echo "📥 Загрузка базы для ${country^^}..."
                   if curl -s -f "http://www.ipdeny.com/ipblocks/data/countries/${country,,}.zone" > /tmp/country.zone; then
                       while read -r line; do ipset add whitelist "$line" -! 2>/dev/null; done < /tmp/country.zone
                       echo "✅ ${country^^} добавлена."
                   fi
               done
               ipset save whitelist > "$IPSET_CONF"
               sed -i '/# GeoIP_Countries:/d' "$UP_SCRIPT"
               sed -i '/if \[ -s .*whitelist.* \]/,/fi/d' "$UP_SCRIPT"
               sed -i '/match-set whitelist/d' "$UP_SCRIPT"
               sed -i '/ipset restore/d' "$UP_SCRIPT"
               sed -i '/^exit 0/d' "$UP_SCRIPT"
               echo "# GeoIP_Countries: $COUNTRIES" >> "$UP_SCRIPT"
               cat <<EOF >> "$UP_SCRIPT"
if [ -s $IPSET_CONF ]; then
    ipset restore -! < $IPSET_CONF 2>/dev/null || true
    iptables -I FORWARD -i $REAL_IF -m state --state NEW -m set ! --match-set whitelist src -j DROP # GeoIP
fi
exit 0
EOF
               ipset restore -! < "$IPSET_CONF" 2>/dev/null
               iptables -D FORWARD -i "$REAL_IF" -m state --state NEW -m set ! --match-set whitelist src -j DROP 2>/dev/null
               iptables -I FORWARD -i "$REAL_IF" -m state --state NEW -m set ! --match-set whitelist src -j DROP
               echo "$(date '+%Y-%m-%d %H:%M'): Включено вручную ($COUNTRIES)" >> /var/log/vps_geoip.log
               echo "✅ GeoIP фильтр включен."
               ;;
            5)
               sed -i '/-m recent/d' "$UP_SCRIPT"
               iptables -F FORWARD
               bash "$UP_SCRIPT"
               rm -f /proc/net/xt_recent/* 2>/dev/null
               echo "✅ Защита портов ПОЛНОСТЬЮ снята." ;;
            6)
               REAL_IF=$(ip -4 route show default | awk '/default/ {print $5}')
               iptables -D FORWARD -i "$REAL_IF" -m state --state NEW -m set ! --match-set whitelist src -j DROP 2>/dev/null
               ipset destroy whitelist 2>/dev/null
               rm -f /etc/ipset/whitelist.conf
               sed -i '/if \[ -s .*whitelist.* \]/,/fi/d' "$UP_SCRIPT"
               sed -i '/match-set whitelist/d' "$UP_SCRIPT"
               sed -i '/ipset restore/d' "$UP_SCRIPT"
               sed -i '/# GeoIP_Countries/d' "$UP_SCRIPT"
               echo "✅ GeoIP полностью отключен."
               ;;
            7)
               while true; do
                   clear
                   echo -e "=== 🔑 УПРАВЛЕНИЕ SSH КЛЮЧАМИ ==="
                   echo "1) 🆕 Сгенерировать новый ключ"
                   echo "2) 📋 Таблица ключей ssh (SFTP пути)"
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
               echo "3) Запустить обновление прямо сейчас"
               read -p "Выбор: " G_OPT
               CRON_JOB="0 3 * * 1 /usr/local/bin/vps update_geoip > /dev/null 2>&1"

               if [ "$G_OPT" == "1" ]; then
                   (crontab -l 2>/dev/null | grep -v "update_geoip"; echo "$CRON_JOB") | crontab -
                   echo "✅ Автообновление в расписание добавлено."
               elif [ "$G_OPT" == "2" ]; then
                   crontab -l 2>/dev/null | grep -v "update_geoip" | crontab -
                   echo "❌ Автообновление отключено."
               elif [ "$G_OPT" == "3" ]; then
                   /usr/local/bin/vps update_geoip
                   echo "✅ Обновление выполнено. Лог: $(tail -n 1 /var/log/vps_geoip.log 2>/dev/null)"
               fi ;;
            9)
               echo -e "\n\e[1;34m=== 🚑 СПИСОК НАРУШИТЕЛЕЙ (Последние 20) ===\e[0m"
               if [ ! -d /proc/net/xt_recent ] || [ -z "$(ls -A /proc/net/xt_recent/ 2>/dev/null)" ]; then
                   echo "✅ Списки банов пусты или модуль не активен."
                   read -p "Enter..." temp; continue
               fi

               FOUND_ANY=0
               for file in /proc/net/xt_recent/*; do
                   [ -e "$file" ] || continue
                   list_name=$(basename "$file")
                   BANNED_IPS=$(grep "src=" "$file" | tail -n 20 | awk -F'src=' '{print $2}' | awk '{print $1}')

                   if [ -n "$BANNED_IPS" ]; then
                       echo -e "\e[1;33mСписок $list_name (показаны последние):\e[0m"
                       echo "$BANNED_IPS" | while read ip; do
                           echo -e "  [🔒] $ip"
                       done
                       FOUND_ANY=1
                   fi
               done

               if [ "$FOUND_ANY" -eq 0 ]; then
                   echo "✅ Нарушителей не обнаружено."
               else
                   echo "--------------------------------"
                   echo -e "Совет: Чтобы разбанить всех сразу, используйте пункт меню '5' (Выкл/Вкл защиты)."
                   read -p "Введите IP для точечного разбана: " UNBAN_IP

                   if [ -n "$UNBAN_IP" ]; then
                       UNBANNED_COUNT=0
                       for file in /proc/net/xt_recent/*; do
                           if grep -q "$UNBAN_IP" "$file"; then
                               echo "-$UNBAN_IP" > "$file"
                               echo -e "✅ IP $UNBAN_IP удален из списка $(basename "$file")"
                               UNBANNED_COUNT=1
                           fi
                       done

                       if [ "$UNBANNED_COUNT" -eq 0 ]; then
                           echo "⚠️ IP $UNBAN_IP не найден в списках."
                       fi
                   fi
               fi
               ;;
            10)
               if [ ! -f "$UP_SCRIPT" ]; then
                   echo "❌ Файл $UP_SCRIPT не найден! Сначала выполните установку."
               elif grep -qE "^iptables.*-A POSTROUTING.*-o wg0 -j MASQUERADE" "$UP_SCRIPT"; then
                   sed -i '/-o wg0 -j MASQUERADE/d' "$UP_SCRIPT"
                   while iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null; do :; done
                   VPN_SUB=$(grep "^Address" "$WG_CONF" 2>/dev/null | awk '{print $3}' | head -1 | sed 's/\.[0-9]*\//.0\//')
                   [ -n "$VPN_SUB" ] && while iptables -t nat -D POSTROUTING -d "$VPN_SUB" -o wg0 -j MASQUERADE 2>/dev/null; do :; done
                   echo -e "✅ Реальные IP \e[1;32mВКЛЮЧЕНЫ\e[0m (MASQUERADE на wg0 удален без разрыва связи)."
               else
                   sed -i '/^exit 0/d' "$UP_SCRIPT"
                   echo "iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE" >> "$UP_SCRIPT"
                   echo "exit 0" >> "$UP_SCRIPT"
                   iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
                   echo -e "⚠️ Реальные IP \e[1;31mВЫКЛЮЧЕНЫ\e[0m (включен MASQUERADE на wg0)."
               fi
               ;;
            11)
               if [ ! -f "$UP_SCRIPT" ]; then
                   echo "❌ Файл $UP_SCRIPT не найден!"
               elif grep -q "clamp-mss-to-pmtu" "$UP_SCRIPT"; then
                   sed -i '/clamp-mss-to-pmtu/d' "$UP_SCRIPT"
                   while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
                   echo -e "⚠️ MSS Clamping \e[1;31mВЫКЛЮЧЕН\e[0m."
               else
                   sed -i '/^exit 0/d' "$UP_SCRIPT"
                   echo "iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true" >> "$UP_SCRIPT"
                   echo "iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" >> "$UP_SCRIPT"
                   echo "exit 0" >> "$UP_SCRIPT"
                   iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
                   iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
                   echo -e "✅ MSS Clamping \e[1;32mВКЛЮЧЕН\e[0m (автоподстройка MTU для TCP)."
               fi
               ;;
            12)
               if grep -q "vps_ssh_notify.sh" /etc/pam.d/sshd 2>/dev/null; then
                   sed -i '/vps_ssh_notify\.sh/d' /etc/pam.d/sshd
                   rm -f "$SSH_NOTIFY_SCRIPT"
                   echo -e "⚠️ SSH-уведомления в Telegram \e[1;31mВЫКЛЮЧЕНЫ\e[0m."
               else
                   if [ ! -f /root/.tg_config ]; then
                       echo "❌ Сначала настройте Telegram-бота (пункт 9 главного меню)."
                   else
                       cat <<'EOF' > "$SSH_NOTIFY_SCRIPT"
#!/bin/bash
[ "$PAM_TYPE" != "open_session" ] && exit 0
[ ! -f /root/.tg_config ] && exit 0
source /root/.tg_config
[ -z "$TOKEN" ] || [ -z "$ADMIN_ID" ] && exit 0
HOST=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')
MSG="🔐 <b>Вход по SSH на $HOST</b>
👤 Пользователь: <code>$PAM_USER</code>
🌍 IP: <code>${PAM_RHOST:-local}</code>
🕒 Время: <code>$DATE</code>"
(curl -s --connect-timeout 5 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d "chat_id=${ADMIN_ID}" -d "parse_mode=HTML" --data-urlencode "text=${MSG}" >/dev/null 2>&1 &)
exit 0
EOF
                       chmod +x "$SSH_NOTIFY_SCRIPT"
                       echo "session optional pam_exec.so seteuid $SSH_NOTIFY_SCRIPT" >> /etc/pam.d/sshd
                       echo -e "✅ SSH-уведомления в Telegram \e[1;32mВКЛЮЧЕНЫ\e[0m (при каждом входе придет алерт)."
                   fi
               fi
               ;;
            0) return ;;
        esac
        read -p "Enter..." temp
    done
}

# ПАУЗА / РАЗБЛОКИРОВКА КЛИЕНТА
toggle_client_pause() {
    echo -e "\n\e[1;34m=== ⏸️ ПАУЗА / РАЗБЛОКИРОВКА КЛИЕНТА ===\e[0m"
    [ ! -f "$WG_CONF" ] && { echo "❌ Файл $WG_CONF не найден!"; read -p "Enter..." temp; return; }

    declare -a names_list
    declare -A is_paused_map
    i=0
    current_name=""
    while read -r line; do
        if [[ "$line" =~ ^#\ Client:\ (.*) ]]; then
            current_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^(#PAUSED#)?AllowedIPs\ =\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            if [ -n "$current_name" ]; then
                p_tag="${BASH_REMATCH[1]}"
                ip="${BASH_REMATCH[2]}"
                names_list[$i]="$current_name"
                if [ -n "$p_tag" ]; then
                    is_paused_map["$current_name"]="1"
                    st_str="\e[1;31m⏸️ НА ПАУЗЕ\e[0m"
                else
                    is_paused_map["$current_name"]="0"
                    st_str="\e[1;32m✅ АКТИВЕН\e[0m"
                fi
                echo -e "$i) 👤 \e[1;37m$current_name\e[0m ($ip) [ $st_str ]"
                i=$((i + 1))
                current_name=""
            fi
        fi
    done < "$WG_CONF"

    [ "$i" -eq 0 ] && { echo "Список пуст."; read -p "Enter..." temp; return; }

    echo "----------------------------------------------"
    read -p "Выберите НОМЕР клиента (или Enter для отмены): " P_NUM
    [ -z "$P_NUM" ] && return

    if [[ "$P_NUM" =~ ^[0-9]+$ ]] && [ "$P_NUM" -lt "$i" ]; then
        SEL_NAME="${names_list[$P_NUM]}"
        LINE=$(grep -n "^# Client: ${SEL_NAME}$" "$WG_CONF" | cut -d: -f1 | head -1)
        if [ -n "$LINE" ]; then
            S_LINE=$((LINE + 1))
            E_LINE=$((LINE + 3))
            if [ "${is_paused_map[$SEL_NAME]}" == "1" ]; then
                sed -i "${S_LINE},${E_LINE}s/^#PAUSED#//" "$WG_CONF"
                reload_wg_peers
                echo -e "✅ Клиент \e[1;32m$SEL_NAME\e[0m РАЗБЛОКИРОВАН (доступ восстановлен)."
            else
                sed -i "${S_LINE},${E_LINE}s/^/#PAUSED#/" "$WG_CONF"
                reload_wg_peers
                echo -e "⏸️ Клиент \e[1;33m$SEL_NAME\e[0m ПОСТАВЛЕН НА ПАУЗУ (ключи и порты сохранены)."
            fi
        fi
    else
        echo "❌ Неверный номер!"
    fi
    read -p "Enter..." temp
}

# УПРАВЛЕНИЕ ЛОКАЛЬНЫМИ ПОДСЕТЯМИ (SITE-TO-SITE)
manage_subnets() {
    while true; do
        clear
        echo -e "\e[1;34m=== 🔀 ЛОКАЛЬНЫЕ ПОДСЕТИ (SITE-TO-SITE) ===\e[0m"
        [ ! -f "$WG_CONF" ] && { echo "❌ Файл $WG_CONF не найден!"; read -p "Enter..." temp; return; }

        declare -a names_list
        declare -A aips_map
        i=0
        current_name=""
        while read -r line; do
            if [[ "$line" =~ ^#\ Client:\ (.*) ]]; then
                current_name="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^(#PAUSED#)?AllowedIPs\ =\ (.*) ]]; then
                if [ -n "$current_name" ]; then
                    aips_val="${BASH_REMATCH[2]}"
                    names_list[$i]="$current_name"
                    aips_map["$current_name"]="$aips_val"
                    echo -e "$i) 👤 \e[1;32m$current_name\e[0m  --> \e[1;36m$aips_val\e[0m"
                    i=$((i + 1))
                    current_name=""
                fi
            fi
        done < "$WG_CONF"

        [ "$i" -eq 0 ] && { echo "Список пуст."; read -p "Enter..." temp; return; }

        echo "----------------------------------------------"
        read -p "Выберите НОМЕР клиента (или Enter для выхода): " S_NUM
        [ -z "$S_NUM" ] && return

        if ! [[ "$S_NUM" =~ ^[0-9]+$ ]] || [ "$S_NUM" -ge "$i" ]; then
            echo "❌ Неверный номер!"; read -p "Enter..." temp; continue
        fi

        C_NAME="${names_list[$S_NUM]}"
        CUR_AIPS="${aips_map[$C_NAME]}"
        LINE=$(grep -n "^# Client: ${C_NAME}$" "$WG_CONF" | cut -d: -f1 | head -1)
        AIPS_LINE=$((LINE + 3))

        echo -e "\nКлиент: \e[1;32m$C_NAME\e[0m"
        echo -e "Текущие AllowedIPs: \e[1;36m$CUR_AIPS\e[0m"
        echo "1) ➕ Добавить локальную подсеть (напр: 192.168.1.0/24)"
        echo "2) ❌ Удалить локальную подсеть"
        echo "0) 🔙 Назад"
        read -p "Выбор: " SUB_ACT

        case $SUB_ACT in
            1)
                read -p "Введите подсеть (CIDR, напр: 192.168.1.0/24): " NEW_SUB
                NEW_SUB=$(echo "$NEW_SUB" | xargs)
                if ! [[ "$NEW_SUB" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                    echo "❌ Некорректный формат! Нужен вид 192.168.1.0/24"
                elif [[ ", $CUR_AIPS," == *", $NEW_SUB,"* ]]; then
                    echo "⚠️ Эта подсеть уже добавлена."
                else
                    NEW_VAL="${CUR_AIPS}, ${NEW_SUB}"
                    sed -i "${AIPS_LINE}s|AllowedIPs = .*|AllowedIPs = ${NEW_VAL}|" "$WG_CONF"
                    reload_wg_peers
                    ip route replace "$NEW_SUB" dev wg0 2>/dev/null
                    echo -e "✅ Подсеть \e[1;32m$NEW_SUB\e[0m добавлена к $C_NAME и маршрут прописан."
                fi
                ;;
            2)
                read -p "Введите подсеть для удаления (напр: 192.168.1.0/24): " DEL_SUB
                DEL_SUB=$(echo "$DEL_SUB" | xargs)
                MAIN_IP=$(echo "$CUR_AIPS" | cut -d',' -f1 | xargs)
                if [ -z "$DEL_SUB" ] || [ "$DEL_SUB" == "$MAIN_IP" ]; then
                    echo "❌ Нельзя удалить основной VPN IP клиента ($MAIN_IP)!"
                elif [[ "$CUR_AIPS" == *"$DEL_SUB"* ]]; then
                    NEW_VAL=$(echo "$CUR_AIPS" | sed "s|, *${DEL_SUB}||g" | sed "s|${DEL_SUB}, *||g")
                    sed -i "${AIPS_LINE}s|AllowedIPs = .*|AllowedIPs = ${NEW_VAL}|" "$WG_CONF"
                    reload_wg_peers
                    ip route del "$DEL_SUB" dev wg0 2>/dev/null || true
                    echo -e "✅ Подсеть \e[1;33m$DEL_SUB\e[0m удалена у $C_NAME."
                else
                    echo "⚠️ Подсеть $DEL_SUB не найдена у этого клиента."
                fi
                ;;
            0) continue ;;
        esac
        read -p "Enter..." temp
    done
}

# МОНИТОРИНГ ЖИВЫХ ПОДКЛЮЧЕНИЙ
monitor_connections() {
    while true; do
        clear
        echo -e "=== 📡 ЖИВЫЕ ПОДКЛЮЧЕНИЯ ==="
        echo "1) 🔍 Активные подключения на проброшенные порты (conntrack)"
        echo "2) 📊 Скорость трафика в реальном времени (iftop на wg0)"
        echo "0) 🔙 Назад"
        read -p "Выбор: " MC_OPT

        case $MC_OPT in
            1)
                if ! command -v conntrack >/dev/null 2>&1; then
                    echo "📦 Устанавливаю conntrack..."
                    apt-get update -y >/dev/null 2>&1 && apt-get install -y conntrack >/dev/null 2>&1
                fi
                while true; do
                    clear
                    echo -e "\e[1;34m=== 🔍 АКТИВНЫЕ ПОДКЛЮЧЕНИЯ (DNAT / ПРОБРОС ПОРТОВ) ===\e[0m"
                    printf "\e[1;33m %-6s %-18s %-12s %-22s %-12s\e[0m\n" "PROTO" "EXTERNAL IP" "VPS PORT" "TARGET (WG)" "STATE"
                    echo " --------------------------------------------------------------------------"
                    CONN_OUT=$(conntrack -L --dst-nat 2>/dev/null | grep -E "tcp|udp")
                    if [ -z "$CONN_OUT" ]; then
                        echo " (Нет активных подключений на проброшенные порты)"
                    else
                        echo "$CONN_OUT" | awk '{
                            proto=$1; state="-"; src=""; dport=""; rsrc=""; rdport="";
                            for(i=1;i<=NF;i++) {
                                if($i ~ /^(ESTABLISHED|SYN_SENT|SYN_RECV|TIME_WAIT|CLOSE_WAIT|FIN_WAIT|ASSURED)$/) state=$i;
                                if(src=="" && $i ~ /^src=/) { split($i,a,"="); src=a[2]; }
                                else if(src!="" && rsrc=="" && $i ~ /^src=/) { split($i,a,"="); rsrc=a[2]; }
                                if(dport=="" && $i ~ /^dport=/) { split($i,a,"="); dport=a[2]; }
                                else if(dport!="" && rdport=="" && $i ~ /^sport=/) { split($i,a,"="); rdport=a[2]; }
                            }
                            if(src!="" && rsrc!="") printf " %-6s %-18s :%-11s %-22s %-12s\n", proto, src, dport, rsrc ":" rdport, state;
                        }' | head -n 35
                    fi
                    echo " --------------------------------------------------------------------------"
                    read -p "[Enter - обновить | q - назад]: " R_KEY
                    [ "$R_KEY" == "q" ] && break
                done
                ;;
            2)
                if ! command -v iftop >/dev/null 2>&1; then
                    echo "📦 Устанавливаю iftop..."
                    apt-get update -y >/dev/null 2>&1 && apt-get install -y iftop >/dev/null 2>&1
                fi
                echo "Запуск iftop (нажмите 'q' для выхода)..."
                sleep 1
                iftop -i wg0 -n -P
                ;;
            0) break ;;
        esac
    done
}

# ПРИМЕНЕНИЕ ЛИМИТОВ
apply_mirror_limit() {
    local NAME=$1; local IP=$2; local SPEED=$3
    if [ -z "$IP" ]; then echo "Error: No IP"; return 1; fi
    local ID_CLASS=$(echo "$IP" | cut -d. -f4)
    sed -i "/# Client:$NAME/d" "$UP_SCRIPT"
    sed -i '/^exit 0/d' "$UP_SCRIPT"
    if [ "$SPEED" == "0" ]; then
        echo "exit 0" >> "$UP_SCRIPT"
        bash "$UP_SCRIPT" >/dev/null 2>&1
        return 0
    fi

    if [ "$SPEED" -ge 500 ]; then
        BURST="1500k"
    else
        BURST="300k"
    fi

    cat <<EOF >> "$UP_SCRIPT"
tc class add dev wg0 parent 1:1 classid 1:$ID_CLASS htb rate ${SPEED}mbit ceil ${SPEED}mbit burst ${BURST} cburst ${BURST} prio 1 # Client:$NAME
tc filter add dev wg0 protocol ip parent 1:0 prio 1 u32 match ip dst $IP flowid 1:$ID_CLASS # Client:$NAME

tc class add dev ifb0 parent 1:1 classid 1:$ID_CLASS htb rate ${SPEED}mbit ceil ${SPEED}mbit burst ${BURST} cburst ${BURST} prio 1 # Client:$NAME
tc filter add dev ifb0 protocol ip parent 1:0 prio 1 u32 match ip src $IP flowid 1:$ID_CLASS # Client:$NAME
EOF

    echo "exit 0" >> "$UP_SCRIPT"
    bash "$UP_SCRIPT" >/dev/null 2>&1
}

full_setup() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    REAL_IF=$(ip -4 route show default | awk '/default/ {print $5}')
    clear
    echo -e "\e[1;32m=== 🛠 ПОЛНАЯ УСТАНОВКА СИСТЕМЫ ===\e[0m"

    while true; do
        echo -e "\n--- 1. Подсеть VPN ---"
        echo -e "1) 10.252.1.0/24\n2) 10.0.0.0/24\n3) 10.8.0.0/24\n4) 172.16.0.0/24\n5) 192.168.10.0/24"
        read -p "Выбор [1]: " WG_SUB_CHOICE
        case ${WG_SUB_CHOICE:-1} in
            2) WG_SUBNET="10.0.0.0/24" ;; 
            3) WG_SUBNET="10.8.0.0/24" ;; 
            4) WG_SUBNET="172.16.0.0/24" ;;
            5) WG_SUBNET="192.168.10.0/24" ;; 
            *) WG_SUBNET="10.252.1.0/24" ;;
        esac
        WG_BASE=$(echo "$WG_SUBNET" | cut -d. -f1-3)
        if ip route | grep -v "wg0" | grep -q "$WG_BASE"; then
            echo -e "\e[1;31m⚠️ ОШИБКА: Конфликт подсети! Выберите другую.\e[0m"
            continue
        fi
        break
    done

    echo -e "\n--- 2. Выберите DNS ---"
    echo -e "1) Quad9 (9.9.9.9)\n2) Google (8.8.8.8)\n3) Cloudflare (1.1.1.1)\n4) AdGuard (94.140.14.14)"
    read -p "Выбор [1]: " DNS_CHOICE
    case ${DNS_CHOICE:-1} in
        2) USER_DNS="8.8.8.8" ;; 
        3) USER_DNS="1.1.1.1" ;; 
        4) USER_DNS="94.140.14.14" ;;
        *) USER_DNS="9.9.9.9" ;;
    esac

    echo -e "\n--- 3. Проброс портов ---"
    read -p "Введите порты (напр: 80 443 8443:443) или Enter для пропуска: " USER_PORTS

    echo -e "\n📦 Установка необходимых компонентов..."
    apt-get update -y && apt-get install -y ufw wireguard fail2ban qrencode curl jq iptables iproute2 ipset conntrack

    echo "options xt_recent ip_list_tot=15000" > /etc/modprobe.d/xt_recent.conf
    modprobe -r xt_recent 2>/dev/null
    modprobe xt_recent ip_list_tot=15000 2>/dev/null

    sed -i '/^#\?Port /d' "$SSH_CONF"
    sed -i "1i Port $SSH_PORT" "$SSH_CONF"
    echo "🛡 Настраиваем Fail2Ban на порт $SSH_PORT..."
    mkdir -p /etc/fail2ban/jail.d
    cat <<EOF > /etc/fail2ban/jail.d/sshd-custom.local
[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban

    if sshd -t; then
        systemctl stop ssh.socket > /dev/null 2>&1
        systemctl disable ssh.socket > /dev/null 2>&1
        systemctl daemon-reload
        systemctl enable ssh || systemctl enable sshd
        systemctl restart ssh || systemctl restart sshd
    fi

    ufw --force reset
    ufw allow "$SSH_PORT/tcp"
    ufw allow "$WG_PORT/udp"
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    echo "y" | ufw enable

    cp "$0" /usr/local/bin/vps
    chmod +x /usr/local/bin/vps
    grep -q "alias vps=" ~/.bashrc || echo "alias vps='sudo vps'" >> ~/.bashrc

    SERVER_IP="${WG_BASE}.1"
    ROUTER_IP="${WG_BASE}.2"

    cat <<EOF > "$UP_SCRIPT"
#!/bin/bash
# 1. ЯДРО
sysctl -w net.ipv4.ip_forward=1

# 2. ОЧИСТКА ПРАВИЛ
iptables -t nat -D POSTROUTING -s $WG_SUBNET -o $REAL_IF -j MASQUERADE 2>/dev/null || true
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# Сброс шейпера
tc qdisc del dev wg0 root 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true
ip link delete ifb0 2>/dev/null || true

# 3. NAT и MSS Clamping (без MASQUERADE на wg0 для сохранения реальных IP клиентов)
iptables -t nat -A POSTROUTING -s $WG_SUBNET -o $REAL_IF -j MASQUERADE
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -A FORWARD -i wg0 -j ACCEPT
iptables -A FORWARD -o wg0 -j ACCEPT

# 4. IFB и шейпер
modprobe ifb numifbs=1 2>/dev/null
ip link delete ifb0 2>/dev/null || true
ip link add name ifb0 type ifb 2>/dev/null || true
ip link set dev ifb0 up 2>/dev/null

tc qdisc add dev wg0 handle ffff: ingress 2>/dev/null
tc filter add dev wg0 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null

# Классы скорости
tc qdisc add dev wg0 root handle 1: htb default 10 2>/dev/null
tc qdisc add dev ifb0 root handle 1: htb default 10 2>/dev/null

tc class add dev wg0 parent 1: classid 1:1 htb rate 1000mbit 2>/dev/null
tc class add dev ifb0 parent 1: classid 1:1 htb rate 1000mbit 2>/dev/null

# Безлимит для всех по умолчанию
tc class add dev wg0 parent 1:1 classid 1:10 htb rate 1000mbit ceil 1000mbit prio 0 2>/dev/null
tc class add dev ifb0 parent 1:1 classid 1:10 htb rate 1000mbit ceil 1000mbit prio 0 2>/dev/null

EOF

    if [ -n "$USER_PORTS" ]; then
        for raw_p in $USER_PORTS; do
            if [[ "$raw_p" == *:* ]]; then
                ext_p="${raw_p%%:*}"
                int_p="${raw_p##*:}"
            else
                ext_p="$raw_p"
                int_p="$raw_p"
            fi
            ufw allow "$ext_p"
            echo "iptables -t nat -D PREROUTING -i $REAL_IF -p tcp --dport $ext_p -j DNAT --to-destination $ROUTER_IP:$int_p 2>/dev/null || true" >> "$UP_SCRIPT"
            echo "iptables -t nat -D PREROUTING -i $REAL_IF -p udp --dport $ext_p -j DNAT --to-destination $ROUTER_IP:$int_p 2>/dev/null || true" >> "$UP_SCRIPT"
            echo "iptables -t nat -A PREROUTING -i $REAL_IF -p tcp --dport $ext_p -j DNAT --to-destination $ROUTER_IP:$int_p # Port:$ext_p" >> "$UP_SCRIPT"
            echo "iptables -t nat -A PREROUTING -i $REAL_IF -p udp --dport $ext_p -j DNAT --to-destination $ROUTER_IP:$int_p # Port:$ext_p" >> "$UP_SCRIPT"
        done
    fi
    echo "exit 0" >> "$UP_SCRIPT"
    chmod +x "$UP_SCRIPT"

    SERVER_PRIV=$(wg genkey); SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)
    cat <<EOF > "$WG_CONF"
[Interface]
Address = $SERVER_IP/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIV
PostUp = $UP_SCRIPT
PostDown = iptables -t nat -F; iptables -P FORWARD ACCEPT; ip link delete ifb0 2>/dev/null
EOF

    echo "Создаем клиента Router ($ROUTER_IP)..."
    generate_peer_config "Router" "$ROUTER_IP" "$USER_DNS" "$SERVER_PUB" "true"

    systemctl enable wg-quick@wg0 && systemctl restart wg-quick@wg0

    clear
    CURRENT_PASS_AUTH=$(grep -v "^#" "$SSH_CONF" 2>/dev/null | grep "PasswordAuthentication" | awk '{print $2}')
    if [ "${CURRENT_PASS_AUTH:-yes}" == "yes" ]; then
        SSH_MSG="\e[1;31m⚠️ Доступ по паролю ВКЛЮЧЕН (небезопасно)!\e[0m\n   \e[1;33mИспользуйте 'vps' -> '2' для настройки ключей.\e[0m"
    else
        SSH_MSG="\e[1;32m🔐 Доступ только по КЛЮЧАМ (безопасно).\e[0m"
    fi

    echo -e "\e[1;32m=============================================\e[0m"
    echo -e "\e[1;32m✅ УСТАНОВКА ЗАВЕРШЕНА! Новый порт SSH: $SSH_PORT ⚠️\e[0m"
    echo -e "\e[1;32m=============================================\e[0m"
    echo -e "\n\e[1;33m📁 Конфиг роутера для скачивания (SFTP):\e[0m"
    echo -e "\e[1;36m$CLIENT_DIR/Router.conf\e[0m"
    echo -e "\n\e[1;33m🚀 Как зайти в меню повторно:\e[0m"
    echo -e "Просто введите команду: \e[1;32mvps\e[0m"
    echo -e "\n$SSH_MSG"
    echo -e "\e[1;32m=============================================\e[0m"
    read -p "Нажмите Enter, чтобы войти в меню..." temp
}

print_web_table() {
    local URL=$1
    local USER=$2
    local PASS=$3
    local MODE=$4
    local PORT=$5
    local IP=$6

    echo -e "${green}╔════════════════════════════════════════════════════════╗${plain}"
    echo -e "${green}║             🔐 ДАННЫЕ ДЛЯ ВХОДА В ПАНЕЛЬ               ║${plain}"
    echo -e "${green}╠════════════════════════════════════════════════════════╣${plain}"
    printf "${green}║${plain} %-14s ${green}│${plain} %-36s ${green}║${plain}\n" "🔗 ССЫЛКА" "$URL"
    echo -e "${green}╟────────────────┼──────────────────────────────────────╢${plain}"
    printf "${green}║${plain} %-14s ${green}│${plain} \033[1;33m%-36s\033[0m ${green}║${plain}\n" "👤 ЛОГИН" "$USER"
    printf "${green}║${plain} %-14s ${green}│${plain} \033[1;33m%-36s\033[0m ${green}║${plain}\n" "🔑 ПАРОЛЬ" "$PASS"

    if [ "$MODE" == "LOCAL" ]; then
    echo -e "${green}╠════════════════╧══════════════════════════════════════╣${plain}"
    echo -e "${green}║${plain} 🚇 \033[1;34mSSH ТУННЕЛЬ (Выполнить на своем ПК):\033[0m               ${green}║${plain}"
    echo -e "${green}║${plain} ssh -L $PORT:127.0.0.1:$PORT root@$IP       ${green}║${plain}"
    fi
    echo -e "${green}╚════════════════════════════════════════════════════════╝${plain}"
}

apply_ttyd_cert() {
    local TYPE=$1
    local CERT_PATH="/root/cert/$TYPE/fullchain.pem"
    local KEY_PATH="/root/cert/$TYPE/privkey.pem"

    if [ ! -f "$CERT_PATH" ]; then
        echo -e "${red}Ошибка: Файлы сертификата для $TYPE не найдены!${plain}"
        return 1
    fi

    echo -e "${green}Применяем сертификат ($TYPE) к панели...${plain}"

    W_PORT=$(grep "ExecStart" /etc/systemd/system/ttyd.service 2>/dev/null | grep -oP '(?<=-p )\d+')
    W_PORT=${W_PORT:-17681}

    CUR_CREDS=$(grep "ExecStart" /etc/systemd/system/ttyd.service 2>/dev/null | grep -oP '(?<=-c ")[^"]+')
    CUR_CREDS=${CUR_CREDS:-admin:admin}

    cat <<EOF > /etc/systemd/system/ttyd.service
[Unit]
Description=Web SSH Service
After=network.target
[Service]
ExecStart=/usr/bin/ttyd -i 0.0.0.0 -p $W_PORT -W -c "$CUR_CREDS" -S -C $CERT_PATH -K $KEY_PATH /bin/bash /usr/local/bin/vps
Restart=always
User=root
WorkingDirectory=/root
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl restart ttyd

    EXT_IP=$(curl -4 -s ifconfig.me)

    echo -e "\n${green}✅ СЕРТИФИКАТ ($TYPE) УСПЕШНО ПРИМЕНЕН!${plain}"
    echo "---------------------------------------------------"
    if [ "$TYPE" == "domain" ]; then
        DOM=$(openssl x509 -noout -subject -in "$CERT_PATH" | sed -n 's/^.*CN = \(.*\)$/\1/p')
        echo -e "🌍 Внешняя ссылка:   ${green}https://$DOM:$W_PORT${plain}"
    else
        echo -e "🌍 Внешняя ссылка:   ${green}https://$EXT_IP:$W_PORT${plain}"
    fi
    echo "---------------------------------------------------"
    echo -e "🚇 SSH Туннель (Localhost):"
    echo -e "   Команда на ПК:    ${yellow}ssh -L $W_PORT:127.0.0.1:$W_PORT root@$EXT_IP${plain}"
    echo -e "   Ссылка в браузере: ${green}https://127.0.0.1:$W_PORT${plain}"
    echo -e "   (При входе через localhost браузер может ругаться на SSL — это нормально)"
    echo "---------------------------------------------------"
}

setup_acme_ip() {
    local IP=$(curl -4 -s ifconfig.me)
    echo -e "${green}Получаем SSL для IP: $IP ...${plain}"

    if ! command -v socat >/dev/null 2>&1; then apt-get install -y socat >/dev/null; fi
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then curl -s https://get.acme.sh | sh >/dev/null 2>&1; fi

    systemctl stop caddy >/dev/null 2>&1
    fuser -k 80/tcp >/dev/null 2>&1
    ufw allow 80/tcp >/dev/null 2>&1

    mkdir -p /root/cert/ip

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue -d "$IP" --standalone --httpport 80 --certificate-profile shortlived --force

    if [ $? -eq 0 ]; then
        ~/.acme.sh/acme.sh --installcert -d "$IP" \
            --key-file /root/cert/ip/privkey.pem \
            --fullchain-file /root/cert/ip/fullchain.pem \
            --reloadcmd "systemctl restart ttyd"

        chmod 600 /root/cert/ip/privkey.pem
        apply_ttyd_cert "ip"
    else
        echo -e "${red}Ошибка получения IP сертификата!${plain}"
    fi
}

setup_acme_domain() {
    read -p "Введите ваш ДОМЕН: " DOMAIN
    echo -e "${green}Получаем SSL для Домена: $DOMAIN ...${plain}"

    if ! command -v socat >/dev/null 2>&1; then apt-get install -y socat >/dev/null; fi
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then curl -s https://get.acme.sh | sh >/dev/null 2>&1; fi

    systemctl stop caddy >/dev/null 2>&1
    fuser -k 80/tcp >/dev/null 2>&1
    ufw allow 80/tcp >/dev/null 2>&1

    mkdir -p /root/cert/domain

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --httpport 80 --force

    if [ $? -eq 0 ]; then
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
            --key-file /root/cert/domain/privkey.pem \
            --fullchain-file /root/cert/domain/fullchain.pem \
            --reloadcmd "systemctl restart ttyd"

        chmod 600 /root/cert/domain/privkey.pem
        apply_ttyd_cert "domain"
    else
        echo -e "${red}Ошибка получения Доменного сертификата!${plain}"
    fi
}

manage_web_panel() {
    if ! command -v wget >/dev/null 2>&1; then
        echo -e "\e[1;33m⚠️ Утилита wget не найдена. Устанавливаем...\e[0m"
        apt-get update -y >/dev/null 2>&1 && apt-get install -y wget >/dev/null 2>&1
    fi

    if ! command -v ttyd >/dev/null 2>&1; then
        echo -e "\e[1;33m⚠️ Web-консоль не найдена. Скачиваем...\e[0m"
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            wget -O /usr/bin/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64
        elif [[ "$ARCH" == "aarch64" ]]; then
            wget -O /usr/bin/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.aarch64
        else
            echo "Архитектура $ARCH не поддерживается авто-установкой."
        fi
        chmod +x /usr/bin/ttyd
        echo -e "\e[1;32m✅ TTYD установлен.\e[0m"
        sleep 1
    fi

    while true; do
        clear
        if systemctl is-active --quiet ttyd; then
            ST_WEB="${green}ВКЛ${plain}"
            SERV_FILE="/etc/systemd/system/ttyd.service"
            CUR_PORT=$(grep "ExecStart" "$SERV_FILE" 2>/dev/null | grep -oP '(?<=-p )\d+')
            CREDS=$(grep "ExecStart" "$SERV_FILE" 2>/dev/null | grep -oP '(?<=-c ")[^"]+')
            CUR_USER=$(echo "$CREDS" | cut -d: -f1)
            CUR_PASS=$(echo "$CREDS" | cut -d: -f2)
            if grep -q "\-i 127.0.0.1" "$SERV_FILE"; then
                MODE_TEXT="🔒 LOCAL (Только туннель)"
                IS_LOCAL=1
            else
                MODE_TEXT="🌍 PUBLIC (Интернет)"
                IS_LOCAL=0
            fi

            if grep -q "\-C /root/cert" "$SERV_FILE"; then
                SSL_TEXT="${green}SSL АКТИВЕН${plain}"
                PROTO="https"
            else
                SSL_TEXT="${yellow}HTTP (Без защиты)${plain}"
                PROTO="http"
            fi
        else
            ST_WEB="${red}ВЫКЛ${plain}"
            SSL_TEXT=""
            MODE_TEXT=""
        fi

        echo -e "=== 🌐 WEB-ПАНЕЛЬ [ $ST_WEB ] ==="
        if [ -n "$MODE_TEXT" ]; then
            echo -e "   Режим:  $MODE_TEXT"
            echo -e "   Защита: $SSL_TEXT"
        fi
        echo "------------------------------------------------"

        if systemctl is-active --quiet ttyd; then
             EXT_IP=$(curl -4 -s ifconfig.me)
             if [ "$IS_LOCAL" -eq 1 ]; then
                 print_web_table "http://127.0.0.1:$CUR_PORT" "$CUR_USER" "$CUR_PASS" "LOCAL" "$CUR_PORT" "$EXT_IP"
             else
                 print_web_table "$PROTO://$EXT_IP:$CUR_PORT" "$CUR_USER" "$CUR_PASS" "PUBLIC" "$CUR_PORT" "$EXT_IP"
             fi
             echo ""
             echo -e "1) 🛑 Выключить панель"
             echo -e "2) 🔄 Перезапустить"
             if [ "$IS_LOCAL" -eq 0 ]; then
                echo -e "3) 🔒 Настроить SSL (Если режим Public)"
             fi
        else
             echo -e "1) 🚀 ВКЛЮЧИТЬ панель"
        fi

        echo "0) 🔙 Назад"
        read -p "Выбор: " W_OPT

        case $W_OPT in
            1)
                if systemctl is-active --quiet ttyd; then
                    systemctl stop ttyd && systemctl disable ttyd
                    [ -n "$CUR_PORT" ] && ufw delete allow "$CUR_PORT/tcp" > /dev/null 2>&1
                    echo -e "${red}Панель остановлена.${plain}"
                else
                    echo -e "\n${green}--- НАСТРОЙКА ЗАПУСКА ---${plain}"
                    echo "1) 🔒 ЛОКАЛЬНО (127.0.0.1) - Безопасно, вход через SSH-туннель. SSL не нужен."
                    echo "2) 🌍 ПУБЛИЧНО (0.0.0.0)   - Доступ из интернета. Рекомендуется SSL."
                    read -p "Выберите режим [1]: " MODE_OPT

                    read -p "Придумайте Логин [admin]: " WU; WU=${WU:-admin}
                    read -p "Придумайте Пароль [admin]: " WP; WP=${WP:-admin}
                    read -p "Порт панели [17681]: " W_PORT; W_PORT=${W_PORT:-17681}

                    if [ "$MODE_OPT" == "2" ]; then
                        IP_BIND="0.0.0.0"
                        read -p "Включить SSL сразу? (y/n) [n]: " WANT_SSL
                        if [[ "$WANT_SSL" == "y" ]]; then
                           if [ -f "/root/cert/ip/fullchain.pem" ]; then
                               SSL_OPTS="-S -C /root/cert/ip/fullchain.pem -K /root/cert/ip/privkey.pem"
                           elif [ -f "/root/cert/domain/fullchain.pem" ]; then
                               SSL_OPTS="-S -C /root/cert/domain/fullchain.pem -K /root/cert/domain/privkey.pem"
                           else
                               echo -e "${red}Сертификатов нет! Запустится без SSL (потом настройте в п.3)${plain}"
                               SSL_OPTS=""
                           fi
                        else
                           SSL_OPTS=""
                        fi
                        ufw allow "$W_PORT/tcp" > /dev/null 2>&1
                    else
                        IP_BIND="127.0.0.1"
                        SSL_OPTS=""
                        ufw delete allow "$W_PORT/tcp" > /dev/null 2>&1
                    fi

                    cat <<EOF > /etc/systemd/system/ttyd.service
[Unit]
Description=Web SSH Service
After=network.target
[Service]
ExecStart=/usr/bin/ttyd -i $IP_BIND -p $W_PORT -W -c "$WU:$WP" $SSL_OPTS /bin/bash /usr/local/bin/vps
Restart=always
User=root
WorkingDirectory=/root
[Install]
WantedBy=multi-user.target
EOF
                    systemctl daemon-reload; systemctl enable ttyd; systemctl restart ttyd
                    echo -e "\n${green}✅ УСПЕШНО ЗАПУЩЕНО!${plain}"
                fi
                ;;
            2) systemctl restart ttyd; echo "Перезапущено." ;;
            3)
                echo -e "\n1) Получить SSL на IP\n2) Получить SSL на Домен\n3) Применить к панели"
                read -p "Выбор: " SSL_SUB
                case $SSL_SUB in
                    1) setup_acme_ip ;;
                    2) setup_acme_domain ;;
                    3)
                       if [ -f "/root/cert/ip/fullchain.pem" ]; then apply_ttyd_cert "ip";
                       elif [ -f "/root/cert/domain/fullchain.pem" ]; then apply_ttyd_cert "domain";
                       else echo -e "${red}Сертификатов нет${plain}"; fi ;;
                esac
                ;;
            0) break ;;
        esac
        read -p "Нажми Enter..." temp
    done
}

manage_bot() {
    BOT_SERVICE="/etc/systemd/system/tgbot.service"
    CFG_FILE="/root/.tg_config"

    load_creds() {
        if [ -f "$CFG_FILE" ]; then
            source "$CFG_FILE"
        fi
    }

    while true; do
        load_creds
        clear
        echo -e "\e[1;36m=== 🤖 УПРАВЛЕНИЕ БОТОМ ===\e[0m"

        if systemctl is-active --quiet tgbot; then
            echo -e "Статус: \e[1;32m✅ РАБОТАЕТ\e[0m"
        else
            echo -e "Статус: \e[1;31m🛑 ОСТАНОВЛЕН\e[0m"
        fi

        if [ -n "$TOKEN" ]; then
            echo -e "Данные: \e[1;33mСОХРАНЕНЫ\e[0m (ID: $ADMIN_ID)"
        else
            echo -e "Данные: \e[1;30mОТСУТСТВУЮТ\e[0m"
        fi

        echo "---------------------------------"
        echo "1) 🛠 Установить / Обновить скрипты (быстро)"
        echo "2) ⚙️ Сменить Токен или ID"
        echo "3) 🔄 Перезапуск службы"
        echo "4) 🛑 Стоп"
        echo "5) 📜 Логи"
        echo "6) 🗑 Удалить бота"
        echo "0) 🔙 Назад"
        echo "---------------------------------"
        read -p "Выбор: " B_OPT

        case $B_OPT in
            1)
                if [ -n "$TOKEN" ] && [ -n "$ADMIN_ID" ]; then
                    echo "Используем сохраненные данные..."
                    install_bot_logic "$TOKEN" "$ADMIN_ID"
                else
                    echo "⚠️ Данные не найдены. Введите их:"
                    read -p "Token: " TOKEN
                    read -p "Admin ID: " ADMIN_ID
                    install_bot_logic "$TOKEN" "$ADMIN_ID"
                fi
                read -p "Готово. Enter..." ;;
            2)
                echo "Введите новые данные:"
                read -p "Новый Token: " TOKEN
                read -p "Новый Admin ID: " ADMIN_ID
                install_bot_logic "$TOKEN" "$ADMIN_ID"
                read -p "Данные обновлены. Enter..." ;;
            3) systemctl restart tgbot; echo "Рестарт..."; sleep 1 ;;
            4) systemctl stop tgbot; echo "Стоп."; sleep 1 ;;
            5) journalctl -u tgbot -n 30 --no-pager; read -p "Enter..." ;;
            6)
                systemctl stop tgbot
                systemctl disable tgbot
                rm -f /etc/systemd/system/tgbot.service
                rm -f /root/.tg_config
                rm -rf /root/scripts
                rm -f /root/tg_bot.py
                systemctl daemon-reload
                echo "Бот удален."
                sleep 2 ;;
            0) break ;;
        esac
    done
}

install_bot_logic() {
    local TOKEN="$1"
    local ID="$2"

    echo "TOKEN=\"$TOKEN\"" > /root/.tg_config
    echo "ADMIN_ID=\"$ID\"" >> /root/.tg_config

    echo "🏗 Установка бота..."

    systemctl stop tgbot 2>/dev/null
    pkill -f "/root/tg_bot.py" 2>/dev/null || true

    echo "📦 Установка библиотек (может занять до 5 минут)..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y ipset curl geoip-bin iproute2 ufw wireguard qrencode jq python3-pip conntrack >/dev/null 2>&1

    pip3 install pyTelegramBotAPI --break-system-packages 2>/dev/null || pip3 install pyTelegramBotAPI

    mkdir -p /root/scripts /etc/ipset /root/wg_clients /etc/wireguard/ssh_key /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    touch /etc/ipset/whitelist.conf

    UP_SCRIPT="/etc/wireguard/up.sh"

    modprobe ifb numifbs=1 2>/dev/null
    grep -q "ifb" /etc/modules || echo "ifb" >> /etc/modules

    # Создаем up.sh только если он еще не существует (чтобы не затирать порты и лимиты!)
    if [ ! -f "$UP_SCRIPT" ]; then
        cat <<'EOF' > "$UP_SCRIPT"
#!/bin/bash
# 1. Ядро
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
DEV=$(ip -4 route show default | awk '/default/ {print $5}')

# 2. NAT сброс
iptables -t nat -F POSTROUTING
iptables -t nat -F PREROUTING
iptables -F FORWARD
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# 3. NAT и MSS Clamping (без MASQUERADE на wg0 для сохранения реальных IP клиентов)
iptables -t nat -A POSTROUTING -o $DEV -j MASQUERADE
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# 4. Forwarding
iptables -A FORWARD -i wg0 -j ACCEPT
iptables -A FORWARD -o wg0 -j ACCEPT
iptables -A FORWARD -i $DEV -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o $DEV -j ACCEPT

# 5. IFB
modprobe ifb numifbs=1 >/dev/null 2>&1 || true
ip link delete ifb0 2>/dev/null || true
ip link add name ifb0 type ifb 2>/dev/null || true
ip link set dev ifb0 up >/dev/null 2>&1 || true

tc qdisc del dev wg0 root >/dev/null 2>&1 || true
tc qdisc del dev ifb0 root >/dev/null 2>&1 || true
tc qdisc del dev wg0 ingress >/dev/null 2>&1 || true

tc qdisc add dev wg0 root handle 1: htb default 1 >/dev/null 2>&1 || true
tc class add dev wg0 parent 1: classid 1:1 htb rate 1000mbit >/dev/null 2>&1 || true

tc qdisc add dev ifb0 root handle 1: htb default 1 >/dev/null 2>&1 || true
tc class add dev ifb0 parent 1: classid 1:1 htb rate 1000mbit >/dev/null 2>&1 || true

tc qdisc add dev wg0 handle ffff: ingress >/dev/null 2>&1 || true
tc filter add dev wg0 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 >/dev/null 2>&1 || true

# 6. GeoIP
if [ -s /etc/ipset/whitelist.conf ]; then
    ipset restore -! < /etc/ipset/whitelist.conf >/dev/null 2>&1 || true
    iptables -I FORWARD -i $DEV -m state --state NEW -m set ! --match-set whitelist src -j DROP >/dev/null 2>&1 || true
fi

exit 0
EOF
        chmod +x "$UP_SCRIPT"
        bash "$UP_SCRIPT"
    fi

    cat <<'EOF' > /root/scripts/geoip_on.sh
#!/bin/bash
COUNTRIES=$1
UP_SCRIPT="/etc/wireguard/up.sh"
IPSET_FILE="/etc/ipset/whitelist.conf"
REAL_IF=$(ip -4 route show default | awk '/default/ {print $5}')
[ -z "$COUNTRIES" ] && echo "EMPTY" && exit 1
iptables -D FORWARD -i "$REAL_IF" -m state --state NEW -m set ! --match-set whitelist src -j DROP 2>/dev/null
ipset destroy whitelist 2>/dev/null
ipset create whitelist hash:net -!
for country in $COUNTRIES; do
    c=$(echo "$country" | tr '[:upper:]' '[:lower:]')
    if curl -s -f "http://www.ipdeny.com/ipblocks/data/countries/$c.zone" > /tmp/cnt.zone; then
        while read -r line; do ipset add whitelist "$line" -! 2>/dev/null; done < /tmp/cnt.zone
    fi
done
ipset save whitelist > "$IPSET_FILE"
sed -i '/if \[ -s .*whitelist.* \]/,/fi/d' "$UP_SCRIPT"
sed -i '/match-set whitelist/d' "$UP_SCRIPT"
sed -i '/# GeoIP_Countries/d' "$UP_SCRIPT"
sed -i '/ipset restore/d' "$UP_SCRIPT"
sed -i '/^exit 0/d' "$UP_SCRIPT"
echo "# GeoIP_Countries: $COUNTRIES" >> "$UP_SCRIPT"
cat <<CMD >> "$UP_SCRIPT"
if [ -s /etc/ipset/whitelist.conf ]; then
    ipset restore -! < /etc/ipset/whitelist.conf 2>/dev/null || true
    iptables -I FORWARD -i $REAL_IF -m state --state NEW -m set ! --match-set whitelist src -j DROP 2>/dev/null || true
fi
CMD
echo "exit 0" >> "$UP_SCRIPT"
iptables -I FORWARD -i "$REAL_IF" -m state --state NEW -m set ! --match-set whitelist src -j DROP
echo "DONE"
EOF
    chmod +x /root/scripts/geoip_on.sh

    cat <<'EOF' > /root/scripts/geoip_off.sh
#!/bin/bash
UP_SCRIPT="/etc/wireguard/up.sh"
REAL_IF=$(ip -4 route show default | awk '/default/ {print $5}')
iptables -D FORWARD -i "$REAL_IF" -m state --state NEW -m set ! --match-set whitelist src -j DROP 2>/dev/null
ipset destroy whitelist 2>/dev/null
rm -f /etc/ipset/whitelist.conf
sed -i '/if \[ -s .*whitelist.* \]/,/fi/d' "$UP_SCRIPT"
sed -i '/# GeoIP_Countries:/d' "$UP_SCRIPT"
sed -i '/match-set whitelist/d' "$UP_SCRIPT"
sed -i '/ipset restore/d' "$UP_SCRIPT"
echo "OFF"
EOF
    chmod +x /root/scripts/geoip_off.sh

    # REAL IP TOGGLE FOR BOT
    cat <<'EOF' > /root/scripts/realip_toggle.sh
#!/bin/bash
UP_SCRIPT="/etc/wireguard/up.sh"
WG_CONF="/etc/wireguard/wg0.conf"
if [ ! -f "$UP_SCRIPT" ]; then echo "ERROR"; exit 1; fi
if grep -qE "^iptables.*-A POSTROUTING.*-o wg0 -j MASQUERADE" "$UP_SCRIPT"; then
    sed -i '/-o wg0 -j MASQUERADE/d' "$UP_SCRIPT"
    while iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null; do :; done
    VPN_SUB=$(grep "^Address" "$WG_CONF" 2>/dev/null | awk '{print $3}' | head -1 | sed 's/\.[0-9]*\//.0\//')
    [ -n "$VPN_SUB" ] && while iptables -t nat -D POSTROUTING -d "$VPN_SUB" -o wg0 -j MASQUERADE 2>/dev/null; do :; done
    echo "REAL_ON"
else
    sed -i '/^exit 0/d' "$UP_SCRIPT"
    echo "iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE" >> "$UP_SCRIPT"
    echo "exit 0" >> "$UP_SCRIPT"
    iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
    echo "REAL_OFF"
fi
EOF
    chmod +x /root/scripts/realip_toggle.sh

    # PAUSE TOGGLE FOR BOT
    cat <<'EOF' > /root/scripts/pause_client.sh
#!/bin/bash
NAME=$1; WG_CONF="/etc/wireguard/wg0.conf"
LINE=$(grep -n "^# Client: ${NAME}$" "$WG_CONF" | cut -d: -f1 | head -1)
[ -z "$LINE" ] && echo "ERROR" && exit 1
S=$((LINE + 1)); E=$((LINE + 3))
if sed -n "${S}p" "$WG_CONF" | grep -q "^#PAUSED#"; then
    sed -i "${S},${E}s/^#PAUSED#//" "$WG_CONF"
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || systemctl restart wg-quick@wg0
    echo "RESUMED"
else
    sed -i "${S},${E}s/^/#PAUSED#/" "$WG_CONF"
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || systemctl restart wg-quick@wg0
    echo "PAUSED"
fi
EOF
    chmod +x /root/scripts/pause_client.sh

    # BACKUP FOR BOT
    cat <<'EOF' > /root/scripts/make_backup.sh
#!/bin/bash
BACKUP_DIR="/root/vps_backups"
mkdir -p "$BACKUP_DIR"
ARCHIVE="$BACKUP_DIR/vps_backup_$(date '+%Y-%m-%d_%H-%M-%S').tar.gz"
PATHS=()
[ -d /etc/wireguard ] && PATHS+=("/etc/wireguard")
[ -d /root/wg_clients ] && PATHS+=("/root/wg_clients")
[ -d /etc/ipset ] && PATHS+=("/etc/ipset")
[ -f /root/.tg_config ] && PATHS+=("/root/.tg_config")
if [ ${#PATHS[@]} -eq 0 ]; then echo "ERROR"; exit 1; fi
tar -czf "$ARCHIVE" "${PATHS[@]}" 2>/dev/null
ls -1t "$BACKUP_DIR"/vps_backup_*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
echo "OK|$ARCHIVE"
EOF
    chmod +x /root/scripts/make_backup.sh

    cat <<'EOF' > /root/scripts/monitor.sh
#!/bin/bash
if [ -f /root/.tg_config ]; then source /root/.tg_config; else exit 0; fi

send_msg() {
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$ADMIN_ID" -d "parse_mode=HTML" --data-urlencode "text=$1" >/dev/null
}

# АВТОПОДНЯТИЕ WIREGUARD
if ! systemctl is-active --quiet wg-quick@wg0; then
    systemctl restart wg-quick@wg0
    sleep 5
    if systemctl is-active --quiet wg-quick@wg0; then
        send_msg "⚠️ <b>WireGuard упал!</b>
🚑 Watchdog: Служба успешно перезапущена."
    fi
fi

# МОНИТОРИНГ ДИСКА (>90%, уведомление не чаще 1 раза в 6 часов)
DISK_PCT=$(df / | awk 'NR==2 {gsub("%",""); print $5}')
DISK_FLAG="/tmp/vps_disk_alert"
if [ -n "$DISK_PCT" ] && [ "$DISK_PCT" -ge 90 ]; then
    NOW_TS=$(date +%s)
    LAST_TS=$(cat "$DISK_FLAG" 2>/dev/null || echo 0)
    if [ $((NOW_TS - LAST_TS)) -ge 21600 ]; then
        DISK_LINE=$(df -h / | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')
        send_msg "⚠️ <b>Мало места на диске VPS!</b>
💾 Занято: <code>$DISK_LINE</code>"
        echo "$NOW_TS" > "$DISK_FLAG"
    fi
else
    rm -f "$DISK_FLAG"
fi

# ANTI-FLOOD
NOW="/tmp/bans_now.txt"
PREV="/tmp/bans_prev.txt"

grep -h "src=" /proc/net/xt_recent/PORT_* 2>/dev/null | awk -F'src=' '{print $2}' | awk '{print $1}' | sort -u > "$NOW"

if [ -f "$PREV" ]; then
    NEW_BANS=$(comm -13 "$PREV" "$NOW")
    if [ -n "$NEW_BANS" ]; then
        COUNT=$(echo "$NEW_BANS" | wc -l)
        send_msg "🛡 <b>Обнаружена атака!</b>
🚫 Новых банов: <b>$COUNT</b>
📋 IP:
<code>$NEW_BANS</code>"
    fi
fi
cp "$NOW" "$PREV"
EOF
    chmod +x /root/scripts/monitor.sh

    cat <<EOF > /etc/systemd/system/vps_monitor.service
[Unit]
Description=VPS Watchdog
[Service]
Type=oneshot
ExecStart=/root/scripts/monitor.sh
EOF

    cat <<EOF > /etc/systemd/system/vps_monitor.timer
[Unit]
Description=Run Monitor every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable vps_monitor.timer
    systemctl start vps_monitor.timer

    # STATUS.SH
    cat <<'EOF' > /root/scripts/status.sh
#!/bin/bash
WG_CONF="/etc/wireguard/wg0.conf"
SSH_CONF="/etc/ssh/sshd_config"
UP_SCRIPT="/etc/wireguard/up.sh"

EXT_IP=$(curl -4 -s ifconfig.me)
GW_IP=$(ip -4 route show default | awk '/default/ {print $3}')
VPN_NET=$(grep "^Address" "$WG_CONF" 2>/dev/null | awk '{print $3}' | head -1)
WG_PORT=$(grep "ListenPort" "$WG_CONF" 2>/dev/null | awk '{print $3}')
SSH_PORT=$(grep "^Port " "$SSH_CONF" 2>/dev/null | awk '{print $2}'); [ -z "$SSH_PORT" ] && SSH_PORT="22"

LOAD_AVG=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
RAM_INFO=$(free -m 2>/dev/null | awk '/Mem:/ {printf "%d/%dMB", $3, $2}')
DISK_INFO=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')

if grep -q "match-set whitelist" "$UP_SCRIPT" 2>/dev/null; then GEO="✅ ON"; else GEO="❌ OFF"; fi
if systemctl is-active --quiet ttyd; then WEB="🖥 ON"; else WEB="❌ OFF"; fi
if grep -q "^PasswordAuthentication no" "$SSH_CONF"; then SSH_MODE="🔐 KEY"; else SSH_MODE="🔓 PASS"; fi
if grep -qE "^iptables.*-A POSTROUTING.*-o wg0 -j MASQUERADE" "$UP_SCRIPT" 2>/dev/null; then REALIP="❌ NAT"; else REALIP="✅ Real"; fi
if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]; then BBR="⚡ ON"; else BBR="OFF"; fi
if grep -q "clamp-mss-to-pmtu" "$UP_SCRIPT" 2>/dev/null; then MSS="✅ ON"; else MSS="OFF"; fi

PORTS_INFO=$(grep "DNAT" "$UP_SCRIPT" 2>/dev/null | grep "dport" | while read -r line; do
    if [[ "$line" =~ --dport\ ([0-9]+).*--to-destination\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+) ]]; then
        ep="${BASH_REMATCH[1]}"; ip="${BASH_REMATCH[2]}"; ip_p="${BASH_REMATCH[3]}"
        c_name=$(grep -B 5 "$ip/32" "$WG_CONF" | grep "# Client:" | awk '{print $3}')
        [ -z "$c_name" ] && c_name="$ip"
        [ "$ep" == "$ip_p" ] && echo "$ep ➜ $c_name" || echo "$ep:$ip_p ➜ $c_name"
    fi
done | sort -u)

[ -z "$PORTS_INFO" ] && PORTS_INFO="Нет"

echo "<b>📊 СИСТЕМНАЯ СВОДКА:</b>"
echo "📡 WAN: <code>$EXT_IP</code>"
echo "🚪 Gateway: <code>$GW_IP</code>"
echo "🕸 VPN Net: <code>$VPN_NET</code>"
echo "🔌 WG Port: <code>$WG_PORT</code>"
echo "🛡 SSH: <code>$SSH_PORT</code> ($SSH_MODE)"
echo "🌍 GeoIP: $GEO | Web: $WEB"
echo "🌐 Real IP: $REALIP | BBR: $BBR | MSS: $MSS"
echo "💻 CPU: <code>$LOAD_AVG</code> | RAM: <code>$RAM_INFO</code>"
echo "💾 Disk: <code>$DISK_INFO</code>"
echo "🚫 Banned: $(ls /proc/net/xt_recent/ 2>/dev/null | xargs -I {} cat /proc/net/xt_recent/{} 2>/dev/null | wc -l)"
echo ""
echo "<b>🔌 ОТКРЫТЫЕ ПОРТЫ:</b>"
echo "<code>$PORTS_INFO</code>"
EOF
    chmod +x /root/scripts/status.sh

    # SET LIMIT
    cat <<'EOF' > /root/scripts/set_limit.sh
#!/bin/bash
NAME=$1; SPEED=$2
UP_SCRIPT="/etc/wireguard/up.sh"; WG_CONF="/etc/wireguard/wg0.conf"
IP=$(grep -A 3 "^# Client: ${NAME}$" "$WG_CONF" | grep AllowedIPs | awk '{print $3}' | cut -d/ -f1 | tr -d ',')
[ -z "$IP" ] && echo "ERROR" && exit 1
sed -i "/# Client:$NAME/d" "$UP_SCRIPT"
sed -i '/^exit 0/d' "$UP_SCRIPT"
if [ "$SPEED" -eq 0 ]; then
    echo "exit 0" >> "$UP_SCRIPT"
    bash "$UP_SCRIPT"
    echo "UNLIM"
    exit 0
fi

if [ "$SPEED" -ge 500 ]; then
    BURST="1500k"
else
    BURST="300k"
fi

ID=$(echo "$IP" | cut -d. -f4)

cat <<RULES >> "$UP_SCRIPT"
tc class add dev wg0 parent 1:1 classid 1:$ID htb rate ${SPEED}mbit ceil ${SPEED}mbit burst ${BURST} cburst ${BURST} prio 1 # Client:$NAME
tc filter add dev wg0 protocol ip parent 1:0 prio 1 u32 match ip dst $IP flowid 1:$ID # Client:$NAME

tc class add dev ifb0 parent 1:1 classid 1:$ID htb rate ${SPEED}mbit ceil ${SPEED}mbit burst ${BURST} cburst ${BURST} prio 1 # Client:$NAME
tc filter add dev ifb0 protocol ip parent 1:0 prio 1 u32 match ip src $IP flowid 1:$ID # Client:$NAME
RULES

echo "exit 0" >> "$UP_SCRIPT"
bash "$UP_SCRIPT"
echo "SET"
EOF
    chmod +x /root/scripts/set_limit.sh

    # ADD PORT (поддержка формата 8443:443 и 443)
    cat <<'EOF' > /root/scripts/add_port.sh
#!/bin/bash
CLIENT_NAME=$1; RAW_PORT=$2
UP_SCRIPT="/etc/wireguard/up.sh"; WG_CONF="/etc/wireguard/wg0.conf"
REAL_IF=$(ip -4 route show default | awk '/default/ {print $5}')
TARGET_IP=$(grep -A 3 "^# Client: ${CLIENT_NAME}$" "$WG_CONF" | grep AllowedIPs | awk '{print $3}' | cut -d/ -f1 | tr -d ',')
[ -z "$TARGET_IP" ] && echo "ERROR" && exit 1

if [[ "$RAW_PORT" == *:* ]]; then
    EXT_PORT="${RAW_PORT%%:*}"
    INT_PORT="${RAW_PORT##*:}"
else
    EXT_PORT="$RAW_PORT"
    INT_PORT="$RAW_PORT"
fi

if ! [[ "$EXT_PORT" =~ ^[0-9]+$ ]] || ! [[ "$INT_PORT" =~ ^[0-9]+$ ]]; then echo "ERROR"; exit 1; fi
if grep -q "dport $EXT_PORT " "$UP_SCRIPT"; then echo "BUSY"; exit 1; fi

ufw allow "$EXT_PORT" >/dev/null 2>&1
ufw route allow in on "$REAL_IF" out on wg0 to "$TARGET_IP" port "$INT_PORT" >/dev/null 2>&1

sed -i '/^exit 0/d' "$UP_SCRIPT"
echo "iptables -t nat -A PREROUTING -i $REAL_IF -p tcp --dport $EXT_PORT -j DNAT --to-destination $TARGET_IP:$INT_PORT # Port:$EXT_PORT" >> "$UP_SCRIPT"
echo "iptables -t nat -A PREROUTING -i $REAL_IF -p udp --dport $EXT_PORT -j DNAT --to-destination $TARGET_IP:$INT_PORT # Port:$EXT_PORT" >> "$UP_SCRIPT"
echo "exit 0" >> "$UP_SCRIPT"

systemctl restart wg-quick@wg0
echo "SUCCESS"
EOF
    chmod +x /root/scripts/add_port.sh

    # DEL PORT
    cat <<'EOF' > /root/scripts/del_port.sh
#!/bin/bash
PORT=$1; UP_SCRIPT="/etc/wireguard/up.sh"
if grep -q "dport $PORT " "$UP_SCRIPT"; then
    sed -i "/--dport $PORT /d" "$UP_SCRIPT"
    sed -i "/PORT_$PORT/d" "$UP_SCRIPT"
    ufw delete allow "$PORT" >/dev/null 2>&1
    systemctl restart wg-quick@wg0
    echo "SUCCESS"
else echo "ERROR"; fi
EOF
    chmod +x /root/scripts/del_port.sh

    # ADD CLIENT (без разрыва соединений через wg syncconf)
    cat <<'EOF' > /root/scripts/add.sh
#!/bin/bash
NAME=$1; [ -z "$NAME" ] && echo "ERROR" && exit 1
WG_CONF="/etc/wireguard/wg0.conf"; CLIENT_DIR="/root/wg_clients"; mkdir -p "$CLIENT_DIR"
WG_BASE=$(grep "^Address" "$WG_CONF" | head -1 | awk '{print $3}' | cut -d/ -f1 | cut -d. -f1-3)
LAST_OCT=$(grep "AllowedIPs" "$WG_CONF" | grep -oP "$WG_BASE\.\d+" | cut -d. -f4 | sort -rn | head -1)
NEW_IP="$WG_BASE.$(( ${LAST_OCT:-2} + 1 ))"
PRIV=$(wg genkey); PUB=$(echo "$PRIV" | wg pubkey)
SRV_PUB=$(grep "PrivateKey" "$WG_CONF" | awk '{print $3}' | wg pubkey)
EXT_IP=$(curl -4 -s --connect-timeout 3 eth0.me); PORT=$(grep "ListenPort" "$WG_CONF" | awk '{print $3}')
DETECTED_DNS=$(grep "DNS =" "$CLIENT_DIR/Router.conf" 2>/dev/null | awk '{print $3}')
DNS_SRV=${DETECTED_DNS:-8.8.8.8}
echo -e "\n# Client: $NAME\n[Peer]\nPublicKey = $PUB\nAllowedIPs = $NEW_IP/32" >> "$WG_CONF"
cat <<CFG > "$CLIENT_DIR/$NAME.conf"
[Interface]
PrivateKey = $PRIV
Address = $NEW_IP/24
DNS = $DNS_SRV
[Peer]
PublicKey = $SRV_PUB
Endpoint = $EXT_IP:$PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CFG

wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || systemctl restart wg-quick@wg0
echo "SUCCESS|$CLIENT_DIR/$NAME.conf"
EOF
    chmod +x /root/scripts/add.sh

    # DEL CLIENT (без разрыва соединений через wg syncconf)
    cat <<'EOF' > /root/scripts/del.sh
#!/bin/bash
NAME=$1; WG_CONF="/etc/wireguard/wg0.conf"; UP_SCRIPT="/etc/wireguard/up.sh"
LINE=$(grep -n "^# Client: ${NAME}$" "$WG_CONF" | cut -d: -f1 | head -1)
if [ -n "$LINE" ]; then
    sed -i "/# Client:$NAME/d" "$UP_SCRIPT"
    sed -i "${LINE},$((LINE + 3))d" "$WG_CONF"
    sed -i '/^$/N;/^\n$/D' "$WG_CONF"
    rm -f "/root/wg_clients/$NAME.conf"
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || systemctl restart wg-quick@wg0
    echo "SUCCESS"
else echo "ERROR"; fi
EOF
    chmod +x /root/scripts/del.sh

    # LIST / GET FILE
    cat <<'EOF' > /root/scripts/list.sh
#!/bin/bash
grep "^# Client:" /etc/wireguard/wg0.conf | awk '{print $3}'
EOF
    chmod +x /root/scripts/list.sh

    cat <<'EOF' > /root/scripts/get_file.sh
#!/bin/bash
NAME=$1; FILE="/root/wg_clients/$NAME.conf"
if [ -f "$FILE" ]; then echo "FOUND|$FILE"; else echo "ERROR"; fi
EOF
    chmod +x /root/scripts/get_file.sh

    # CLIENTS INFO (с онлайн-статусом, паузой и трафиком)
    cat <<'EOF' > /root/scripts/clients.sh
#!/bin/bash
WG_CONF="/etc/wireguard/wg0.conf"; UP_SCRIPT="/etc/wireguard/up.sh"

fmt_b() {
    local b=${1:-0}
    if [ "$b" -ge 1073741824 ]; then awk -v x="$b" 'BEGIN {printf "%.1fG", x/1073741824}'
    elif [ "$b" -ge 1048576 ]; then awk -v x="$b" 'BEGIN {printf "%.1fM", x/1048576}'
    elif [ "$b" -ge 1024 ]; then awk -v x="$b" 'BEGIN {printf "%.0fK", x/1024}'
    else echo "${b}B"; fi
}

declare -A m_on m_tr
NOW_TS=$(date +%s)
if ip link show wg0 >/dev/null 2>&1; then
    while IFS=$'\t' read -r pub psk ep aips hs rx tx ka; do
        [ -z "$aips" ] && continue
        p_ip=$(echo "$aips" | cut -d',' -f1 | cut -d'/' -f1)
        if [ -n "$hs" ] && [ "$hs" -gt 0 ] && [ $((NOW_TS - hs)) -lt 180 ]; then m_on[$p_ip]="🟢"; else m_on[$p_ip]="⚪"; fi
        m_tr[$p_ip]=$(fmt_b $(( ${rx:-0} + ${tx:-0} )))
    done < <(wg show wg0 dump 2>/dev/null | tail -n +2)
fi

echo "<b>👥 КЛИЕНТЫ:</b>"
if [ -f "$WG_CONF" ]; then
    grep "^# Client:" "$WG_CONF" | awk '{print $3}' | while read name; do
        aip_line=$(grep -A 3 "^# Client: ${name}$" "$WG_CONF" | grep AllowedIPs | head -1)
        ip=$(echo "$aip_line" | awk '{print $3}' | cut -d/ -f1 | tr -d ',')
        if echo "$aip_line" | grep -q "^#PAUSED#"; then
            st="⏸️"
        else
            st="${m_on[$ip]:-⚪}"
        fi
        tr="${m_tr[$ip]:-0B}"
        LIMIT=$(grep "# Client:$name" "$UP_SCRIPT" 2>/dev/null | grep "rate" | head -1 | awk -F'rate ' '{print $2}' | awk '{print $1}' | sed 's/mbit//')
        [ -n "$LIMIT" ] && LIMIT_STR="📉 ${LIMIT}Mb" || LIMIT_STR="♾️ Unlim"
        echo "$st <b>$name</b> <code>$ip</code> [$LIMIT_STR | $tr]"
    done
fi
EOF
    chmod +x /root/scripts/clients.sh

    # LIST LIMITS
    cat <<'EOF' > /root/scripts/list_limits.sh
#!/bin/bash
WG_CONF="/etc/wireguard/wg0.conf"; UP_SCRIPT="/etc/wireguard/up.sh"
if [ -f "$WG_CONF" ]; then
    grep "^# Client:" "$WG_CONF" | awk '{print $3}' | while read name; do
        LIMIT=$(grep "# Client:$name" "$UP_SCRIPT" 2>/dev/null | grep "rate" | head -1 | awk -F'rate ' '{print $2}' | awk '{print $1}' | sed 's/mbit//')
        [ -z "$LIMIT" ] && LIMIT="Unlim" || LIMIT="${LIMIT}Mb"
        echo "$name|$LIMIT"
    done
fi
EOF
    chmod +x /root/scripts/list_limits.sh

    # SSH KEYS
    cat <<'EOF' > /root/scripts/ssh_keys.sh
#!/bin/bash
ACTION=$1; NAME=$2
KEY_DIR="/etc/wireguard/ssh_key"; AUTH_FILE="/root/.ssh/authorized_keys"; mkdir -p "$KEY_DIR"
if [ "$ACTION" == "gen" ]; then
    SAFE_NAME=$(echo "$NAME" | tr -dc 'a-zA-Z0-9_-')
    KEY_PATH="$KEY_DIR/$SAFE_NAME"; if [ -f "$KEY_PATH" ]; then echo "EXIST"; exit 1; fi
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q; cat "$KEY_PATH.pub" >> "$AUTH_FILE"; echo "OK|$KEY_PATH"
elif [ "$ACTION" == "list" ]; then ls -1 "$KEY_DIR" | grep -v ".pub"
elif [ "$ACTION" == "path" ]; then
    SAFE_NAME=$(echo "$NAME" | tr -dc 'a-zA-Z0-9_-'); [ -f "$KEY_DIR/$SAFE_NAME" ] && echo "FOUND|$KEY_DIR/$SAFE_NAME" || echo "ERROR"
elif [ "$ACTION" == "del" ]; then
    SAFE_NAME=$(echo "$NAME" | tr -dc 'a-zA-Z0-9_-'); KEY_PATH="$KEY_DIR/$SAFE_NAME"
    if [ -f "$KEY_PATH" ]; then
        [ -f "$KEY_PATH.pub" ] && sed -i "/$(cat $KEY_PATH.pub | awk '{print $2}')/d" "$AUTH_FILE"
        rm -f "$KEY_PATH" "$KEY_PATH.pub"; echo "DELETED"
    else echo "NOT_FOUND"; fi
fi
EOF
    chmod +x /root/scripts/ssh_keys.sh

    # SSH TOGGLE
    cat <<'EOF' > /root/scripts/ssh_toggle.sh
#!/bin/bash
CFG="/etc/ssh/sshd_config"; AUTH_FILE="/root/.ssh/authorized_keys"
if [ ! -s "$AUTH_FILE" ]; then echo "NO_KEYS"; exit 1; fi
if grep -q "^PasswordAuthentication no" "$CFG"; then
    sed -i '/^PasswordAuthentication/d' "$CFG"; echo "PasswordAuthentication yes" >> "$CFG"; STATUS="PASS_ON"
else
    sed -i '/^PasswordAuthentication/d' "$CFG"; echo "PasswordAuthentication no" >> "$CFG"; STATUS="PASS_OFF"
fi
systemctl restart ssh; systemctl restart sshd; echo "$STATUS"
EOF
    chmod +x /root/scripts/ssh_toggle.sh

    # PYTHON BOT
    cat <<EOF > /root/tg_bot.py
import telebot
import subprocess
import os
import time
from telebot import types
TOKEN = "$TOKEN"
ADMIN_ID = int("$ID")
SCRIPT_DIR = "/root/scripts"
bot = telebot.TeleBot(TOKEN)
def call_script(script, *args):
    cmd = [os.path.join(SCRIPT_DIR, script)] + list(args)
    try: return subprocess.check_output(cmd, stderr=subprocess.STDOUT).decode('utf-8').strip()
    except Exception as e: return f"Error: {e}"
def main_menu():
    m = types.ReplyKeyboardMarkup(resize_keyboard=True, row_width=2)
    m.add("📊 Инфраструктура", "🛡 Безопасность")
    m.add("👥 Клиенты", "🔌 Добавить порт")
    m.add("➕ Создать Клиента", "🗑 Удалить Клиента")
    m.add("🚀 Лимит скорости", "❌ Удалить порт")
    m.add("⏸️ Пауза клиента", "💾 Скачать бэкап")
    return m
def security_menu():
    m = types.ReplyKeyboardMarkup(resize_keyboard=True, row_width=2)
    m.add("🔑 SSH Ключи", "🔐 Toggle SSH (Key/Pass)")
    m.add("🌍 GeoIP Меню", "🌐 Реальные IP (Real/NAT)")
    m.add("🔙 Назад")
    return m
def keys_menu():
    m = types.ReplyKeyboardMarkup(resize_keyboard=True, row_width=2)
    m.add("🆕 Создать Ключ", "📥 Скачать Ключ")
    m.add("🗑 Удалить Ключ", "🔙 Назад в Sec")
    return m
def back_menu():
    m = types.ReplyKeyboardMarkup(resize_keyboard=True)
    m.add("🔙 Отмена")
    return m
@bot.message_handler(commands=['start'])
def start(m):
    if m.from_user.id != ADMIN_ID: return
    bot.send_message(m.chat.id, "🛡👋 <b>Привет, Хозяин! Сервер в норме.</b>", reply_markup=main_menu(), parse_mode='HTML')
@bot.message_handler(func=lambda m: m.text == "🔙 Назад")
def go_back(m): bot.send_message(m.chat.id, "Меню", reply_markup=main_menu())
@bot.message_handler(func=lambda m: m.text == "🔙 Назад в Sec")
def go_back_sec(m): bot.send_message(m.chat.id, "Безопасность", reply_markup=security_menu())
@bot.message_handler(func=lambda m: m.text == "🔙 Отмена")
def cancel_op(m): bot.send_message(m.chat.id, "Отменено.", reply_markup=main_menu())
@bot.message_handler(func=lambda m: m.text == "📊 Инфраструктура")
def status(m): bot.send_message(m.chat.id, call_script('status.sh'), parse_mode='HTML')
@bot.message_handler(func=lambda m: m.text == "🛡 Безопасность")
def sec(m): bot.send_message(m.chat.id, "🛡 Настройки:", reply_markup=security_menu())
@bot.message_handler(func=lambda m: m.text == "💾 Скачать бэкап")
def send_bk(m):
    if m.from_user.id != ADMIN_ID: return
    bot.send_message(m.chat.id, "⏳ Создаю архив...")
    res = call_script('make_backup.sh')
    if "OK|" in res:
        try:
            with open(res.split("|")[1], 'rb') as f:
                bot.send_document(m.chat.id, f, caption="💾 Резервная копия VPS", reply_markup=main_menu())
        except Exception as e:
            bot.send_message(m.chat.id, f"❌ Ошибка отправки: {e}", reply_markup=main_menu())
    else:
        bot.send_message(m.chat.id, "❌ Ошибка создания бэкапа.", reply_markup=main_menu())
@bot.message_handler(func=lambda m: m.text == "⏸️ Пауза клиента")
def pause_u(m):
    res = call_script('list.sh')
    if not res: bot.send_message(m.chat.id, "Пусто.", reply_markup=main_menu()); return
    items = res.splitlines()
    txt = "<b>⏸️ Пауза / Разблокировка:</b>\n"
    for i, item in enumerate(items, 1): txt += f"{i}. {item}\n"
    msg = bot.send_message(m.chat.id, txt + "\n👇 Цифра:", parse_mode='HTML', reply_markup=back_menu())
    bot.register_next_step_handler(msg, pause_u_2, items)
def pause_u_2(m, items):
    if m.text == "🔙 Отмена": start(m); return
    if not m.text.isdigit(): return
    idx = int(m.text) - 1
    if 0 <= idx < len(items):
        res = call_script('pause_client.sh', items[idx])
        if "PAUSED" in res: msg = f"⏸️ Клиент <b>{items[idx]}</b> поставлен на паузу."
        elif "RESUMED" in res: msg = f"✅ Клиент <b>{items[idx]}</b> разблокирован."
        else: msg = "❌ Ошибка."
        bot.send_message(m.chat.id, msg, parse_mode='HTML', reply_markup=main_menu())
    else:
        bot.send_message(m.chat.id, "Неверно.", reply_markup=main_menu())
@bot.message_handler(func=lambda m: m.text == "🌐 Реальные IP (Real/NAT)")
def realip_tog(m):
    res = call_script('realip_toggle.sh')
    if "REAL_ON" in res: msg = "✅ Реальные IP <b>ВКЛЮЧЕНЫ</b> (MASQUERADE на wg0 удален)."
    elif "REAL_OFF" in res: msg = "⚠️ Реальные IP <b>ВЫКЛЮЧЕНЫ</b> (включен NAT/MASQUERADE на wg0)."
    else: msg = "❌ Ошибка переключения."
    bot.send_message(m.chat.id, msg, parse_mode='HTML', reply_markup=security_menu())
@bot.message_handler(func=lambda m: m.text == "🔑 SSH Ключи")
def keys_main(m): bot.send_message(m.chat.id, "Управление:", reply_markup=keys_menu())
@bot.message_handler(func=lambda m: m.text == "🆕 Создать Ключ")
def k_create(m):
    msg = bot.send_message(m.chat.id, "📝 Введите имя ключа:", reply_markup=back_menu())
    bot.register_next_step_handler(msg, k_create_2)
def k_create_2(m):
    if m.text == "🔙 Отмена": sec(m); return
    res = call_script('ssh_keys.sh', 'gen', m.text.strip())
    if "OK" in res:
        try:
            with open(res.split("|")[1], 'rb') as f:
                bot.send_document(m.chat.id, f, caption=f"✅ Ключ <b>{m.text.strip()}</b> создан!", parse_mode='HTML', reply_markup=keys_menu())
        except: bot.send_message(m.chat.id, "✅ Создан, ошибка отправки.", reply_markup=keys_menu())
    elif "EXIST" in res: bot.send_message(m.chat.id, "⚠️ Имя занято.", reply_markup=keys_menu())
    else: bot.send_message(m.chat.id, "❌ Ошибка.", reply_markup=keys_menu())
@bot.message_handler(func=lambda m: m.text == "📥 Скачать Ключ")
def k_dl(m):
    res = call_script('ssh_keys.sh', 'list')
    if not res: bot.send_message(m.chat.id, "Пусто.", reply_markup=keys_menu()); return
    items = res.splitlines()
    txt = "<b>📥 Скачать:</b>\n"
    for i, item in enumerate(items, 1): txt += f"{i}. {item}\n"
    msg = bot.send_message(m.chat.id, txt + "\n👇 Цифра:", parse_mode='HTML', reply_markup=back_menu())
    bot.register_next_step_handler(msg, k_dl_2, items)
def k_dl_2(m, items):
    if m.text == "🔙 Отмена": keys_main(m); return
    if not m.text.isdigit(): return
    idx = int(m.text) - 1
    if 0 <= idx < len(items):
        res = call_script('ssh_keys.sh', 'path', items[idx])
        if "FOUND" in res:
            try:
                with open(res.split("|")[1], 'rb') as f:
                    bot.send_document(m.chat.id, f, caption=f"🔑 Ключ: {items[idx]}", reply_markup=keys_menu())
            except: pass
    else: bot.send_message(m.chat.id, "Неверно.")
@bot.message_handler(func=lambda m: m.text == "🗑 Удалить Ключ")
def k_del(m):
    res = call_script('ssh_keys.sh', 'list')
    if not res: bot.send_message(m.chat.id, "Пусто.", reply_markup=keys_menu()); return
    items = res.splitlines()
    txt = "<b>🗑 Удалить:</b>\n"
    for i, item in enumerate(items, 1): txt += f"{i}. {item}\n"
    msg = bot.send_message(m.chat.id, txt + "\n👇 Цифра:", parse_mode='HTML', reply_markup=back_menu())
    bot.register_next_step_handler(msg, k_del_2, items)
def k_del_2(m, items):
    if m.text == "🔙 Отмена": keys_main(m); return
    if not m.text.isdigit(): return
    idx = int(m.text) - 1
    if 0 <= idx < len(items):
        call_script('ssh_keys.sh', 'del', items[idx])
        bot.send_message(m.chat.id, f"✅ Удален: {items[idx]}", reply_markup=keys_menu())
@bot.message_handler(func=lambda m: m.text == "🔐 Toggle SSH (Key/Pass)")
def ssh_tog(m):
    bot.send_message(m.chat.id, "⏳ ...")
    res = call_script('ssh_toggle.sh')
    if "PASS_OFF" in res: msg = "✅ Только ключи."
    elif "PASS_ON" in res: msg = "⚠️ Пароль включен."
    elif "NO_KEYS" in res: msg = "⛔️ Нет ключей!"
    else: msg = "❌ Ошибка."
    bot.send_message(m.chat.id, msg, reply_markup=security_menu())
@bot.message_handler(func=lambda m: m.text == "🌍 GeoIP Меню")
def geo_m(m):
    mk = types.ReplyKeyboardMarkup(resize_keyboard=True, row_width=2)
    mk.add("✅ Включить", "❌ Выключить", "🔙 Назад в Sec")
    bot.send_message(m.chat.id, "GeoIP:", reply_markup=mk)
@bot.message_handler(func=lambda m: m.text == "✅ Включить")
def geo_on_1(m):
    msg = bot.send_message(m.chat.id, "📝 Коды (ru us):", reply_markup=back_menu())
    bot.register_next_step_handler(msg, geo_on_2)
def geo_on_2(m):
    if m.text == "🔙 Отмена": sec(m); return
    bot.send_message(m.chat.id, "⏳ Скачиваю...")
    res = call_script('geoip_on.sh', m.text.strip())
    if "DONE" in res: bot.send_message(m.chat.id, "✅ GeoIP ON!", reply_markup=security_menu())
    else: bot.send_message(m.chat.id, "❌ Ошибка.", reply_markup=security_menu())
@bot.message_handler(func=lambda m: m.text == "❌ Выключить")
def geo_off(m):
    call_script('geoip_off.sh')
    bot.send_message(m.chat.id, "✅ GeoIP OFF.", reply_markup=security_menu())
@bot.message_handler(func=lambda m: m.text == "👥 Клиенты")
def clients_show(m):
    res = call_script('clients.sh')
    if len(res) < 20: res += "\n(Пусто)"
    mk = types.ReplyKeyboardMarkup(resize_keyboard=True, row_width=2)
    mk.add("📥 Скачать конфиг WG", "🔙 Назад")
    bot.send_message(m.chat.id, res, parse_mode='HTML', reply_markup=mk)
@bot.message_handler(func=lambda m: m.text == "📥 Скачать конфиг WG")
def wg_dl(m):
    res = call_script('list.sh')
    if not res: bot.send_message(m.chat.id, "Нет клиентов.", reply_markup=main_menu()); return
    items = res.splitlines()
    txt = "<b>📥 Скачать:</b>\n"
    for i, item in enumerate(items, 1): txt += f"{i}. {item}\n"
    msg = bot.send_message(m.chat.id, txt + "\n👇 Цифра:", parse_mode='HTML', reply_markup=back_menu())
    bot.register_next_step_handler(msg, wg_dl_2, items)
def wg_dl_2(m, items):
    if m.text == "🔙 Отмена": clients_show(m); return
    if not m.text.isdigit(): return
    idx = int(m.text) - 1
    if 0 <= idx < len(items):
        res = call_script('get_file.sh', items[idx])
        if "FOUND" in res:
            try:
                with open(res.split("|")[1], 'rb') as f:
                    bot.send_document(m.chat.id, f, caption=f"📄 Config: {items[idx]}")
            except: pass
    else: bot.send_message(m.chat.id, "Неверно.")
    clients_show(m)
@bot.message_handler(func=lambda m: m.text == "➕ Создать Клиента")
def add_u(m):
    msg = bot.send_message(m.chat.id, "📝 Имя:", reply_markup=back_menu())
    bot.register_next_step_handler(msg, add_u_2)
def add_u_2(m):
    if m.text == "🔙 Отмена": start(m); return
    name = m.text.strip()
    res = call_script('add.sh', name)
    if "SUCCESS" in res:
        try:
            with open(res.split('|')[1], 'rb') as f: bot.send_document(m.chat.id, f, caption=f"✅ {name}")
        except: pass
    bot.send_message(m.chat.id, "Готово.", reply_markup=main_menu())
@bot.message_handler(func=lambda m: m.text == "🗑 Удалить Клиента")
def del_u(m):
    res = call_script('list.sh')
    if not res: bot.send_message(m.chat.id, "Пусто.", reply_markup=main_menu()); return
    items = res.splitlines()
    txt = "<b>🗑 Удалить:</b>\n"
    for i, item in enumerate(items, 1): txt += f"{i}. {item}\n"
    msg = bot.send_message(m.chat.id, txt + "\n👇 Цифра:", parse_mode='HTML', reply_markup=back_menu())
    bot.register_next_step_handler(msg, del_u_2, items)
def del_u_2(m, items):
    if m.text == "🔙 Отмена": start(m); return
    if not m.text.isdigit(): return
    idx = int(m.text) - 1
    if 0 <= idx < len(items):
        call_script('del.sh', items[idx])
        bot.send_message(m.chat.id, f"✅ Удален: {items[idx]}")
    bot.send_message(m.chat.id, "Меню", reply_markup=main_menu())
@bot.message_handler(func=lambda m: m.text == "🚀 Лимит скорости")
def lim_1(m):
    res = call_script('list_limits.sh')
    if not res: bot.send_message(m.chat.id, "Нет клиентов.", reply_markup=main_menu()); return
    items = []
    txt = "<b>🚀 Кому? (Текущие лимиты):</b>\n"
    lines = res.splitlines()
    for i, line in enumerate(lines, 1):
        name, limit = line.split("|")
        items.append(name)
        txt += f"{i}. <b>{name}</b> ({limit})\n"
    msg = bot.send_message(m.chat.id, txt + "\n👇 Цифра:", parse_mode='HTML', reply_markup=back_menu())
    bot.register_next_step_handler(msg, lim_2, items)
def lim_2(m, items):
    if m.text == "🔙 Отмена": start(m); return
    if not m.text.isdigit(): return
    idx = int(m.text) - 1
    if 0 <= idx < len(items):
        msg = bot.send_message(m.chat.id, f"Введите лимит для {items[idx]} (Мбит/с, 0 - снять):")
        bot.register_next_step_handler(msg, lim_3, items[idx])
    else: bot.send_message(m.chat.id, "Ошибка.")
def lim_3(m, name):
    if not m.text.isdigit(): return
    call_script('set_limit.sh', name, m.text)
    bot.send_message(m.chat.id, "✅ Лимит обновлен.", reply_markup=main_menu())
@bot.message_handler(func=lambda m: m.text == "🔌 Добавить порт")
def add_p(m):
    res = call_script('list.sh')
    if not res: bot.send_message(m.chat.id, "Нет клиентов.", reply_markup=main_menu()); return
    items = res.splitlines()
    txt = "<b>Кому?</b>\n"
    for i, item in enumerate(items, 1): txt += f"{i}. {item}\n"
    msg = bot.send_message(m.chat.id, txt + "\n👇 Цифра:", parse_mode='HTML', reply_markup=back_menu())
    bot.register_next_step_handler(msg, add_p_2, items)
def add_p_2(m, items):
    if m.text == "🔙 Отмена": start(m); return
    if not m.text.isdigit(): return
    idx = int(m.text) - 1
    if 0 <= idx < len(items):
        msg = bot.send_message(m.chat.id, f"⌨️ Порт для {items[idx]} (напр: 443 или 8443:443):")
        bot.register_next_step_handler(msg, add_p_3, items[idx])
    else: bot.send_message(m.chat.id, "Ошибка.")
def add_p_3(m, name):
    val = m.text.strip()
    if not val.replace(":", "").isdigit(): return
    res = call_script('add_port.sh', name, val)
    if "SUCCESS" in res: bot.send_message(m.chat.id, "✅ Порт открыт.", reply_markup=main_menu())
    elif "BUSY" in res: bot.send_message(m.chat.id, "⚠️ Внешний порт уже занят.", reply_markup=main_menu())
    else: bot.send_message(m.chat.id, "❌ Ошибка.", reply_markup=main_menu())
@bot.message_handler(func=lambda m: m.text == "❌ Удалить порт")
def del_p(m):
    msg = bot.send_message(m.chat.id, "⌨️ Внешний номер порта:", reply_markup=back_menu())
    bot.register_next_step_handler(msg, del_p_2)
def del_p_2(m):
    if m.text == "🔙 Отмена": start(m); return
    call_script('del_port.sh', m.text)
    bot.send_message(m.chat.id, "✅ Порт закрыт.", reply_markup=main_menu())

if __name__ == "__main__":
    while True:
        try: bot.polling(none_stop=True)
        except: time.sleep(5)
EOF

    cat <<EOF > /etc/systemd/system/tgbot.service
[Unit]
Description=WG Bot
After=network.target
[Service]
ExecStart=/usr/bin/python3 /root/tg_bot.py
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tgbot
    systemctl restart tgbot
    echo "✅ Бот установлен."
}

manage_backup() {
    BACKUP_DIR="/root/vps_backups"
    mkdir -p "$BACKUP_DIR"

    while true; do
        clear
        BK_CRON_ST=$(crontab -l 2>/dev/null | grep -q "backup_tg" && echo -e "\e[1;32mВКЛ\e[0m" || echo -e "\e[1;31mВЫКЛ\e[0m")
        echo -e "=== 💾 БЭКАП И ВОССТАНОВЛЕНИЕ ==="
        echo "1) 📦 Создать резервную копию (локально)"
        echo "2) 📤 Создать и отправить бэкап в Telegram"
        echo -e "3) 🔄 Автобэкап в Telegram (Вс, 04:00) [ $BK_CRON_ST ]"
        echo "4) ♻️ Восстановить из резервной копии"
        echo "5) 📋 Список бэкапов"
        echo "0) 🔙 Назад"
        read -p "Выбор: " BK_OPT

        case $BK_OPT in
            1)
                ARCHIVE="$BACKUP_DIR/vps_backup_$(date '+%Y-%m-%d_%H-%M-%S').tar.gz"
                PATHS=()
                [ -d /etc/wireguard ] && PATHS+=("/etc/wireguard")
                [ -d /root/wg_clients ] && PATHS+=("/root/wg_clients")
                [ -d /etc/ipset ] && PATHS+=("/etc/ipset")
                [ -f /root/.tg_config ] && PATHS+=("/root/.tg_config")

                if [ ${#PATHS[@]} -eq 0 ]; then
                    echo "❌ Нет данных для бэкапа."
                else
                    tar -czf "$ARCHIVE" "${PATHS[@]}" 2>/dev/null
                    echo -e "✅ Бэкап создан:\n   \e[1;36m$ARCHIVE\e[0m"
                fi
                ;;
            2)
                if [ ! -f /root/.tg_config ]; then
                    echo "❌ Сначала настройте Telegram-бота (пункт 9 главного меню)."
                else
                    /usr/local/bin/vps backup_tg
                    echo "✅ Бэкап создан и отправлен в Telegram."
                fi
                ;;
            3)
                CRON_BK="0 4 * * 0 /usr/local/bin/vps backup_tg > /dev/null 2>&1"
                if crontab -l 2>/dev/null | grep -q "backup_tg"; then
                    crontab -l 2>/dev/null | grep -v "backup_tg" | crontab -
                    echo "❌ Автобэкап в Telegram отключен."
                else
                    (crontab -l 2>/dev/null | grep -v "backup_tg"; echo "$CRON_BK") | crontab -
                    echo "✅ Автобэкап в Telegram включен (каждое воскресенье в 04:00)."
                fi
                ;;
            4)
                mapfile -t BACKUPS < <(ls -1t "$BACKUP_DIR"/vps_backup_*.tar.gz 2>/dev/null)
                if [ ${#BACKUPS[@]} -eq 0 ]; then
                    echo "❌ Бэкапы не найдены в $BACKUP_DIR."
                else
                    echo "Доступные бэкапы:"
                    for idx in "${!BACKUPS[@]}"; do
                        echo "$((idx + 1))) $(basename "${BACKUPS[$idx]}")"
                    done
                    read -p "Введите номер бэкапа для восстановления: " B_NUM
                    if [[ "$B_NUM" =~ ^[0-9]+$ ]] && [ "$B_NUM" -ge 1 ] && [ "$B_NUM" -le "${#BACKUPS[@]}" ]; then
                        SEL_ARCH="${BACKUPS[$((B_NUM - 1))]}"
                        tar -xzf "$SEL_ARCH" -C /
                        chmod +x "$UP_SCRIPT" 2>/dev/null
                        systemctl restart wg-quick@wg0 2>/dev/null
                        echo -e "✅ Восстановлено из \e[1;32m$(basename "$SEL_ARCH")\e[0m и WireGuard перезапущен."
                    else
                        echo "❌ Неверный номер."
                    fi
                fi
                ;;
            5)
                echo -e "\nФайлы в $BACKUP_DIR:"
                ls -lh "$BACKUP_DIR"/vps_backup_*.tar.gz 2>/dev/null || echo "Пусто."
                ;;
            0) break ;;
        esac
        read -p "Enter..." temp
    done
}

toggle_bbr() {
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$CUR_CC" == "bbr" ]; then
        rm -f /etc/sysctl.d/99-vps-bbr.conf
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
        echo -e "⚠️ TCP BBR \e[1;31mВЫКЛЮЧЕН\e[0m (возвращен cubic)."
    else
        cat <<EOF > /etc/sysctl.d/99-vps-bbr.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl --system >/dev/null 2>&1
        if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]; then
            echo -e "✅ TCP BBR \e[1;32mВКЛЮЧЕН\e[0m (ускорение TCP через VPN активно)."
        else
            echo -e "❌ Не удалось включить BBR (возможно, ядро не поддерживает)."
        fi
    fi
}

self_update() {
    echo -e "📥 Скачиваю свежую версию с GitHub..."
    TMP_SCRIPT="/tmp/vps_update.sh"
    if ! curl -fsSL --connect-timeout 10 "$REPO_URL" -o "$TMP_SCRIPT"; then
        echo -e "\e[1;31m❌ Ошибка скачивания ($REPO_URL).\e[0m"
        return 1
    fi
    sed -i 's/\r$//' "$TMP_SCRIPT"
    if ! bash -n "$TMP_SCRIPT"; then
        echo -e "\e[1;31m❌ Ошибка синтаксиса в скачанном файле! Обновление отменено.\e[0m"
        rm -f "$TMP_SCRIPT"
        return 1
    fi
    cp "$TMP_SCRIPT" /usr/local/bin/vps
    chmod +x /usr/local/bin/vps
    rm -f "$TMP_SCRIPT"
    echo -e "\e[1;32m✅ Скрипт успешно обновлен! Перезапускаю...\e[0m"
    sleep 1
    exec /usr/local/bin/vps
}

show_tech_menu() {
    while true; do
        clear
        BBR_ST=$([ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ] && echo -e "\e[1;32mВКЛ\e[0m" || echo -e "\e[1;31mВЫКЛ\e[0m")
        echo -e "=== ⚙️ ТЕХНИЧЕСКОЕ ОБСЛУЖИВАНИЕ ==="
        echo "1) 🔄 Рестарт SSH"
        echo "2) 🚀 Рестарт WireGuard (wg0)"
        echo "3) ▶️  Запуск WireGuard (wg0)"
        echo "4) 📊 Состояние WireGuard (wg show)"
        echo "5) 📂 Показать файлы в /etc/wireguard"
        echo "6) 📱 ПОКАЗАТЬ QR Выбранного Клиента"
        echo "7) 🌀 REBOOT (Перезагрузка всей системы)"
        echo -e "8) 🌐 \e[1;32mУПРАВЛЕНИЕ WEB-ПАНЕЛЬЮ\e[0m"
        echo -e "9) 💾 \e[1;36mБЭКАП / ВОССТАНОВЛЕНИЕ\e[0m"
        echo -e "10) ⚡ TCP BBR [ $BBR_ST ]"
        echo -e "11) ⬆️  \e[1;33mОБНОВИТЬ СКРИПТ С GITHUB\e[0m"
        echo -e "12) 📡 \e[1;35mЖИВЫЕ ПОДКЛЮЧЕНИЯ (ПОРТЫ / ТРАФИК)\e[0m"
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
            6) grep -a "^# Client:" "$WG_CONF" | awk '{print $3}'
               read -p "Имя юзера для QR: " QN
               [ -f "$CLIENT_DIR/$QN.conf" ] && qrencode -t ansiutf8 < "$CLIENT_DIR/$QN.conf" || echo "❌ Файл не найден!" ;;
            7) read -p "⚠️ ПЕРЕЗАГРУЗИТЬ VPS? (y/n): " CONFIRM
               [ "$CONFIRM" == "y" ] && reboot ;;
            8) manage_web_panel ;;
            9) manage_backup ;;
            10) toggle_bbr ;;
            11) self_update ;;
            12) monitor_connections ;;
            0) break ;;
        esac
        read -p "Enter..." temp
    done
}

while true; do
    clear; show_infra
    echo "=== 🛡️ VPS MANAGER v3.3 ==="
    echo -e "1) 🛠 ПОЛНАЯ УСТАНОВКА"
    echo -e "2) 🔐 ЦЕНТР БЕЗОПАСНОСТИ"
    echo -e "3) 🔌 ДОБАВИТЬ ПОРТ"
    echo -e "4) ❌ УДАЛИТЬ ПОРТ"
    echo -e "5) 👥 ДОБАВИТЬ КЛИЕНТА (QR)"
    echo -e "6) 🗑 УДАЛИТЬ КЛИЕНТА"
    echo -e "7) 🏎 ИЗМЕНИТЬ ЛИМИТ СКОРОСТИ"
    echo -e "8) ⚙️ ТЕХ. ОБСЛУЖИВАНИЕ"
    echo -e "9) 🤖 \e[1;36mТЕЛЕГРАМ БОТ\e[0m"
    echo -e "10) ⏸️ ПАУЗА / РАЗБЛОКИРОВКА КЛИЕНТА"
    echo -e "11) 🔀 ЛОКАЛЬНЫЕ ПОДСЕТИ (SITE-TO-SITE)"
    echo "0) 🚪 ВЫХОД"

    read -p "Действие: " M
    case $M in
        1) full_setup ;;
        2) manage_security ;;
        3)
            echo -e "\n\e[1;34m=== 🔌 ПРОБРОС ПОРТОВ (СПИСКОМ) ===\e[0m"
            echo -e "Формат: \e[1;33m443\e[0m (1-в-1) или \e[1;33m8443:443\e[0m (Внешний:Внутренний)"
            read -p "Введите порты (через пробел или запятую): " RAW_PORTS
            [ -z "$RAW_PORTS" ] && continue

            CLEAN_PORTS=$(echo "$RAW_PORTS" | tr ',' ' ' | xargs)
            declare -A clients; declare -a names_list; i=0
            while read -r line; do
                if [[ "$line" =~ ^#\ Client:\ (.*) ]]; then
                    current_name="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^(#PAUSED#)?AllowedIPs\ =\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    if [ -n "$current_name" ]; then
                        current_ip="${BASH_REMATCH[2]}"
                        clients["$current_name"]="$current_ip"
                        names_list[$i]="$current_name"
                        echo -e "$i) 👤 \e[1;32m$current_name\e[0m \t--> $current_ip"
                        ((i++))
                        current_name=""
                    fi
                fi
            done < "$WG_CONF"

            echo "----------------------------------------------"
            read -p "Введите ИМЯ или НОМЕР (Enter = Router): " T_NAME_INPUT
            if [[ "$T_NAME_INPUT" =~ ^[0-9]+$ ]] && [ "$T_NAME_INPUT" -lt "$i" ]; then
                T_NAME="${names_list[$T_NAME_INPUT]}"
            else
                T_NAME="$T_NAME_INPUT"
            fi
            T_NAME=${T_NAME:-Router}
            TARGET_IP=${clients["$T_NAME"]}

            if [ -z "$TARGET_IP" ]; then
                echo -e "\e[1;31m❌ Ошибка: Клиент '$T_NAME' не найден!\e[0m"; read -p "Enter..." temp; continue
            fi

            echo "🛡 Защита: 1)Стандарт 2)Строго 3)Выкл"; read -p "Выбор [1]: " P_PROT
            case $P_PROT in 2) H=10; S=86400 ;; 3) H=0; S=0 ;; *) H=5; S=60 ;; esac

            for RAW_P in $CLEAN_PORTS; do
                if [[ "$RAW_P" == *:* ]]; then
                    EXT_P="${RAW_P%%:*}"
                    INT_P="${RAW_P##*:}"
                else
                    EXT_P="$RAW_P"
                    INT_P="$RAW_P"
                fi
                if ! [[ "$EXT_P" =~ ^[0-9]+$ ]] || ! [[ "$INT_P" =~ ^[0-9]+$ ]]; then
                    echo -e "\e[1;31m⚠️ Пропуск некорректного порта: $RAW_P\e[0m"
                    continue
                fi

                echo -e "⚙️ Обработка порта \e[1;33m$EXT_P -> $TARGET_IP:$INT_P\e[0m..."

                if grep -q "dport $EXT_P " "$UP_SCRIPT"; then
                    sed -i "/--dport $EXT_P /d" "$UP_SCRIPT"
                    sed -i "/name PORT_$EXT_P/d" "$UP_SCRIPT"
                fi

                ufw allow "$EXT_P" >/dev/null 2>&1
                sed -i '/^exit 0/d' "$UP_SCRIPT"

                if [ "$H" -ne 0 ]; then
                    echo "iptables -I FORWARD -i $REAL_IF -p tcp --dport $EXT_P -m state --state NEW -m recent --set --name PORT_$EXT_P" >> "$UP_SCRIPT"
                    echo "iptables -I FORWARD -i $REAL_IF -p tcp --dport $EXT_P -m state --state NEW -m recent --update --seconds $S --hitcount $H --name PORT_$EXT_P -j DROP" >> "$UP_SCRIPT"
                fi

                echo "iptables -t nat -A PREROUTING -i $REAL_IF -p tcp --dport $EXT_P -j DNAT --to-destination $TARGET_IP:$INT_P # Port:$EXT_P to $T_NAME" >> "$UP_SCRIPT"
                echo "iptables -t nat -A PREROUTING -i $REAL_IF -p udp --dport $EXT_P -j DNAT --to-destination $TARGET_IP:$INT_P # Port:$EXT_P to $T_NAME" >> "$UP_SCRIPT"
                echo "exit 0" >> "$UP_SCRIPT"
            done

            systemctl restart wg-quick@wg0
            echo -e "\e[1;32m✅ Все указанные порты проброшены на $T_NAME!\e[0m"
            read -p "Enter..." temp ;;
        4)
            echo -e "\n\e[1;34m=== ❌ УДАЛЕНИЕ ПРОБРОСА ПОРТА ===\e[0m"

            if [ ! -f "$UP_SCRIPT" ] || ! grep -q "DNAT" "$UP_SCRIPT"; then
                echo -e "\e[1;30mСписок проброшенных портов пуст.\e[0m"
                read -p "Enter..." temp; continue
            fi

            echo "Текущие правила:"
            grep "DNAT" "$UP_SCRIPT" | awk -F'--dport ' '{print $2}' | awk '{print "ID: " NR " | Внешний порт: " $1}'

            read -p "Введите ВНЕШНИЙ НОМЕР ПОРТА для удаления: " D_PORT
            [ -z "$D_PORT" ] && continue

            if grep -q "dport $D_PORT " "$UP_SCRIPT"; then
                echo -e "♻️ Удаляю правила для порта $D_PORT..."
                sed -i "/--dport $D_PORT /d" "$UP_SCRIPT"
                sed -i "/PORT_$D_PORT/d" "$UP_SCRIPT"
                ufw delete allow "$D_PORT" >/dev/null 2>&1

                echo -e "✅ Порт $D_PORT успешно удален из системы."
                systemctl restart wg-quick@wg0
            else
                echo -e "\e[1;31m❌ Ошибка: Порт $D_PORT не найден в списке активных правил!\e[0m"
            fi
            read -p "Enter..." temp ;;
        5)
            echo -e "\n\e[1;34m=== 👥 ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ (SMART) ===\e[0m"
            read -p "Введите имя (Латиница): " RAW_NAME

            NEW_NAME=$(echo "$RAW_NAME" | tr -cd 'a-zA-Z0-9_-')
            [ -z "$NEW_NAME" ] && { echo "❌ Имя не может быть пустым!"; read -p "Enter..." temp; continue; }

            if grep -q "^# Client: ${NEW_NAME}$" "$WG_CONF"; then
                echo "❌ Такое имя уже есть!"; read -p "Enter..." temp; continue
            fi
            WG_BASE=$(grep "^Address" "$WG_CONF" | head -1 | awk '{print $3}' | cut -d/ -f1 | cut -d. -f1-3)
            LAST_OCTET=$(grep "AllowedIPs" "$WG_CONF" | grep -oP "$WG_BASE\.\d+" | cut -d. -f4 | sort -rn | head -1)
            NEW_IP="$WG_BASE.$(( ${LAST_OCTET:-2} + 1 ))"

            CURRENT_DNS=$(grep "DNS =" "$CLIENT_DIR/Router.conf" 2>/dev/null | awk '{print $3}')
            CURRENT_DNS=${CURRENT_DNS:-8.8.8.8}

            echo "Создаем $NEW_NAME ($NEW_IP) [DNS: $CURRENT_DNS]..."

            SRV_PUB=$(grep "PrivateKey" "$WG_CONF" | awk '{print $3}' | wg pubkey)
            [ -z "$SRV_PUB" ] && SRV_PUB=$(wg show wg0 public-key 2>/dev/null)

            generate_peer_config "$NEW_NAME" "$NEW_IP" "$CURRENT_DNS" "$SRV_PUB" "false"

            echo "✅ Создано. QR-код:"
            if [ -f "$CLIENT_DIR/$NEW_NAME.conf" ]; then
                qrencode -t ansiutf8 < "$CLIENT_DIR/$NEW_NAME.conf" 2>/dev/null
            else
                echo "⚠️ Ошибка: файл конфига не создан."
            fi

            reload_wg_peers
            read -p "Enter..." temp ;;
        6)
            echo -e "\n\e[1;34m=== 🗑️ УДАЛЕНИЕ ПОЛЬЗОВАТЕЛЯ (SMART) ===\e[0m"
            declare -a names_list; declare -A clients_ips; i=0; current_name=""
            echo "Список пользователей:"
            while read -r line; do
                line=$(echo "$line" | xargs)
                if [[ "$line" =~ ^#\ Client:\ (.*) ]]; then
                    current_name="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^(#PAUSED#)?AllowedIPs\ =\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    if [ -n "$current_name" ]; then
                        ip="${BASH_REMATCH[2]}"
                        names_list[$i]="$current_name"
                        clients_ips["$current_name"]="$ip"
                        echo -e "$i) 👤 \e[1;32m$current_name\e[0m ($ip)"
                        i=$((i + 1))
                        current_name=""
                    fi
                fi
            done < "$WG_CONF"

            [ "$i" -eq 0 ] && { echo "Список пуст."; read -p "Enter..." temp; continue; }

            read -p "Введите НОМЕР для удаления: " USER_NUM
            if [[ "$USER_NUM" =~ ^[0-9]+$ ]] && [ "$USER_NUM" -lt "$i" ]; then
                DEL_NAME="${names_list[$USER_NUM]}"
                DEL_IP="${clients_ips[$DEL_NAME]}"

                echo -e "♻️ Удаление $DEL_NAME и очистка ресурсов..."

                PORTS_REMOVED=0
                if [ -f "$UP_SCRIPT" ]; then
                    PORTS_TO_CLOSE=$(grep "to-destination $DEL_IP" "$UP_SCRIPT" | grep -oP '(?<=dport )\d+' | sort -u)

                    for port in $PORTS_TO_CLOSE; do
                        echo "   -> Закрываю порт $port в UFW..."
                        ufw delete allow "$port" >/dev/null 2>&1
                        ufw delete allow "$port/tcp" >/dev/null 2>&1
                        ufw delete allow "$port/udp" >/dev/null 2>&1
                        sed -i "/PORT_$port/d" "$UP_SCRIPT"
                        PORTS_REMOVED=1
                    done

                    sed -i "/$DEL_IP/d" "$UP_SCRIPT"
                    sed -i "/# Client:$DEL_NAME/d" "$UP_SCRIPT"
                fi

                LINE=$(grep -n "^# Client: ${DEL_NAME}$" "$WG_CONF" | cut -d: -f1 | head -1)
                if [ -n "$LINE" ]; then
                    START=$LINE
                    END=$((LINE + 3))
                    sed -i "${START},${END}d" "$WG_CONF"
                    sed -i '/^$/N;/^\n$/D' "$WG_CONF"

                    rm -f "$CLIENT_DIR/$DEL_NAME.conf"
                    echo "✅ Пользователь $DEL_NAME и все его порты удалены."
                    if [ "$PORTS_REMOVED" -eq 1 ]; then
                        systemctl restart wg-quick@wg0
                    else
                        reload_wg_peers
                    fi
                fi
            else
                echo "❌ Неверный номер!"
            fi
            read -p "Enter..." temp ;;
        7)
            echo -e "\n\e[1;34m=== 🏎️ ИЗМЕНЕНИЕ ЛИМИТА СКОРОСТИ ===\e[0m"
            [ ! -f "$WG_CONF" ] && { echo "Файл конфига не найден!"; read -p "Enter..." temp; continue; }

            declare -a names_list
            declare -A clients_ips
            i=0
            current_name=""

            echo "Список пользователей:"
            while read -r line; do
                line=$(echo "$line" | xargs)
                if [[ "$line" =~ ^#\ Client:\ (.*) ]]; then
                    current_name="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^(#PAUSED#)?AllowedIPs\ =\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    if [ -n "$current_name" ]; then
                        ip="${BASH_REMATCH[2]}"
                        names_list[$i]="$current_name"
                        clients_ips["$current_name"]="$ip"

                        CURRENT_LIMIT=$(grep -a "# Client:$current_name" "$UP_SCRIPT" 2>/dev/null | grep "rate" | head -1 | awk -F'rate ' '{print $2}' | awk '{print $1}')
                        [ -z "$CURRENT_LIMIT" ] && lim_info="\e[1;30m♾️ Unlim\e[0m" || lim_info="\e[1;33m📉 ${CURRENT_LIMIT}Mb\e[0m"

                        echo -e "$i) 👤 \e[1;32m$current_name\e[0m ($ip) [ $lim_info ]"
                        i=$((i + 1))
                        current_name=""
                    fi
                fi
            done < "$WG_CONF"

            if [ "$i" -eq 0 ]; then echo "Список пуст."; read -p "Enter..." temp; continue; fi

            echo "----------------------------------------------"
            read -p "Выберите НОМЕР клиента: " USER_NUM

            if [[ "$USER_NUM" =~ ^[0-9]+$ ]] && [ "$USER_NUM" -lt "$i" ]; then
                C_NAME="${names_list[$USER_NUM]}"
                C_IP="${clients_ips[$C_NAME]}"

                read -p "Новый лимит для $C_NAME (Мбит/с, 0 - безлимит): " NEW_S

                sed -i "/# Client:$C_NAME/d" "$UP_SCRIPT"

                if [ "$NEW_S" -ne 0 ] 2>/dev/null; then
                    apply_mirror_limit "$C_NAME" "$C_IP" "$NEW_S"
                    echo "✅ Лимит ${NEW_S}Mb установлен для $C_NAME."
                else
                    apply_mirror_limit "$C_NAME" "$C_IP" "0"
                    echo "♾️ Ограничения для $C_NAME сняты."
                fi
            else
                echo "❌ Неверный номер!"
            fi
            read -p "Enter..." temp ;;
        8) show_tech_menu ;;
        9) manage_bot ;;
        10) toggle_client_pause ;;
        11) manage_subnets ;;
        0) exit 0 ;;
    esac
done


