#!/usr/bin/env bash
# wg_lab.sh — автоматизация WireGuard VPN lab (сервер/клиент)
# Использование:
#   sudo bash wg_lab.sh server [LISTEN_PORT]
#   sudo bash wg_lab.sh client <SERVER_ENDPOINT_IP[:PORT]>
#
# Примеры:
#   sudo bash wg_lab.sh server 51820
#   sudo bash wg_lab.sh client 192.168.56.10:51820
#
set -euo pipefail

ROLE="${1:-}"
ARG2="${2:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash wg_lab.sh <server|client> ..."
  exit 1
fi

if [[ -z "${ROLE}" ]]; then
  echo "Использование:"
  echo "  sudo bash wg_lab.sh server [LISTEN_PORT]"
  echo "  sudo bash wg_lab.sh client <SERVER_ENDPOINT_IP[:PORT]>"
  exit 1
fi

install_wireguard() {
  if ! command -v wg >/dev/null 2>&1; then
    apt update
    apt install -y wireguard
  fi
}

prepare_dir() {
  mkdir -p /etc/wireguard
  chmod 700 /etc/wireguard
  cd /etc/wireguard
}

gen_keys_server() {
  umask 077
  if [[ ! -f server_private.key ]]; then
    wg genkey > server_private.key
    chmod 600 server_private.key
    wg pubkey < server_private.key > server_public.key
  fi
}

gen_keys_client() {
  umask 077
  if [[ ! -f client_private.key ]]; then
    wg genkey > client_private.key
    chmod 600 client_private.key
    wg pubkey < client_private.key > client_public.key
  fi
}

enable_autostart_and_up() {
  local ifname="$1"
  systemctl enable "wg-quick@${ifname}" >/dev/null 2>&1 || true
  wg-quick down "${ifname}" >/dev/null 2>&1 || true
  wg-quick up "${ifname}"
}

allow_ufw_udp() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    # и на русском, и на английском статус
    local status
    status="$(ufw status || true)"
    if echo "$status" | grep -qiE "Status: active|Состояние: активен"; then
      ufw allow "${port}"/udp || true
      ufw reload || true
    fi
  fi
}

case "$ROLE" in
  server)
    LISTEN_PORT="${ARG2:-51820}"
    install_wireguard
    prepare_dir
    gen_keys_server

    SERVER_PRIV="$(cat server_private.key)"
    SERVER_PUB="$(cat server_public.key)"

    echo "SERVER PUBLIC KEY: ${SERVER_PUB}"
    read -r -p "Вставь PUBLIC KEY клиента (или Enter, чтобы пока пропустить): " CLIENT_PUB || true
    CLIENT_PUB="${CLIENT_PUB:-PLACEHOLDER_CLIENT_PUB}"

    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24
PrivateKey = ${SERVER_PRIV}
ListenPort = ${LISTEN_PORT}

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = 10.0.0.2/32
EOF

    chmod 600 /etc/wireguard/wg0.conf

    allow_ufw_udp "${LISTEN_PORT}"

    if [[ "${CLIENT_PUB}" != "PLACEHOLDER_CLIENT_PUB" ]]; then
      enable_autostart_and_up wg0
      echo "Готово. Состояние:"
      wg show
    else
      echo "⚠️ В конфиг записан плейсхолдер клиента. Когда будет ключ, выполни:"
      echo "  sudo sed -i 's|PublicKey = PLACEHOLDER_CLIENT_PUB|PublicKey = <CLIENT_PUBLIC>|' /etc/wireguard/wg0.conf"
      echo "  sudo wg-quick up wg0"
    fi
    ;;
  client)
    if [[ -z "${ARG2}" ]]; then
      echo "Укажи адрес сервера: sudo bash wg_lab.sh client <SERVER_IP[:PORT]>"
      exit 1
    fi
    ENDPOINT="${ARG2}"
    if [[ "${ENDPOINT}" != *:* ]]; then
      ENDPOINT="${ENDPOINT}:51820"
    fi

    install_wireguard
    prepare_dir
    gen_keys_client

    CLIENT_PRIV="$(cat client_private.key)"
    CLIENT_PUB="$(cat client_public.key)"

    echo "CLIENT PUBLIC KEY: ${CLIENT_PUB}"
    read -r -p "Вставь PUBLIC KEY сервера (или Enter, чтобы пока пропустить): " SERVER_PUB || true
    SERVER_PUB="${SERVER_PUB:-PLACEHOLDER_SERVER_PUB}"

    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.2/24
PrivateKey = ${CLIENT_PRIV}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${ENDPOINT}
AllowedIPs = 10.0.0.1/32
PersistentKeepalive = 15
EOF

    chmod 600 /etc/wireguard/wg0.conf

    if [[ "${SERVER_PUB}" != "PLACEHOLDER_SERVER_PUB" ]]; then
      enable_autostart_and_up wg0
      echo "Готово. Состояние:"
      wg show
    else
      echo "⚠️ В конфиг записан плейсхолдер сервера. Когда будет ключ, выполни:"
      echo "  sudo sed -i 's|PublicKey = PLACEHOLDER_SERVER_PUB|PublicKey = <SERVER_PUBLIC>|' /etc/wireguard/wg0.conf"
      echo "  sudo wg-quick up wg0"
    fi

    ;;
  *)
    echo "Неизвестная роль: ${ROLE}. Используй server или client."
    exit 1
    ;;
esac

echo
echo "Подсказки:"
echo "  На сервере: cat /etc/wireguard/server_public.key"
echo "  На клиенте: cat /etc/wireguard/client_public.key"
echo "  Журнал: sudo journalctl -u wg-quick@wg0 -n 100 --no-pager"
