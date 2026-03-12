#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Базовая настройка безопасности Linux‑сервера
# Скрипт для первичной конфигурации нового сервера (Ubuntu 22.04+)
#
# Что делает:
#   - Создаёт именного sudo‑пользователя с SSH‑ключом
#   - Настраивает SSH (ключи, запрет паролей, запрет root)
#   - Устанавливает и настраивает fail2ban (опционально)
#   - Настраивает UFW firewall (опционально)
#   - Включает noexec на /tmp и /var/tmp
#   - Включает unattended-upgrades
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/1vank1n/ubuntu-init/main/ubuntu-init.sh | sudo bash
#   # или
#   chmod +x ubuntu-init.sh
#   sudo ./ubuntu-init.sh
# ============================================================================

# --- Если запущен через pipe, скачиваем во временный файл и перезапускаем ---

if [[ ! -t 0 ]]; then
    TMPSCRIPT=$(mktemp /tmp/ubuntu-init.XXXXXX.sh)
    cat > "$TMPSCRIPT"
    chmod +x "$TMPSCRIPT"
    exec bash "$TMPSCRIPT" < /dev/tty
fi

# --- Цвета и утилиты --------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

ask() {
    local prompt="$1" default="$2" reply
    read -rp "$(echo -e "${CYAN}$prompt${NC} [$default]: ")" reply
    echo "${reply:-$default}"
}

ask_yes_no() {
    local prompt="$1" default="$2" reply
    read -rp "$(echo -e "${CYAN}$prompt${NC} [$default]: ")" reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# --- Проверки ----------------------------------------------------------------

[[ $EUID -ne 0 ]] && error "Запустите скрипт от root: sudo ./ubuntu-init.sh"

if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    warn "Скрипт рассчитан на Ubuntu/Debian. На другой ОС могут быть проблемы."
    ask_yes_no "Продолжить?" "n" || exit 0
fi

# --- Сбор параметров --------------------------------------------------------

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Настройка безопасности сервера${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

USERNAME=$(ask "Имя sudo‑пользователя (ваше имя или ops)" "ops")
SSH_PORT=$(ask "SSH‑порт" "22")
SSH_PUBLIC_KEY=$(ask "Публичный SSH‑ключ (вставьте целиком, или пустая строка — пропустить)" "")

echo ""
INSTALL_FAIL2BAN=$(ask_yes_no "Установить fail2ban?" "y" && echo "y" || echo "n")
INSTALL_UFW=$(ask_yes_no "Настроить UFW firewall?" "y" && echo "y" || echo "n")

if [[ "$INSTALL_UFW" == "y" ]]; then
    OPEN_HTTP=$(ask_yes_no "Открыть порт 80 (HTTP)?" "y" && echo "y" || echo "n")
    OPEN_HTTPS=$(ask_yes_no "Открыть порт 443 (HTTPS)?" "y" && echo "y" || echo "n")
fi

SETUP_TMP_NOEXEC=$(ask_yes_no "Включить noexec на /tmp и /var/tmp?" "y" && echo "y" || echo "n")
SETUP_UNATTENDED=$(ask_yes_no "Включить автообновления безопасности?" "y" && echo "y" || echo "n")

echo ""
warn "Следующая опция снижает безопасность. Если SSH‑ключ будет скомпрометирован,"
warn "атакующий получит root без дополнительных барьеров."
NOPASSWD_SUDO=$(ask_yes_no "Разрешить sudo без пароля? (не рекомендуется)" "n" && echo "y" || echo "n")

# --- Подтверждение -----------------------------------------------------------

echo ""
echo -e "${YELLOW}=== Параметры ===${NC}"
echo "  Пользователь:        $USERNAME"
echo "  SSH‑порт:            $SSH_PORT"
echo "  SSH‑ключ:            ${SSH_PUBLIC_KEY:+задан}${SSH_PUBLIC_KEY:-не задан}"
echo "  Fail2ban:            $INSTALL_FAIL2BAN"
echo "  UFW:                 $INSTALL_UFW"
[[ "$INSTALL_UFW" == "y" ]] && echo "  HTTP (80):           $OPEN_HTTP"
[[ "$INSTALL_UFW" == "y" ]] && echo "  HTTPS (443):         $OPEN_HTTPS"
echo "  noexec /tmp:         $SETUP_TMP_NOEXEC"
echo "  Автообновления:      $SETUP_UNATTENDED"
echo "  sudo без пароля:     $NOPASSWD_SUDO"
echo ""

ask_yes_no "Всё верно? Начинаем?" "y" || { info "Отменено."; exit 0; }

echo ""

# --- 1. Пользователь --------------------------------------------------------

info "Создание пользователя $USERNAME..."

if id "$USERNAME" &>/dev/null; then
    warn "Пользователь $USERNAME уже существует — пропускаю создание."
else
    adduser --disabled-password --gecos "" "$USERNAME"
    success "Пользователь $USERNAME создан."
fi

usermod -aG sudo "$USERNAME"
success "$USERNAME добавлен в группу sudo."

if [[ "$NOPASSWD_SUDO" == "y" ]]; then
    echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USERNAME}"
    chmod 440 "/etc/sudoers.d/${USERNAME}"
    success "sudo без пароля включён для $USERNAME."
    warn "Помните: при компрометации SSH‑ключа атакующий сразу получает root."
else
    # Пароль для sudo (не для SSH — SSH работает только по ключу)
    info "Задайте пароль для $USERNAME (используется только для sudo):"
    passwd "$USERNAME"
    success "Пароль установлен."
fi

# SSH‑ключ
if [[ -n "$SSH_PUBLIC_KEY" ]]; then
    USER_HOME=$(eval echo "~$USERNAME")
    SSH_DIR="$USER_HOME/.ssh"
    AUTH_KEYS="$SSH_DIR/authorized_keys"

    mkdir -p "$SSH_DIR"

    # Добавляем ключ, если его ещё нет
    if [[ -f "$AUTH_KEYS" ]] && grep -qF "$SSH_PUBLIC_KEY" "$AUTH_KEYS"; then
        warn "SSH‑ключ уже присутствует в $AUTH_KEYS."
    else
        echo "$SSH_PUBLIC_KEY" >> "$AUTH_KEYS"
        success "SSH‑ключ добавлен."
    fi

    chmod 700 "$SSH_DIR"
    chmod 600 "$AUTH_KEYS"
    chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
fi

# --- 2. SSH -----------------------------------------------------------------

info "Настройка SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%s)"
cp "$SSHD_CONFIG" "$SSHD_BACKUP"
success "Бэкап sshd_config → $SSHD_BACKUP"

# Функция: установить параметр в sshd_config
set_sshd_param() {
    local key="$1" value="$2"
    if grep -qE "^\s*#?\s*${key}\b" "$SSHD_CONFIG"; then
        sed -i "s|^\s*#\?\s*${key}\b.*|${key} ${value}|" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

set_sshd_param "Port"                          "$SSH_PORT"
set_sshd_param "PermitRootLogin"               "no"
set_sshd_param "PasswordAuthentication"        "no"
set_sshd_param "PermitEmptyPasswords"          "no"
set_sshd_param "KbdInteractiveAuthentication"  "no"
set_sshd_param "UsePAM"                        "yes"

# AllowUsers — белый список
if grep -qE "^\s*AllowUsers\b" "$SSHD_CONFIG"; then
    # Если AllowUsers уже есть — добавляем пользователя, если его там нет
    if ! grep -qE "^\s*AllowUsers\b.*\b${USERNAME}\b" "$SSHD_CONFIG"; then
        sed -i "s|^\(\s*AllowUsers\b.*\)|\1 ${USERNAME}|" "$SSHD_CONFIG"
    fi
else
    echo "AllowUsers ${USERNAME}" >> "$SSHD_CONFIG"
fi

# Проверяем конфиг перед перезапуском
if sshd -t 2>/dev/null; then
    systemctl restart ssh
    success "SSH настроен и перезапущен (порт $SSH_PORT)."
else
    error "Ошибка в sshd_config! Восстановите из бэкапа: $SSHD_BACKUP"
fi

# --- 3. Fail2ban -------------------------------------------------------------

if [[ "$INSTALL_FAIL2BAN" == "y" ]]; then
    info "Установка fail2ban..."
    apt-get update -qq
    apt-get install -y -qq fail2ban

    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
bantime  = 1h
maxretry = 3
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    success "Fail2ban установлен и настроен."
fi

# --- 4. UFW ------------------------------------------------------------------

if [[ "$INSTALL_UFW" == "y" ]]; then
    info "Настройка UFW..."
    apt-get install -y -qq ufw

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment "SSH"

    [[ "$OPEN_HTTP" == "y" ]]  && ufw allow 80/tcp comment "HTTP"
    [[ "$OPEN_HTTPS" == "y" ]] && ufw allow 443/tcp comment "HTTPS"

    # Включаем без интерактивного подтверждения
    ufw --force enable
    success "UFW настроен и включён."
    ufw status verbose
fi

# --- 5. noexec на /tmp -------------------------------------------------------

if [[ "$SETUP_TMP_NOEXEC" == "y" ]]; then
    info "Настройка noexec на /tmp и /var/tmp..."

    add_fstab_entry() {
        local mountpoint="$1"
        if grep -qE "\s${mountpoint}\s" /etc/fstab; then
            warn "$mountpoint уже есть в fstab — пропускаю."
        else
            echo "tmpfs ${mountpoint} tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
            mount -o remount "$mountpoint" 2>/dev/null || mount "$mountpoint" 2>/dev/null || true
            success "${mountpoint} — noexec включён."
        fi
    }

    add_fstab_entry "/tmp"
    add_fstab_entry "/var/tmp"
fi

# --- 6. Автообновления -------------------------------------------------------

if [[ "$SETUP_UNATTENDED" == "y" ]]; then
    info "Настройка автообновлений безопасности..."
    apt-get install -y -qq unattended-upgrades

    # Включаем автообновления (неинтерактивно)
    echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades

    success "Unattended‑upgrades включены."
fi

# --- Готово ------------------------------------------------------------------

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Настройка завершена${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  Пользователь:  ${CYAN}${USERNAME}${NC} (sudo)"
echo -e "  SSH‑порт:      ${CYAN}${SSH_PORT}${NC}"
echo ""
echo -e "${YELLOW}ВАЖНО: Прежде чем закрывать текущую сессию,${NC}"
echo -e "${YELLOW}откройте новый терминал и проверьте вход:${NC}"
echo ""
echo -e "  ${CYAN}ssh -p ${SSH_PORT} ${USERNAME}@$(hostname -I | awk '{print $1}')${NC}"
echo ""
echo -e "Бэкап sshd_config: ${SSHD_BACKUP}"
echo ""
