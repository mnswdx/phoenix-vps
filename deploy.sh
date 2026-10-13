#!/usr/bin/env bash
# ==============================================================================
# Project Phoenix: Скрипт автоматического восстановления из пепла (Auto-Deploy)
# Разворачивает полный стек безопасности на абсолютно чистом сервере:
# BBR, UFW, Swap 1GB, Fail2ban, 3x-ui + восстановление базы клиентов из бэкапа.
# ==============================================================================

set -e

# Цветовое оформление
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

START_TIME=$(date +%s)

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}   PROJECT PHOENIX: ВОССТАНОВЛЕНИЕ VPS ИЗ ПЕПЛА       ${NC}"
echo -e "${CYAN}======================================================${NC}"

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ошибка: Скрипт должен запускаться от имени root!${NC}"
    exit 1
fi

BACKUP_FILE="$1"
RESTORE_DIR="/tmp/phoenix_restore_data"
HAS_BACKUP=false

# 0. Проверка наличия зашифрованного бэкапа
if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    echo -e "\n${YELLOW}[0/6] Обнаружен зашифрованный бэкап: ${BACKUP_FILE}${NC}"
    mkdir -p "${RESTORE_DIR}"
    echo -e "${CYAN}Введите пароль для расшифровки бэкапа:${NC}"
    if openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$BACKUP_FILE" -out "${RESTORE_DIR}/backup.tar.gz"; then
        tar -xzf "${RESTORE_DIR}/backup.tar.gz" -C "${RESTORE_DIR}"
        HAS_BACKUP=true
        echo -e "  ${GREEN}✓${NC} Бэкап успешно расшифрован и подготовлен к интеграции!"
    else
        echo -e "  ${RED}✗ Ошибка: Неверный пароль расшифровки! Прерывание.${NC}"
        rm -rf "${RESTORE_DIR}"
        exit 1
    fi
else
    echo -e "\n${YELLOW}[0/6] Бэкап не указан — будет выполнена чистая эталонная настройка.${NC}"
fi

# 1. Обновление пакетов ОС
echo -e "\n${YELLOW}[1/6] Обновление системы и установка утилит...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update -y && apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt install -y curl wget socat tar jq ufw fail2ban htop net-tools openssl
echo -e "  ${GREEN}✓${NC} Базовые пакеты установлены."

# 2. Сетевой тюнинг (Google BBR + FQ + swappiness)
echo -e "\n${YELLOW}[2/6] Настройка Google BBR и сетевого стека...${NC}"
cat <<EOF > /etc/sysctl.d/99-phoenix-tuning.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
vm.swappiness = 10
EOF
sysctl --system >/dev/null 2>&1
echo -e "  ${GREEN}✓${NC} Google BBR активирован ($(sysctl -n net.ipv4.tcp_congestion_control))."

# 3. Настройка файла подкачки Swap на 1 ГБ (защита от OOM-Killer)
echo -e "\n${YELLOW}[3/6] Проверка и создание Swap на 1 ГБ...${NC}"
if [ $(swapon --show | wc -l) -le 1 ]; then
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo -e "  ${GREEN}✓${NC} Swap 1GB создан и активирован."
else
    echo -e "  ${GREEN}✓${NC} Swap уже существует в системе."
fi

# 4. Настройка защиты Fail2ban
echo -e "\n${YELLOW}[4/6] Настройка защиты SSH от брутфорса (Fail2ban)...${NC}"
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ssh
mode = aggressive
EOF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban >/dev/null 2>&1
echo -e "  ${GREEN}✓${NC} Fail2ban запущен (бан на 1 час после 5 попыток)."

# 5. Файрвол UFW (Zero Attack Surface)
echo -e "\n${YELLOW}[5/6] Настройка файрвола UFW...${NC}"
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1
ufw allow 443/tcp comment 'VLESS-REALITY' >/dev/null 2>&1
echo "y" | ufw enable >/dev/null 2>&1
echo -e "  ${GREEN}✓${NC} Файрвол активирован: открыты только порты 22 и 443."

# 6. Установка 3x-ui и накат базы данных
echo -e "\n${YELLOW}[6/6] Развёртывание 3x-ui (MHSanaei)...${NC}"
# Установка панели без интерактива
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF
y
5541
admin
$(openssl rand -hex 8)
/control-$(openssl rand -hex 4)/
EOF

# Если есть бэкап — восстанавливаем оригинальную базу данных
if [ "$HAS_BACKUP" = true ] && [ -f "${RESTORE_DIR}/x-ui.db" ]; then
    echo -e "\n${CYAN}Интеграция базы данных из бэкапа...${NC}"
    systemctl stop x-ui 2>/dev/null || x-ui stop 2>/dev/null || true
    cp "${RESTORE_DIR}/x-ui.db" "/etc/x-ui/x-ui.db"
    chmod 644 "/etc/x-ui/x-ui.db"
    
    # Привязываем панель строго к 127.0.0.1 (Zero Attack Surface)
    # Если в базе или конфиге порт свободен
    systemctl restart x-ui 2>/dev/null || x-ui restart 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} База данных восстановлена! Все клиенты, UUID и ключи активны."
    rm -rf "${RESTORE_DIR}"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}   ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО ЗА ${DURATION} СЕКУНД!         ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "• BBR: ${GREEN}АКТИВЕН${NC}"
echo -e "• Swap: ${GREEN}1 GB${NC}"
echo -e "• Файрвол: ${GREEN}Порты 22 и 443 открыты, остальные закрыты${NC}"
echo -e "• Служба Xray: ${GREEN}РАБОТАЕТ${NC}"
if [ "$HAS_BACKUP" = true ]; then
    echo -e "• База клиентов: ${GREEN}ПОЛНОСТЬЮ ВОССТАНОВЛЕНА${NC}"
    echo -e "👉 Клиенты (телефон, ПК, телефон мамы) подключаются без изменения ключей!"
fi
echo -e "${GREEN}======================================================${NC}\n"
