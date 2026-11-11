#!/usr/bin/env bash
# Run on an Ubuntu/Debian controller: sudo bash setup-amneziawg.sh
# Target: Ubuntu 24.04 amd64. Requires inbound TCP/22, TCP/80, TCP/443, UDP/51820.
# Root and panel passwords stay in memory and pipes (never regular files).
# Only the panel's bcrypt hash is persisted (required for future logins).
set +x
set +v
set +a
set -Eeuo pipefail
umask 077
ulimit -c 0

readonly REPO_URL="https://github.com/Ai0N4/AmneziaWG-Web-Panel.git"
readonly REPO_DIR="${REPO_DIR:-$HOME/AmneziaWG-Web-Panel}"
readonly ANSIBLE_USER=root

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }
clear_secrets() {
  unset ROOT_PASSWORD PANEL_PASSWORD AMNEZIAWG_PANEL_HASH EXISTING_PANEL_HASH
}
trap clear_secrets EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $EUID -eq 0 ]] || die "Запустите скрипт от root: sudo bash $0"
command -v apt >/dev/null 2>&1 || die "Для управляющей машины нужен Debian/Ubuntu с apt"

# Never accept passwords in arguments, environment, inventory or temp files.
unset ROOT_PASSWORD PANEL_PASSWORD
exec 4<>/dev/tty
TARGET_IP="${1:-}"
if [[ -z "$TARGET_IP" ]]; then
  read -r -u 4 -p "IP сервера: " TARGET_IP
fi
[[ "$TARGET_IP" =~ ^[0-9a-fA-F:.]+$ ]] || die "Некорректный IP-адрес"
read -r -s -u 4 -p "Пароль root: " ROOT_PASSWORD
printf '\n' >&4
[[ -n "$ROOT_PASSWORD" ]] || die "Пароль root не должен быть пустым"
read -r -s -u 4 -p "Пароль панели AmneziaWG: " PANEL_PASSWORD
printf '\n' >&4
[[ -n "$PANEL_PASSWORD" ]] || die "Пароль панели не должен быть пустым"
exec 4>&-

log "Установка инструментов управления"
# Unattended upgrades may hold dpkg for several minutes on a fresh VPS.
# Let APT wait for its lock instead of interrupting the other package manager.
apt -o DPkg::Lock::Timeout=1800 update
# sshpass reads the root password from a pipe FD, never from argv or a file.
apt -o DPkg::Lock::Timeout=1800 install -y python3 python3-venv python3-pip git openssh-client sshpass
python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$TARGET_IP"
python3 --version
python3 -c 'import sys; sys.exit("Python 3.12+ required") if sys.version_info < (3, 12) else None'

SSH_OPTIONS=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
  -o NumberOfPasswordPrompts=1
  -o ControlMaster=no
  -o ControlPath=none
  -o LogLevel=ERROR
)
remote() {
  sshpass -d 3 ssh "${SSH_OPTIONS[@]}" "${ANSIBLE_USER}@${TARGET_IP}" "$@" \
    3< <(printf '%s\n' "$ROOT_PASSWORD")
}
run_ansible() (
  # Ansible resolves symlinks before reading --connection-password-file.
  # /dev/fd/N therefore becomes an unusable /proc/.../pipe:[...] path.
  # A FIFO has a stable pathname but carries data only in kernel memory.
  # Its private directory is on tmpfs; no regular file contains the password.
  password_dir="$(mktemp -d /dev/shm/amneziawg-auth.XXXXXX)"
  password_pipe="$password_dir/connection-password"
  password_writer=''
  cleanup_password_pipe() {
    # Only signal a still-running shell job, never a potentially reused PID.
    for active_job in $(jobs -pr); do
      if [[ "$active_job" == "$password_writer" ]]; then
        kill "$active_job" 2>/dev/null || true
      fi
    done
    if [[ -n "$password_writer" ]]; then
      wait "$password_writer" 2>/dev/null || true
    fi
    rm -f -- "$password_pipe"
    rmdir -- "$password_dir"
  }
  trap cleanup_password_pipe EXIT
  mkfifo -m 600 "$password_pipe"
  (
    trap - EXIT INT TERM
    printf '%s\n' "$ROOT_PASSWORD" >"$password_pipe"
  ) &
  password_writer=$!
  ANSIBLE_SSH_PASSWORD_MECHANISM=sshpass "$@" \
    --connection-password-file "$password_pipe"
)

log "Проверка SSH"
remote true
if [[ -e "$REPO_DIR" && ! -d "$REPO_DIR/.git" ]]; then
  die "$REPO_DIR существует, но это не Git-репозиторий"
fi
if [[ ! -d "$REPO_DIR/.git" ]]; then
  git clone "$REPO_URL" "$REPO_DIR"
elif git -C "$REPO_DIR" diff --quiet && git -C "$REPO_DIR" diff --cached --quiet; then
  git -C "$REPO_DIR" pull --ff-only
else
  log "Используется существующая копия проекта с локальными настройками"
fi
cd "$REPO_DIR"
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
.venv/bin/pip install 'bcrypt>=4,<6'
.venv/bin/ansible-galaxy collection install -r requirements.yml
.venv/bin/ansible --version

# Disable file logging and persistent facts. Secret tasks also use no_log.
export ANSIBLE_LOG_PATH=/dev/null
export ANSIBLE_CACHE_PLUGIN=memory
export ANSIBLE_DISPLAY_ARGS_TO_STDOUT=false
export ANSIBLE_SSH_ARGS="-o StrictHostKeyChecking=accept-new -o ControlMaster=no -o ControlPath=none"

log "Создание bcrypt-хеша пароля панели"
# Reuse the existing hash for the same password to avoid container restarts.
# Neither the password nor the hash is printed.
EXISTING_PANEL_HASH="$(remote 'if [ -f /opt/amneziawg/password.hash ]; then cat /opt/amneziawg/password.hash; fi')"
AMNEZIAWG_PANEL_HASH="$(
  printf '%s\0%s' "$PANEL_PASSWORD" "$EXISTING_PANEL_HASH" |
    .venv/bin/python -c '
import bcrypt
import sys

password, previous = sys.stdin.buffer.read().split(b"\0", 1)
if not 8 <= len(password) <= 72:
    raise SystemExit("Пароль панели должен занимать от 8 до 72 байт UTF-8")
previous = previous.strip()
try:
    unchanged = bcrypt.checkpw(password, previous)
except ValueError:
    unchanged = False
result = previous if unchanged else bcrypt.hashpw(password, bcrypt.gensalt(12))
sys.stdout.buffer.write(result)
'
)"
export AMNEZIAWG_PANEL_HASH
unset EXISTING_PANEL_HASH

log "Создание приватного inventory"
cp inventory.example.yml inventory.local.yml
chmod 600 inventory.local.yml
TARGET_IP="$TARGET_IP" .venv/bin/python - <<'PYINVENTORY'
from pathlib import Path
import os
import yaml

path = Path("inventory.local.yml")
inventory = yaml.safe_load(path.read_text(encoding="utf-8"))

def find_vpn(node):
    if not isinstance(node, dict):
        return None
    if isinstance(node.get("vpn"), dict) and "hosts" in node["vpn"]:
        return node["vpn"]
    for value in node.values():
        found = find_vpn(value)
        if found is not None:
            return found
    return None

vpn = find_vpn(inventory)
if vpn is None or not vpn["hosts"]:
    raise SystemExit("В inventory.example.yml не найдена группа vpn с хостом")
hosts = vpn["hosts"]
if len(hosts) != 1:
    raise SystemExit("Шаблон должен содержать ровно один хост vpn")
alias = next(iter(hosts))
settings = hosts[alias] or {}
settings.update(
    ansible_host=os.environ["TARGET_IP"],
    ansible_user="root",
    amneziawg_host=os.environ["TARGET_IP"],
    amneziawg_ui_public=True,
    amneziawg_nginx_port=443,
    amneziawg_nginx_tls_enabled=True,
)
for key in ("ansible_password", "ansible_ssh_pass", "ansible_become_password"):
    settings.pop(key, None)
vpn["hosts"] = {alias: settings}
path.write_text(yaml.safe_dump(inventory, sort_keys=False), encoding="utf-8")
PYINVENTORY

log "Настройка роли: только аутентификация панели, хранение только хеша"
.venv/bin/python - <<'PYPATCH'
from pathlib import Path
import re
import yaml

role = Path("roles/amneziawg")

class AnsibleDumper(yaml.SafeDumper):
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)

# Apply to every apt task in the play, including install.yml and nginx.yml.
# The module default is only 60 seconds, which loses races with unattended-upgrades.
playbook_path = Path("playbook.yml")
plays = yaml.safe_load(playbook_path.read_text(encoding="utf-8"))
for play in plays:
    if "amneziawg" in play.get("roles", []):
        apt_defaults = play.setdefault("module_defaults", {}).setdefault("ansible.builtin.apt", {})
        apt_defaults["lock_timeout"] = 1800
playbook_path.write_text(yaml.dump(plays, Dumper=AnsibleDumper, sort_keys=False, width=120), encoding="utf-8")

configure = role / "tasks/configure.yml"
tasks = yaml.safe_load(configure.read_text(encoding="utf-8"))
credential_names = {
    "Generate panel credentials once on the server",
    "Install user-provided panel password hash",
    "Remove legacy plaintext panel password",
    "Install panel authentication verifier",
}
indices = [i for i, task in enumerate(tasks) if task.get("name") in credential_names]
if not indices:
    raise SystemExit("configure.yml: не найдена задача настройки пароля")
position = min(indices)
tasks = [task for task in tasks if task.get("name") not in credential_names]
tasks[position:position] = [
    {
        "name": "Install user-provided panel password hash",
        "ansible.builtin.copy": {
            "content": "{{ lookup('ansible.builtin.env', 'AMNEZIAWG_PANEL_HASH', default=undef()) }}\n",
            "dest": "{{ amneziawg_directory }}/password.hash",
            "owner": "root", "group": "root", "mode": "0600",
        },
        "no_log": True,
    },
    {
        "name": "Remove legacy plaintext panel password",
        "ansible.builtin.file": {
            "path": "{{ amneziawg_directory }}/password.txt", "state": "absent",
        },
        "no_log": True,
    },
    {
        "name": "Install panel authentication verifier",
        "ansible.builtin.copy": {
            "src": "verify-login.py",
            "dest": "/usr/local/sbin/amneziawg-verify-panel.py",
            "owner": "root", "group": "root", "mode": "0700",
        },
    },
]
configure.write_text(yaml.dump(tasks, Dumper=AnsibleDumper, sort_keys=False, width=120), encoding="utf-8")

nginx_tasks = role / "tasks/nginx.yml"
task_text = nginx_tasks.read_text(encoding="utf-8")
marker = "    # setup-amneziawg: persistent nginx basic-auth compatibility\n"
if marker in task_text:
    start = task_text.index(marker)
    end = task_text.find("    - name: Install validated isolated nginx configuration\n", start)
    if end < 0:
        raise SystemExit("nginx.yml: не найден конец старого блока Basic Auth")
    task_text = task_text[:start] + task_text[end:]
nginx = yaml.safe_load(task_text)
for task in nginx:
    for entry in task.get("block", []):
        command = entry.get("ansible.builtin.command")
        if isinstance(command, dict) and "proxy" in command.get("argv", []):
            command["argv"] = ["direct" if arg == "proxy" else arg for arg in command["argv"]]
        if entry.get("name") == "Verify both authentication layers through nginx":
            entry["name"] = "Verify panel authentication through nginx"
nginx_tasks.write_text(yaml.dump(nginx, Dumper=AnsibleDumper, sort_keys=False, width=120), encoding="utf-8")

template = role / "templates/nginx.conf.j2"
text = template.read_text(encoding="utf-8")
text = re.sub(r"(?m)^[ \t]*auth_basic(?:_user_file)?[ \t]+.*\n?", "", text)
template.write_text(text, encoding="utf-8")

# The original verifier reads password.txt. This replacement checks protection
# without a password during Ansible; the final real-login check uses SSH stdin.
(role / "files/verify-login.py").write_text('''"""Verify panel authentication without persisting or printing credentials."""
import http.client
from http.cookies import SimpleCookie
import json
from pathlib import Path
import re
import secrets
import socket
import ssl
import sys

directory = Path(sys.argv[1])
port = int(sys.argv[2])
scheme = sys.argv[3] if len(sys.argv) > 3 else "http"
with_password = len(sys.argv) > 6 and sys.argv[6] == "--stdin-password"
tls_name = sys.argv[7] if with_password else "127.0.0.1"
context = None
if scheme == "https":
    context = (ssl.create_default_context() if with_password else
               ssl.create_default_context(cafile=str(directory / "tls/cert.pem")))

def request(method, path, payload=None, cookie=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    if context is not None:
        connection.sock = context.wrap_socket(
            socket.create_connection(("127.0.0.1", port), timeout=15),
            server_hostname=tls_name,
        )
    headers = {"Content-Type": "application/json"}
    if cookie:
        headers["Cookie"] = cookie
    body = json.dumps(payload).encode() if payload is not None else None
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        status, response_headers = response.status, dict(response.getheaders())
        data = response.read()
        return status, response_headers, data
    finally:
        connection.close()

def json_body(data):
    return json.loads(data)

assert not (directory / "password.txt").exists(), "Plaintext password file must not exist"
stored_hash = (directory / "password.hash").read_bytes().strip()
assert re.fullmatch(rb"\\$2[aby]\\$\\d{2}\\$[./A-Za-z0-9]{53}", stored_hash), "Invalid bcrypt hash"
status, headers, data = request("GET", "/api/session")
assert status == 200 and "WWW-Authenticate" not in headers, "Basic Auth must be disabled"
session = json_body(data)
assert session["requiresPassword"] and not session["authenticated"], "Panel must require a password"
status, _, _ = request("GET", "/api/wireguard/client")
assert status == 401, "Client API must require panel authentication"
status, _, _ = request("POST", "/api/session", {"password": secrets.token_urlsafe(32)})
assert status == 401, "Invalid panel password must be rejected"

if with_password:
    password = sys.stdin.buffer.read().decode("utf-8")
    assert password, "No password on stdin"
    status, headers, data = request("POST", "/api/session", {"password": password})
    del password
    assert status == 200 and json_body(data).get("success") is True, "Panel login failed"
    cookies = SimpleCookie()
    cookies.load(headers.get("Set-Cookie", ""))
    assert cookies, "Session cookie missing"
    if scheme == "https":
        assert all(cookie["secure"] for cookie in cookies.values()), "Session cookie must be Secure"
    cookie_header = "; ".join(f"{item.key}={item.value}" for item in cookies.values())
    status, _, data = request("GET", "/api/session", cookie=cookie_header)
    assert status == 200 and json_body(data)["authenticated"], "Authenticated session failed"
    status, _, data = request("GET", "/api/wireguard/client", cookie=cookie_header)
    assert status == 200 and isinstance(json_body(data), list), "Authenticated client API failed"
    print("Real panel login and authenticated client API verified; no plaintext password file")
else:
    print("Panel authentication required; Basic Auth disabled; only bcrypt hash persisted")
''', encoding="utf-8")
PYPATCH

log "Проверка Ansible и проекта"
run_ansible .venv/bin/ansible -i inventory.local.yml vpn -m ansible.builtin.ping
.venv/bin/ansible-lint
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/ansible-playbook playbook.yml --syntax-check
run_ansible .venv/bin/ansible-playbook -i inventory.local.yml playbook.yml --check --diff

log "Развёртывание AmneziaWG и панели"
run_ansible .venv/bin/ansible-playbook -i inventory.local.yml playbook.yml
unset AMNEZIAWG_PANEL_HASH

log "Let's Encrypt для IP-адреса и автоматическое продление"
remote bash -s -- "$TARGET_IP" <<'REMOTE'
set -Eeuo pipefail
umask 077
TARGET_IP="$1"
python3 -m venv /opt/amneziawg-certbot
/opt/amneziawg-certbot/bin/python -m pip install --upgrade pip
/opt/amneziawg-certbot/bin/pip install --upgrade 'certbot>=5.4'
CERTBOT=/opt/amneziawg-certbot/bin/certbot

# HTTP-01 needs TCP/80. Leave HTTPS/443 running while obtaining certificates.
add_http_rule() {
  iptables-nft -w -C INPUT -p tcp --dport 80 -m comment --comment amneziawg-certbot -j ACCEPT 2>/dev/null ||
    iptables-nft -w -I INPUT -p tcp --dport 80 -m comment --comment amneziawg-certbot -j ACCEPT
}
del_http_rule() {
  iptables-nft -w -D INPUT -p tcp --dport 80 -m comment --comment amneziawg-certbot -j ACCEPT 2>/dev/null || true
}
trap del_http_rule EXIT
add_http_rule
"$CERTBOT" certonly --non-interactive --agree-tos --register-unsafely-without-email \
  --preferred-profile shortlived --preferred-challenges http-01 \
  --standalone --ip-address "$TARGET_IP" --http-01-port 80 \
  --cert-name amneziawg-ip

install -d -m 0700 /opt/amneziawg/letsencrypt
install -m 0644 /etc/letsencrypt/live/amneziawg-ip/fullchain.pem /opt/amneziawg/letsencrypt/fullchain.pem
install -m 0600 /etc/letsencrypt/live/amneziawg-ip/privkey.pem /opt/amneziawg/letsencrypt/privkey.pem
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/amneziawg-panel.sh <<'HOOK'
#!/bin/sh
set -eu
install -m 0644 /etc/letsencrypt/live/amneziawg-ip/fullchain.pem /opt/amneziawg/letsencrypt/fullchain.pem
install -m 0600 /etc/letsencrypt/live/amneziawg-ip/privkey.pem /opt/amneziawg/letsencrypt/privkey.pem
/usr/sbin/nginx -t -c /etc/amneziawg-nginx/nginx.conf
if systemctl is-active --quiet amneziawg-proxy; then
  systemctl reload amneziawg-proxy
fi
HOOK
chmod 0750 /etc/letsencrypt/renewal-hooks/deploy/amneziawg-panel.sh

sed -i \
  -e '/^[[:space:]]*auth_basic[[:space:]]/d' \
  -e '/^[[:space:]]*auth_basic_user_file[[:space:]]/d' \
  -e 's#ssl_certificate\s\+[^;]*;#ssl_certificate /opt/amneziawg/letsencrypt/fullchain.pem;#' \
  -e 's#ssl_certificate_key\s\+[^;]*;#ssl_certificate_key /opt/amneziawg/letsencrypt/privkey.pem;#' \
  /etc/amneziawg-nginx/nginx.conf
rm -f /etc/amneziawg-nginx/htpasswd /opt/amneziawg/nginx-password.txt /opt/amneziawg/nginx-username.txt
rm -f /etc/cron.d/amneziawg-certificate
cat >/usr/local/sbin/amneziawg-certbot-renew <<'RENEW'
#!/bin/sh
set -eu
exec 9>/run/amneziawg-certbot-renew.lock
flock -n 9 || exit 0
remove_rule() {
  iptables-nft -w -D INPUT -p tcp --dport 80 -m comment --comment amneziawg-certbot -j ACCEPT 2>/dev/null || true
}
trap remove_rule EXIT
iptables-nft -w -C INPUT -p tcp --dport 80 -m comment --comment amneziawg-certbot -j ACCEPT 2>/dev/null ||
  iptables-nft -w -I INPUT -p tcp --dport 80 -m comment --comment amneziawg-certbot -j ACCEPT
/opt/amneziawg-certbot/bin/certbot renew --non-interactive --cert-name amneziawg-ip
RENEW
chmod 0750 /usr/local/sbin/amneziawg-certbot-renew
cat >/etc/systemd/system/amneziawg-certbot-renew.service <<'UNIT'
[Unit]
Description=Renew AmneziaWG Let's Encrypt certificate

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/amneziawg-certbot-renew
UNIT
cat >/etc/systemd/system/amneziawg-certbot-renew.timer <<'UNIT'
[Unit]
Description=Twice-daily AmneziaWG Let's Encrypt renewal

[Timer]
OnCalendar=*-*-* 03,15:17:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now amneziawg-certbot-renew.timer
nginx -t -c /etc/amneziawg-nginx/nginx.conf
systemctl reload amneziawg-proxy
test ! -e /opt/amneziawg/password.txt
REMOTE

log "Проверка входа с указанным паролем (через SSH stdin)"
printf '%s' "$PANEL_PASSWORD" |
  remote "python3 /usr/local/sbin/amneziawg-verify-panel.py /opt/amneziawg 443 https direct 51820 --stdin-password $TARGET_IP"
unset PANEL_PASSWORD
remote 'systemctl is-active docker amneziawg-firewall amneziawg-proxy amneziawg-certbot-renew.timer && awg show wg0 listen-port'
unset ROOT_PASSWORD
printf '\nГотово. Панель: https://%s/\n' "$TARGET_IP"
printf 'Используйте введённый пароль панели. Открытый пароль нигде не сохраняется; хранится только bcrypt-хеш.\n'
