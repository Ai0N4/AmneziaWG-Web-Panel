# AmneziaWG с Ansible

Устанавливает AmneziaWG и веб-панель amnezia-wg-easy на `root@vpn-server.example`.
Замените `vpn-server.example` в командах на ваш SSH-алиас или адрес сервера;
адрес развёртывания указывается только в игнорируемом Git файле `inventory.local.yml`.
Поддерживаемая целевая система: Ubuntu 24.04 amd64 с systemd и заголовочными файлами для используемого
ядра. Роль намеренно отклоняет другие платформы до их проверки.

Основано на [руководстве Lyucean](https://lyucean.com/vpn-amneziawg/), адаптировано для
реального хоста Ubuntu и проверено по [документации Amnezia по установке модуля ядра](https://docs.amnezia.org/documentation/instructions/install-amneziawg-kernel-module-linux/).
Используются официальные пакеты Docker, нативный PPA Amnezia для Noble с ограниченной областью действия
ключа подписи, зафиксированный базовый образ контейнера и сеть хоста с `NET_ADMIN`.
Модуль ядра загружается при запуске системы, Docker перезапускает контейнер, а systemd-служба
повторно применяет небольшие правила межсетевого экрана хоста после запуска Docker.

## Установка Ansible на macOS

При необходимости установите [Homebrew](https://brew.sh/), затем выполните:

```sh
brew install python@3.12 git
git clone https://github.com/Ai0N4/AmneziaWG-Web-Panel.git
cd AmneziaWG-Web-Panel
python3.12 -m venv .venv
```

## Установка Ansible на Linux

Для контролирующей машины требуется Python 3.12 или новее для зафиксированной версии Ansible.
В Ubuntu 24.04 или современной версии Debian с Python 3.12+:

```sh
sudo apt update && sudo apt install -y python3 python3-venv python3-pip git openssh-client
```

В актуальной версии Fedora:

```sh
sudo dnf install -y python3 python3-pip git openssh-clients
```

Затем клонируйте репозиторий и создайте виртуальное окружение:

```sh
git clone https://github.com/Ai0N4/AmneziaWG-Web-Panel.git
.git
cd AmneziaWG-Web-Panel
python3 --version
python3 -m venv .venv
```

Если `python3 --version` показывает версию ниже 3.12, сначала установите поддерживаемый интерпретатор Python
и используйте его исполняемый файл (например, `python3.12`) для создания `.venv`.
Поддержка Linux в качестве контролирующей машины не меняет ограничения целевой системы на Ubuntu 24.04.

## Установка зависимостей проекта (для обеих платформ)

Из корневого каталога репозитория:

```sh
.venv/bin/python -m pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
.venv/bin/ansible-galaxy collection install -r requirements.yml
.venv/bin/ansible --version
```

Ansible выполняется локально через SSH; на целевом сервере он не устанавливается. Целевой сервер
должен иметь Python 3 и доступ root либо sudo без пароля. См.
[официальное руководство по установке Ansible](https://docs.ansible.com/projects/ansible/latest/installation_guide/intro_installation.html).

## Настройка приватного inventory и развёртывание

```sh
cp inventory.example.yml inventory.local.yml
chmod 600 inventory.local.yml
```

Отредактируйте `inventory.local.yml`: замените `vpn-server.example` адресом целевого сервера
и укажите `ansible_user`. При необходимости добавьте `ansible_ssh_private_key_file` с путём
к вашему SSH-ключу или используйте SSH-agent. Не вставляйте приватные ключи в inventory.
Для учётной записи с sudo укажите её имя и используйте `--ask-become-pass`, если это требуется.

Реальный inventory добавлен в `.gitignore`. `ansible.cfg` по умолчанию использует фиктивный inventory,
поэтому для каждого реального развёртывания необходимо явно указывать `-i inventory.local.yml`. Никогда не используйте принудительное
добавление локального inventory. Для нескольких серверов используйте дополнительные алиасы внутри
`vpn.hosts` и `--limit <alias>`, чтобы выполнять развёртывание на одном хосте за раз.

```sh
ssh root@vpn-server.example true
.venv/bin/ansible -i inventory.local.yml vpn -m ansible.builtin.ping
.venv/bin/ansible-lint
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/ansible-playbook playbook.yml --syntax-check
.venv/bin/ansible-playbook -i inventory.local.yml playbook.yml --check --diff -k -K
```

Проверка SSH host key остаётся включённой. При первом подключении проверьте отпечаток сервера.
Для отдельного `.known_hosts` можно использовать
`--ssh-common-args='-o UserKnownHostsFile=.known_hosts -o StrictHostKeyChecking=yes'`.

Режим проверки (**check mode**) предназначен **только для предварительной проверки**: он проверяет платформу и конфликтующие пакеты;
он не моделирует установку репозиториев, сборку DKMS, запуск контейнера
или генерацию учётных данных. При установке выполняются проверки во время работы, после чего
выполняется обычный повторный запуск для проверки идемпотентности. Полное обновление ОС или перезагрузка не выполняются.

Значения по умолчанию находятся в `roles/amneziawg/defaults/main.yml`. Переопределяйте endpoint, внешний
интерфейс или порты в inventory/групповых переменных. Подсеть VPN — `10.8.0.0/24`;
перед использованием на другом сервере проверьте пересечение сетей. Это развёртывание
рассчитано на чистый хост; перед применением на другом сервере проверьте существующие VPN, контейнеры и firewall
перед применением. Firewall провайдера должен разрешать настроенный UDP-порт VPN
(`amneziawg_port`, по умолчанию 51820) и SSH.

## Настройка UDP-порта VPN

Укажите `amneziawg_port` для целевого хоста в игнорируемом inventory. Допустимо
целое число от **1 до 65535**, включая привилегированные порты, такие как 53 и 443:

```yaml
amneziawg_port: 443
```

```sh
.venv/bin/ansible-playbook -i inventory.local.yml playbook.yml
```

VPN использует UDP независимо от TCP-порта nginx. VPN UDP 443 и nginx TCP
443 могут работать одновременно. UDP 53 поддерживается только при отсутствии конфликтов: локальный DNS
резолвер, привязанный даже к loopback-адресу, может конфликтовать с wildcard
listener. Playbook проверяет конфликтующие UDP-сокеты перед изменением
firewall или контейнера и отказывается останавливать или перенастраивать другой сервис.

Изменение порта пересоздаёт VPN-контейнер и ненадолго прерывает соединения.
Порт, на котором слушает сервер, новые клиентские endpoint и управляемые правила firewall
используют одно и то же значение. **Уже импортированные клиенты должны изменить порт своего Endpoint
или заново скачать и импортировать конфигурацию из панели.** Обновите также
правила firewall провайдера. Чтобы отменить изменение, восстановите предыдущий `amneziawg_port`, повторно примените настройки
и восстановите порты endpoint на клиентах. Изменение порта не превращает VPN-пакеты в
DNS- или HTTPS-трафик.

## Приватный доступ к панели

Панель всегда обслуживает обычный HTTP на **127.0.0.1:51821**. По умолчанию
`amneziawg_ui_public: false`, so the nginx proxy is disabled and no public TCP
port is opened. Access the panel through SSH:

```sh
ssh -N -L 51821:127.0.0.1:51821 root@vpn-server.example
```

Откройте <http://127.0.0.1:51821>. Получите существующий пароль панели в другом терминале:

```sh
ssh root@vpn-server.example 'cat /opt/amneziawg/password.txt'
```

## Публичный доступ через nginx

Установите эти переменные для целевого хоста в игнорируемом `inventory.local.yml`:

```yaml
amneziawg_ui_public: true
amneziawg_nginx_port: 443
amneziawg_nginx_tls_enabled: true
amneziawg_nginx_username: admin
```

Затем выполните развёртывание:

```sh
.venv/bin/ansible-galaxy collection install -r requirements.yml
.venv/bin/ansible-playbook -i inventory.local.yml playbook.yml
```

Откройте `https://vpn-server.example/`. Сначала войдите в Basic-auth nginx в браузере,
затем используйте существующий пароль панели на странице входа. Оба уровня
остаются обязательными. Получите сгенерированные nginx-учётные данные через проверенное SSH-соединение:

```sh
ssh root@vpn-server.example 'cat /opt/amneziawg/nginx-username.txt /opt/amneziawg/nginx-password.txt'
```

Ansible один раз генерирует независимый случайный пароль Basic-auth на сервере.
Имя пользователя по умолчанию — `admin`, его можно изменить. Учётные данные в открытом виде и
bcrypt-хеш находятся в `/opt/amneziawg`, доступны только root и сохраняются
при повторном развёртывании. Процессы nginx читают только хеш из
`/etc/amneziawg-nginx/htpasswd` (`root:www-data`, mode `0640`). Secret-bearing tasks
suppress output. Do not put credentials in inventory, commands, Git, or logs.

`amneziawg_ui_public` — единственный переключатель публичного доступа: он включает выделенную
`amneziawg-proxy.service`, which forwards to `http://127.0.0.1:51821`, and adds a
managed TCP firewall rule. The backend never listens publicly. nginx validates
Basic authentication on every path and removes its Authorization header before
forwarding requests. The distribution's default nginx site is not started on a
new installation; existing unrelated nginx services and sites are left intact.

`amneziawg_nginx_port` определяет публичный TCP-порт (по умолчанию **80**, допустимы значения
1–65535, кроме **51821**, зарезервированного для backend).
`amneziawg_nginx_tls_enabled` определяет использование HTTPS (по умолчанию **false**). Настроенные значения должны оставаться корректными даже в приватном режиме. Обе настройки действуют только
на nginx при `amneziawg_ui_public: true`. Для HTTP используйте порт 80 и TLS false;
HTTP передаёт Basic credentials и сессии панели без шифрования, поэтому используйте HTTPS
для публичных развёртываний. Одно только изменение порта не меняет протокол.
Убедитесь, что выбранный TCP-порт разрешён firewall провайдера.

The playbook rejects ports owned by unrelated services. Port changes reload nginx
and replace the old managed firewall rule. Set the previous port and reapply to
undo a port change. Set `amneziawg_ui_public: false` and reapply to stop/disable the
прокси, удалить его управляемое TCP-правило и удалить cron продления сертификата. Сохранённые
настройки nginx-порта/TLS игнорируются в приватном режиме; localhost HTTP остаётся
доступен через SSH. Переключение режимов прокси не пересоздаёт VPN-контейнер.

### Миграция с прямого публичного доступа к панели

Оставьте `amneziawg_ui_public`, переименуйте `amneziawg_ui_port` в `amneziawg_nginx_port`,
а `amneziawg_tls_enabled` — в `amneziawg_nginx_tls_enabled` в локальном inventory.
Старые имена переменных порта/TLS явно отклоняются. Если ранее публичным портом был
51821, его необходимо изменить (например, на 443 с TLS). При первой миграции
контейнер панели пересоздаётся на localhost, что ненадолго прерывает VPN-соединения; данные панели/клиентов
и существующий сертификат сохраняются. Последующие изменения nginx-порта, TLS и
публичной доступности не перезапускают VPN-контейнер.

### HTTPS с самоподписанным сертификатом

nginx завершает TLS 1.2/1.3 и при включённом HTTPS устанавливает cookies с атрибутами Secure, HttpOnly, SameSite=Lax
при включённом HTTPS. Публичного незашифрованного listener или HTTP-редиректа нет.
Playbook создаёт RSA-ключ размером 3072 бит и самоподписанный сертификат сроком действия
365 дней. В Subject и Issuer используется нейтральное имя `Restricted`; ни в одном из них
не указывается AmneziaWG. Сертификат распространяется на `amneziawg_host` (настроенный VPN endpoint) и localhost,
включая IP SAN для числовых адресов. При изменении адреса обновите `amneziawg_host` и повторно примените настройки.
TLS-файлы находятся в `/opt/amneziawg/tls` вне
контекста сборки образа; контейнер панели не имеет mount для TLS-ключа или сертификата.

При обновлении со старого брендированного сертификата он выпускается заново с нейтральным именем,
при сохранении приватного ключа и endpoint SAN. nginx перезагружает новый сертификат;
обновите явное доверие браузера/клиента к старому самоподписанному сертификату.
Будущие автоматические продления сохраняют нейтральное имя из обновлённого CSR.

Браузеры показывают предупреждение о доверии, пока вы явно не добавите самоподписанный
сертификат в доверенные. Получайте только публичный сертификат через проверенный SSH и проверяйте его
SHA-256 fingerprint перед тем, как доверять ему:

```sh
ssh root@vpn-server.example 'openssl x509 -in /opt/amneziawg/tls/cert.pem -noout -fingerprint -sha256'
scp root@vpn-server.example:/opt/amneziawg/tls/cert.pem /tmp/amneziawg-cert.pem
# curl prompts for the nginx password; use your configured username:
curl --cacert /tmp/amneziawg-cert.pem --user admin https://vpn-server.example/api/session
```

Храните `key.pem` на сервере. Развёртывание явно проверяет доверие к созданному
сертификату, проверяет его SAN, отклоняет отсутствующие/неверные Basic credentials и проверяет
оба уровня аутентификации и Secure cookies через HTTPS. См. документацию nginx по
[Basic authentication](https://nginx.org/en/docs/http/ngx_http_auth_basic_module.html)
and [cookie flags](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cookie_flags)
для используемых директив прокси.

### Автоматическое продление сертификата

При включённом публичном режиме и TLS nginx файл `/etc/cron.d/amneziawg-certificate` запускается
ежедневно в **03:17 по часовому поясу сервера** от имени root. Он обновляет сертификат, когда до окончания
срока остаётся менее 30 дней, используя существующий приватный ключ и CSR. Блокировка предотвращает одновременное
продление; новый сертификат проверяется и устанавливается атомарно. Вспомогательный скрипт
проверяет конфигурацию nginx и перезагружает только активную службу `amneziawg-proxy`.
Он никогда не перезапускает VPN-контейнер и не запускает остановленный прокси. При неудачной
проверке/перезагрузке оставляется маркер для повторной попытки при следующем запуске. Логи используют
syslog-тег `amneziawg-tls`.

```sh
ssh root@vpn-server.example 'cat /etc/cron.d/amneziawg-certificate'
ssh root@vpn-server.example 'journalctl -t amneziawg-tls'
# Check now; a certificate with more than 30 days left stays unchanged:
ssh root@vpn-server.example /usr/local/sbin/amneziawg-renew-certificate
# Force renewal and nginx reload (changes the certificate fingerprint):
ssh root@vpn-server.example '/usr/local/sbin/amneziawg-renew-certificate --force'
```

Refresh clients that explicitly trust the old certificate after renewal. The
fingerprint changes even though the key is retained. Disabling nginx TLS removes
cron-задачу и обслуживает HTTP на настроенном nginx-порту; явно укажите нужный HTTP
порт. Отключение публичного режима останавливает прокси и удаляет cron независимо
от сохранённых настроек TLS. Сертификаты и учётные данные сохраняются.

Создайте клиента в панели и импортируйте его QR-код/конфигурацию в AmneziaWG.
Secrets and client keys stay under `/opt/amneziawg`; back it up securely. Only the
panel's bcrypt hash is passed to the container. The article's `PASSWORD` setting
заменена на `PASSWORD_HASH`.

Базовый образ содержит старые инструменты `awg`, которые не работают с текущим модулем ядра v3
(`netlink: attribute type 14 has an invalid length`). Роль собирает небольшой
производный образ на целевом сервере, заменяя `awg` инструментами, собранными из зафиксированного
upstream-коммита, указанного в настройках по умолчанию. Загруженный архив проверяется по SHA-256;
пакеты компилятора остаются на этапе сборки. Исходный код и Dockerfile находятся в
`/opt/amneziawg/build`, отдельно от секретов. При первой установке необходим исходящий
HTTPS-доступ к репозиториям пакетов, Docker Hub, зеркалам Alpine и GitHub.
Образ также содержит проверенный патч для upstream middleware аутентификации:
ответы нативного Node должны использовать `writeHead`/`end`, а не Express `status`/`json`.
Без этого патча отклонённые запросы возвращают HTTP 500 вместо 401. Проверка
проверяет как отказ при неправильном пароле, так и успешный вход с сгенерированным
паролем; все операции, связанные с секретами, подавляют вывод Ansible.

`WG_DEVICE` использует обнаруженный внешний интерфейс (`ens3` на этом хосте), поэтому
собственные NAT-правила контейнера настроены корректно. Его устаревшие правила iptables дополняются
ограниченными правилами host iptables-nft INPUT/FORWARD. Существующие правила/политики по умолчанию
никогда не очищаются и не заменяются. Открывается только выбранный публичный TCP-порт nginx. Маршрутизация IPv4 через туннель
настраивается; поведение IPv6 на клиентах следует проверять отдельно.

## Проверка и процедура остановки

```sh
ssh root@vpn-server.example 'systemctl is-active docker amneziawg-firewall; awg show wg0 listen-port'
ssh root@vpn-server.example 'curl -fsS http://127.0.0.1:51821/api/session'
# With public mode enabled, also verify the dedicated proxy:
ssh root@vpn-server.example 'systemctl is-active amneziawg-proxy && nginx -t -c /etc/amneziawg-nginx/nginx.conf'
.venv/bin/ansible-playbook -i inventory.local.yml playbook.yml
# Stop the deployment and its automatic restart; retain keys and client data:
.venv/bin/ansible-playbook -i inventory.local.yml rollback.yml
```

Rollback останавливает/отключает управляемый nginx-прокси и контейнер, удаляет
cron-задачу продления сертификата и удаляет только управляемые правила firewall хоста. Учётные данные,
сертификаты и данные VPN-клиентов сохраняются.
Установленные пакеты, репозитории, модуль и IP forwarding остаются на месте, чтобы
не нарушать работу других функций общего хоста. Для повторного запуска выполните `playbook.yml`.
После частично неудачной установки проверьте, какие службы существуют, прежде чем выполнять rollback.
Удаление ядра/пакетов является отдельной операцией. Перезагрузка не является частью rollback.

Для полной сквозной проверки подключите реального внешнего VPN-клиента и подтвердите
handshake, разрешение DNS и публичный IP-адрес выхода. Одни только серверные проверки не могут
подтвердить работу UDP-firewall провайдера или интернет-соединение через туннель клиента.
