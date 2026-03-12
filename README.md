# ubuntu-init

Интерактивный скрипт базовой настройки безопасности для новых серверов на Ubuntu 22.04+.

## Что делает

- Создаёт именного sudo‑пользователя с SSH‑ключом
- Настраивает SSH (только ключи, запрет паролей, запрет root, белый список `AllowUsers`)
- Устанавливает fail2ban (опционально)
- Включает `noexec` на `/tmp` и `/var/tmp`
- Включает автообновления безопасности (`unattended-upgrades`)

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/1vank1n/ubuntu-init/main/ubuntu-init.sh | sudo bash
```

Скрипт задаст интерактивные вопросы (имя пользователя, SSH‑порт, ключ и т.д.), покажет сводку параметров и попросит подтверждение перед применением.

## Или вручную

```bash
wget https://raw.githubusercontent.com/1vank1n/ubuntu-init/main/ubuntu-init.sh
chmod +x ubuntu-init.sh
sudo ./ubuntu-init.sh
```

## Что спрашивает

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| Имя пользователя | `ops` | sudo‑пользователь для SSH |
| SSH‑порт | `22` | Порт для sshd |
| SSH‑ключ | — | Публичный ключ (ed25519) |
| Fail2ban | да | Защита от перебора |
| UFW | да | Firewall с белым списком портов |
| HTTP/HTTPS | да | Открыть 80/443 в UFW |
| noexec /tmp | да | Запрет исполнения из /tmp |
| Автообновления | да | unattended-upgrades |
| sudo без пароля | нет | NOPASSWD (не рекомендуется) |

## Безопасность

Скрипт рассчитан на работу в паре со статьёй [«Базовые настройки безопасности»](https://docs.il-studio.ru/new-catalog/poleznoe/bazovye-nastroyki-bezopasnosti).

Если вы выбираете sudo без пароля, рекомендуется компенсировать это:

- Passphrase на SSH‑ключе + ssh-agent
- Ограничение по IP в `authorized_keys`: `from="1.2.3.4" ssh-ed25519 ...`

## Лицензия

MIT
