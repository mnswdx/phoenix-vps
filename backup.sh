#!/usr/bin/env bash
# ==============================================================================
# Project Phoenix: Скрипт создания зашифрованного бэкапа сервера (Backup Engine)
# Собирает базу данных 3x-ui (все ключи, UUID клиентов, REALITY параметры),
# настройки sysctl (BBR), fail2ban и файрвола UFW.
# ==============================================================================

set -e

# Цвета для вывода в терминал
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}   PROJECT PHOENIX: СОЗДАНИЕ РЕЗЕРВНОЙ КОПИИ СЕРВЕРА  ${NC}"
echo -e "${CYAN}======================================================${NC}"

# Временная директория для сбора файлов
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/tmp/phoenix_backup_${TIMESTAMP}"
ARCHIVE_NAME="phoenix_backup_${TIMESTAMP}.tar.gz"
ENCRYPTED_NAME="phoenix_backup_${TIMESTAMP}.enc"

mkdir -p "${BACKUP_DIR}"

echo -e "\n${YELLOW}[1/4] Сбор критических конфигураций...${NC}"

# 1. База данных 3x-ui (SQLite со всеми клиентами, ключами REALITY и правилами)
if [ -f "/etc/x-ui/x-ui.db" ]; then
    cp "/etc/x-ui/x-ui.db" "${BACKUP_DIR}/x-ui.db"
    echo -e "  ${GREEN}✓${NC} База данных 3x-ui скопирована (/etc/x-ui/x-ui.db)"
else
    echo -e "  ${RED}✗ Ошибка: База данных /etc/x-ui/x-ui.db не найдена!${NC}"
    exit 1
fi

# 2. Сетевые настройки BBR и подкачки sysctl
if [ -f "/etc/sysctl.conf" ]; then
    cp "/etc/sysctl.conf" "${BACKUP_DIR}/sysctl.conf"
    echo -e "  ${GREEN}✓${NC} Настройки BBR и swappiness скопированы (/etc/sysctl.conf)"
fi

# 3. Настройки Fail2ban
if [ -f "/etc/fail2ban/jail.local" ]; then
    cp "/etc/fail2ban/jail.local" "${BACKUP_DIR}/jail.local"
    echo -e "  ${GREEN}✓${NC} Конфигурация Fail2ban скопирована (/etc/fail2ban/jail.local)"
fi

# 4. Правила UFW
if [ -d "/etc/ufw" ]; then
    mkdir -p "${BACKUP_DIR}/ufw"
    cp -r /etc/ufw/* "${BACKUP_DIR}/ufw/" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Правила файрвола UFW скопированы"
fi

echo -e "\n${YELLOW}[2/4] Упаковка в архив...${NC}"
tar -czf "/tmp/${ARCHIVE_NAME}" -C "${BACKUP_DIR}" .
rm -rf "${BACKUP_DIR}"
echo -e "  ${GREEN}✓${NC} Архив создан: /tmp/${ARCHIVE_NAME} ($(du -h /tmp/${ARCHIVE_NAME} | cut -f1))"

echo -e "\n${YELLOW}[3/4] Шифрование архива алгоритмом AES-256-CBC...${NC}"
echo -e "${CYAN}Придумайте и введите надёжный пароль для шифрования бэкапа:${NC}"

# Шифрование через openssl с PBKDF2 (современный надёжный стандарт)
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "/tmp/${ARCHIVE_NAME}" -out "/root/${ENCRYPTED_NAME}"
rm -f "/tmp/${ARCHIVE_NAME}"

echo -e "\n${YELLOW}[4/4] Завершение...${NC}"
echo -e "${GREEN}✓ Зашифрованный бэкап успешно создан:${NC} /root/${ENCRYPTED_NAME}"
echo -e "\n${CYAN}Чтобы скачать этот бэкап на свой компьютер, выполните в терминале:${NC}"
echo -e "scp root@<IP_СЕРВЕРА>:/root/${ENCRYPTED_NAME} ./"
echo -e "${CYAN}======================================================${NC}\n"
