# 🚀 S-wave

**S-wave** --- это легковесная надстройка, которая автоматизирует
установку и настройку [Sing-box](https://sing-box.sagernet.org/) на
роутерах семейства **Keenetic**.

S-wave --- это переделаный клон [Kneen](https://github.com/Skrill0/XKeen), но
адаптированный под **Sing-box**. Sing-box готовый берется с https://github.com/SagerNet/sing-box/releases с помощью  github action, если подскажите какая версия работает c процесорами mips на Ultra SE (KN-2510), Giga SE (KN-2410), DSL (KN-2010), Skipper DSL (KN-2112), Duo (KN-2110), Ultra SE (KN-2510),  Hopper DSL (KN-3610), добавлю в релиз

------------------------------------------------------------------------

Инструмент для настройки и управления **sing-box** на роутерах с поддержкой `opkg`.

---

## 📦 Установка

1. **Скачайте пакет для вашей архитектуры процессора:**

   ```bash
   opkg install https://github.com/for6to9si/S-wave/releases/download/v1.12.8/sing-box_1.12.8_{CPU}.ipk
   ```

   > Замените `{CPU}` на тип процессора вашего роутера.

---

## 🖥 Поддерживаемые архитектуры CPU

Наиболее распространённые значения `{CPU}`:

* `mipsel` — для роутеров с процессорами MediaTek, Ralink
* `aarch64` — для 64-битных ARM

---

2. **После установки** на вашем роутере появится группа политик **Swave**.
   По окончании успешного запуска `/opt/etc/init.d/S99sing-box` добавьте ваше устройство в политику **Swave**.

---

3. **Скопируйте и настройте конфигурацию:**

   ```bash
   mv /opt/etc/xwave/example.json /opt/etc/xwave/settings.json
   ```

---

4. **Основные настройки находятся в файле:**

   ```
   /opt/etc/swave/settings.json
   ```

   🔧 Важные параметры:

    * Используется режим **redirect** для TCP (`порт 60008`) и **tproxy** для UDP (`порт 60009`).
    * `port_forwarding_list` — список портов для перенаправления (по умолчанию: `80, 443, 8080`).
    * `port_forwarding_range` — диапазон портов для перенаправления.
    * `IPv4_exclusions` — список IP-адресов, которые **не будут отправляться через VPN**.
    * `"port_redirect": "60008"` — должен совпадать с параметром в блоке
      `inbounds -> "type": "redirect"` в файле
      `/opt/etc/sing-box/configs/config.json`.
    * `"port_tproxy": "60009"` — должен совпадать с параметром в блоке
      `inbounds -> "type": "tproxy"` в файле
      `/opt/etc/sing-box/configs/config.json`.

---

5. **Основные команды управления:**

   ```bash
   /opt/etc/init.d/S99sing-box start           # Запуск sing-box
   /opt/etc/init.d/S99sing-box restart         # Перезапуск sing-box
   /opt/etc/init.d/S99sing-box fast_restart    # Быстрый перезапуск sing-box без перезапуска таблиц маршрутизации.
   /opt/etc/init.d/S99sing-box status          # Проверка статуса sing-box
   /opt/etc/init.d/S99sing-box backup          # Создание бэкапа конфигурации
   /opt/etc/init.d/S99sing-box stop            # Остановка sing-box
   ```

   > ⚠️ При неуспешном запуске проверяйте лог:
   >
   > ```bash
   > cat /opt/var/log/swave/swave.log
   > ```

---


------------------------------------------------------------------------

## ⚙️ Конфигурация Sing-box

Основной конфиг:

    /opt/etc/sing-box/configs/config.json

Пример `config.json` с входящими и исходящими соединениями, маршрутизацией и логированием:

<details>
<summary>Показать пример config.json</summary>

```json
{
  "log": {
    "disabled": false,
    "level": "debug",
    "output": "/opt/var/log/sing-box/sing-box.log",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "cloudflare",
        "type": "https",
        "server": "1.1.1.1"
      }
    ],
    "final": "cloudflare",
    "strategy": "prefer_ipv4",
    "disable_cache": false,
    "disable_expire": false
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 1081,
      "tcp_fast_open": false,
      "sniff": true,
      "sniff_override_destination": true,
      "set_system_proxy": false
    },
    {
      "type": "redirect",
      "tag": "redirect-in",
      "listen": "::",
      "listen_port": 60008,
      "tcp_fast_open": false,
      "sniff": true,
      "sniff_override_destination": true
    },
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "::",
      "listen_port": 60009,
      "tcp_fast_open": false,
      "sniff": true,
      "sniff_override_destination": true,
      "network": ["udp", "tcp"]
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "Proxy-out",
      "outbounds": ["URL-Test", "ss-german", "ss-netherlands", "vless-genman", "vless-netherlands"],
      "default": "URL-Test"
    },
    {
      "type": "urltest",
      "tag": "URL-Test",
      "outbounds": ["ss-german", "ss-netherlands", "vless-genman", "vless-netherlands"],
      "url": "http://www.gstatic.com/generate_204",
      "interval": "3m30s",
      "tolerance": 50,
      "idle_timeout": "30m0s",
      "interrupt_exist_connections": false
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rule_set": [
      {
        "tag": "geoip-ru",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
        "download_detour": "Proxy-out"
      }
    ],
    "default_domain_resolver": {
      "server": "cloudflare",
      "rewrite_ttl": 60,
      "client_subnet": "1.1.1.1"
    },
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "port": 53, "action": "hijack-dns" },
      { "protocol": ["quic"], "action": "reject" },
      { "rule_set": "geoip-ru", "outbound": "direct" },
      {
        "ip_cidr": ["94.100.180.201/32", "94.100.180.202/32"],
        "domain_keyword": ["mail.ru", "yandex.net", "yastatic.net", "yandex.ru", "vk.com"],
        "domain_suffix": [".ru"],
        "outbound": "direct"
      }
    ],
    "final": "Proxy-out",
    "auto_detect_interface": true
  },
  "experimental": {
    "cache_file": { "enabled": true },
    "clash_api": {
      "external_controller": "0.0.0.0:9090",
      "external_ui": "ui",
      "external_ui_download_detour": "Proxy-out"
    }
  }
}
```

</details>

------------------------------------------------------------------------

## 🌍 Примеры VPN-конфигураций

Можно оставить только один файл.

**Shadowsocks (ss-german.json):**

``` json
{
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-german",
      "method": "aes-256-gcm",
      "server": "111.111.111.111",
      "server_port": 46813,
      "password": "6mXfvававававfYOVdxBcxElCwzJgBV0tRgbKbU="
    }
  ]
}
```

**VLESS (vless-german.json):**

``` json
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-genman",
      "server": "111.111.111.111",
      "server_port": 111,
      "uuid": "c762d232-c5e0-4260-a395-1111111111",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "packet_encoding": "xudp",
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "public_key": "VPN Public key",
          "short_id": "c11876,1111,111"
        },
        "insecure": false,
        "server_name": "duma.gov.ru",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    }
  ]
}
```

------------------------------------------------------------------------

## 📂 Структура конфигов

После настройки папка должна выглядеть так:

    /opt/etc/sing-box/configs
    ├── config.json
    ├── ss-german.json
    ├── ss-netherlands.json
    ├── vless-german.json
    └── vless-netherlands.json

------------------------------------------------------------------------

## ✅ Итог

* Установка проста: скачать пакет и настроить JSON.
* Можно использовать **несколько VPN-конфигов** или оставить один.
* Управление через `/opt/etc/swave/settings.json` и `/opt/etc/sing-box/configs/config.json`.
* Поддерживается **redirect (TCP)** и **tproxy (UDP)** для гибкой маршрутизации.
