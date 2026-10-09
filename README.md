# Развёртывание AmneziaWG Web Panel

Краткая инструкция по развёртыванию AmneziaWG VPN через Ansible. Команды выполняются на управляющей машине с Ubuntu 24.04, которая имеет SSH-доступ к VPN-серверу.

Перед началом подготовьте VPS-сервер с Ubuntu 24.04 amd64, публичным IP-адресом и доступом по SSH под `root`. Для VPN откройте выбранный UDP-порт (по умолчанию — `51820`), а для публичной веб-панели — TCP-порт `443`.

## 1. Подготовить управляющую машину

```bash
apt update
apt install -y python3 python3-venv python3-pip git openssh-client

git clone https://github.com/Ai0N4/AmneziaWG-Web-Panel.git
cd AmneziaWG-Web-Panel
python3 --version
python3 -m venv .venv
```

## 2. Установить зависимости

```bash
.venv/bin/python -m pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
.venv/bin/ansible-galaxy collection install -r requirements.yml
.venv/bin/ansible --version
```

## 3. Создать и настроить inventory

Сначала создайте приватный inventory из шаблона, затем откройте его для редактирования:

```bash
cp inventory.example.yml inventory.local.yml
chmod 600 inventory.local.yml
nano inventory.local.yml
```

В `inventory.local.yml` замените `vpn-server.example` на публичный IP-адрес или DNS-имя вашего сервера. При необходимости измените `amneziawg_port`; этот UDP-порт должен быть разрешён в firewall сервера и у провайдера.

```yaml
all:
  children:
    vpn:
      hosts:
        amnezia:
          ansible_host: <IP_ИЛИ_DNS_СЕРВЕРА>
          ansible_user: root
          amneziawg_port: 51820
          amneziawg_ui_public: true
          amneziawg_nginx_port: 443
          amneziawg_nginx_tls_enabled: true
```

## 4. Проверить подключение и конфигурацию

Замените `<IP_ИЛИ_DNS_СЕРВЕРА>` на адрес из inventory. Ключ `-k` запрашивает пароль SSH.

```bash
ssh root@<IP_ИЛИ_DNS_СЕРВЕРА> true
.venv/bin/ansible -i inventory.local.yml vpn -m ansible.builtin.ping -k
.venv/bin/ansible-lint
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/ansible-playbook playbook.yml --syntax-check
.venv/bin/ansible-playbook -i inventory.local.yml playbook.yml --check --diff -k
```

Если все проверки прошли, выполните развёртывание:

```bash
.venv/bin/ansible-playbook \
  -i inventory.local.yml \
  playbook.yml \
  -k
```

## 5. Открыть веб-панель

Получите учётные данные веб-панели с сервера:

```bash
ssh root@<IP_ИЛИ_DNS_СЕРВЕРА> 'cat /opt/amneziawg/nginx-username.txt /opt/amneziawg/nginx-password.txt'
ssh root@<IP_ИЛИ_DNS_СЕРВЕРА> 'cat /opt/amneziawg/password.txt'
```

Откройте `https://<IP_ИЛИ_DNS_СЕРВЕРА>`. Введите пароль панели. Если браузер предупредит о сертификате, проверьте отпечаток сертификата на сервере перед продолжением.

## Важно

- `inventory.local.yml` содержит данные конкретного сервера: не добавляйте его в Git.
- При авторизации по SSH-ключу укажите ключ в inventory или SSH-agent и уберите `-k` из команд.
- `--check --diff` не вносит изменений; последняя команда запускает настоящее развёртывание.
