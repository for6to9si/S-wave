#!/bin/sh

# Путь к JSON-файлу с настройками
SETTING="/opt/etc/swave/settings.json"

get_clean_json() {
  awk '
  BEGIN { in_string = 0 }
  {
    line = $0
    result = ""
    for (i = 1; i <= length(line); i++) {
      char = substr(line, i, 1)
      next_char = substr(line, i+1, 1)
      if (char == "\"" && prev != "\\") {
        in_string = !in_string
      }
      if (!in_string && char == "/" && next_char == "/") {
        break
      }
      result = result char
      prev = char
    }
    print result
  }' "$1"
}

js_SETTING=$(get_clean_json "$SETTING" | jq -c '.' 2>/dev/null)

DEBUG=false
DEBUG_LOG=$(echo "$js_SETTING" | jq -r '.app.log')

# Функция для отладки
debug() {
    [ "$DEBUG" = "true" ] && {
        _YELLOW='\033[33m'
        _NC='\033[0m'  # No Color
        echo -e "${_YELLOW}[DEBUG]${_NC} $*"          # Вывод в терминал
    #    logger -p debug -t "$(basename "$0")" "$*"  # И в syslog (опционально)
    #    echo "$(date) $*" >> "$DEBUG_LOG"           # И в файл (опционально)
    }
}

# Включение трассировки (если нужно)
#[ "$DEBUG" = "true" ] && set -x

# Выключение трассировки (если включали)
[ "$DEBUG" = "true" ] && set +x

# Пример использования
#chain_name=$(echo "$js_SETTING" | jq -r '.network.chain_name')
#debug "Наименование цепочки ${chain_name}"

IP_RULES_LOG=$(echo "$js_SETTING" | jq -r '.app.log')

# Если переменная не задана, используем /dev/null
LOG_FILE="${IP_RULES_LOG:-/dev/null}"

restart_script() {
      "$0" "$@"
    exit $?
}

IPv6=$(echo "$js_SETTING" | jq -r '.network.IPv6 // "false"')

if ip -6 addr show scope global | grep -q inet6; then
    debug "IPv6-адреса настроены (глобальные)"
else
    debug "IPv6-адреса отсутствуют или отключены"
    IPv6=false
fi

get_policy_mark() {

  # Определяем коды цветов (используем $'...' для интерпретации escape-последовательностей)
  _color_red=$'\033[31m'
  _color_reset=$'\033[0m'

  policy_mark=$(
      curl -kfsS "localhost:79/rci/show/ip/policy" \
      | jq -r --arg policy "$(echo "$js_SETTING" | jq -r '.network.connection_policy')" '
          .[]
          | select(.description
          | ascii_downcase == ($policy | ascii_downcase))
          | .mark'
  )

  if [ -z "$policy_mark" ]; then
      printf "%s %s[ERROR]%s Не удалось получить отметку о политике для: %s\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$_color_red" \
        "$_color_reset" \
        "$(echo "$js_SETTING" | jq -r '.network.connection_policy')" >&2
      logger -t "$(basename "$0")" "Не удалось получить отметку о политике для: $(echo "$js_SETTING" | jq -r '.network.connection_policy')"
      return 1
  fi

  echo "0x${policy_mark}"
}

load_kernel_modules(){

  modules=$(echo "$js_SETTING" | jq -r '.network.modules | join(" ")')
  modules_path=$(echo "$js_SETTING" | jq -r '.network.module_path')

  for mod in $modules; do
      modname=$(basename "$mod" .ko)
      if lsmod | grep -q "^$modname"; then
          continue
      else
          echo "Модуль $modname не загружен. Пытаюсь загрузить..."
          logger -t "$(basename "$0")" "Модуль $modname не загружен. Пытаюсь загрузить..."
          if insmod "$modules_path/$mod"; then
              echo "Модуль $modname успешно загружен."
              logger -t "$(basename "$0")" "Модуль $modname успешно загружен."
          else
              echo "Ошибка загрузки модуля $modname из $modules_path/$mod"
              logger -t "$(basename "$0")" "Ошибка загрузки модуля $modname из $modules_path/$mod"
          fi
      fi
  done
}

init_dns_tables(){

    # Проверка наличия цепочек и включенного dns_filter
    if [ "${1}" = "iptables" ] \
    && iptables -t nat -nL "${chain_name}" >/dev/null 2>&1 \
    && iptables -t mangle -nL "${chain_name}" >/dev/null 2>&1 \
    && echo "$js_SETTING" | jq -e '.network.dns.dns_filter == true' >/dev/null
    then
        # IPv4
        for ip in $(echo "$js_SETTING" | jq -r '.network.dns.IPv4[]'); do
            if ! iptables -t nat -C "${chain_name}" -d "$ip" -p tcp -m tcp ! --dport 53 -j RETURN 2>/dev/null; then
                iptables -w -t nat    -A "${chain_name}" -d "$ip" -p tcp -m tcp ! --dport 53 -j RETURN
            fi
            if ! iptables -t mangle -C "${chain_name}" -d "$ip" -p tcp -m tcp --dport 53 -j RETURN 2>/dev/null; then
                iptables -w -t mangle -A "${chain_name}" -d "$ip" -p tcp -m tcp --dport 53 -j RETURN
            fi
            if ! iptables -t mangle -C "${chain_name}" -d "$ip" -p udp -m udp ! --dport 53 -j RETURN 2>/dev/null; then
                iptables -w -t mangle -A "${chain_name}" -d "$ip" -p udp -m udp ! --dport 53 -j RETURN
            fi
            if ! iptables -t nat -C "${chain_name}" -d "$ip" -p udp -m udp --dport 53 -j RETURN 2>/dev/null; then
                iptables -w -t nat    -A "${chain_name}" -d "$ip" -p udp -m udp --dport 53 -j RETURN
            fi
            debug "DNS таблица цепи ${chain_name} для ${ip} создана"
        done
    fi

    if [ "${1}" = "ip6tables" ] \
    && ip6tables -t nat -nL "${chain_name}" >/dev/null 2>&1 \
    && ip6tables -t mangle -nL "${chain_name}" >/dev/null 2>&1 \
    && echo "$js_SETTING" | jq -e '.network.dns.dns_filter == true' >/dev/null
    then
        # Проверка, разрешён ли IPv6

        if [ "$IPv6" != "false" ]; then
            for ip6 in $(echo "$js_SETTING" | jq -r '.network.dns.IPv6[]'); do
                if ! ip6tables -t nat -C "${chain_name}" -d "$ip6" -p tcp -m tcp ! --dport 53 -j RETURN 2>/dev/null; then
                    ip6tables -w -t nat    -A "${chain_name}" -d "$ip6" -p tcp -m tcp ! --dport 53 -j RETURN
                fi
                if ! ip6tables -t mangle -C "${chain_name}" -d "$ip6" -p tcp -m tcp --dport 53 -j RETURN 2>/dev/null; then
                    ip6tables -w -t mangle -A "${chain_name}" -d "$ip6" -p tcp -m tcp --dport 53 -j RETURN
                fi
                if ! ip6tables -t mangle -C "${chain_name}" -d "$ip6" -p udp -m udp ! --dport 53 -j RETURN 2>/dev/null; then
                    ip6tables -w -t mangle -A "${chain_name}" -d "$ip6" -p udp -m udp ! --dport 53 -j RETURN
                fi
                if ! ip6tables -t nat -C "${chain_name}" -d "$ip6" -p udp -m udp --dport 53 -j RETURN 2>/dev/null; then
                    ip6tables -w -t nat    -A "${chain_name}" -d "$ip6" -p udp -m udp --dport 53 -j RETURN
                fi
                debug "DNS таблица цепи ${chain_name} для ${ip6} создана"
            done
        fi
    fi

}

#создания цепи и правил
init_iptables(){
  chain_name=$(echo "$js_SETTING" | jq -r '.network.chain_name')
  chain_name_output="${chain_name}"_out
  table_mark_hex=$(echo "$js_SETTING" | jq -r '.network.table_mark_hex')
  port_tproxy=$(echo "$js_SETTING" | jq -r '.network.port_tproxy')
  port_redirect=$(echo "$js_SETTING" | jq -r '.network.port_redirect')
  policy_mark=$(get_policy_mark)
  port_forwarding_list=$(echo "$js_SETTING" | jq -r '.network.port_forwarding_list | join(",")')
  if echo "$js_SETTING" | jq -e '.network.dns.dns_filter' > /dev/null; then
    port_forwarding_list="53,${port_forwarding_list}"
  fi
#  load_kernel_modules

  for family in iptables ip6tables; do
    [ "$family" = "ip6tables" ] && [ "$IPv6" != "true" ] && continue

    # Используем ::1 для ip6tables, иначе 127.0.0.1
    loopback_ip="127.0.0.1"
    [ "$family" = "ip6tables" ] && loopback_ip="::1"

    # REDIRECT
    if ! "${family}" -t nat -nL ${chain_name} >/dev/null 2>&1; then
      "${family}" -w -t nat -N ${chain_name} >> "${LOG_FILE}" 2>&1
      debug "#REDIRECT ($family)"
      "${family}" -w -t nat -A ${chain_name} -p tcp -j REDIRECT --to-port "${port_redirect}" >> "${LOG_FILE}" 2>&1
      "${family}" -w -t nat -A PREROUTING -m connmark --mark ${policy_mark} -m conntrack ! --ctstate INVALID -p tcp -m multiport --dports  ${port_forwarding_list} -j ${chain_name} >>"${LOG_FILE}" 2>&1
    fi

    # TPROXY
    if ! "${family}" -t mangle -nL ${chain_name} >/dev/null 2>&1; then
      "${family}" -w -t mangle -N ${chain_name}
      debug "#TPROXY ($family)"
      "${family}" -w -t mangle -I ${chain_name} -p udp -m socket --transparent -j MARK --set-mark "${table_mark_hex}" >> "${LOG_FILE}" 2>&1
      "${family}" -w -t mangle -A ${chain_name} -p udp -j TPROXY --on-ip "$loopback_ip" --on-port "${port_tproxy}" --tproxy-mark "${table_mark_hex}" >> "${LOG_FILE}" 2>&1
      "${family}" -w -t mangle -A PREROUTING -m connmark --mark ${policy_mark} -m conntrack ! --ctstate INVALID -p udp -m multiport --dports  ${port_forwarding_list} -j ${chain_name} >> "${LOG_FILE}" 2>&1
#      "${family}" -w -t mangle -A PREROUTING -m connmark ! --mark ${policy_mark} -m conntrack ! --ctstate INVALID -p udp -m multiport --dports 53 -j ${chain_name} >> "${LOG_FILE}" 2>&1
    fi

    #DNS
    init_dns_tables "$family"

    # OUTPUT nat
    if ! "${family}" -t nat -nL ${chain_name_output} >/dev/null 2>&1; then
      "${family}" -w -t nat -N ${chain_name_output}
      debug "#OUTPUT ($family)"
    fi
    # OUTPUT mangle
    if ! "${family}" -t mangle -nL ${chain_name_output} >/dev/null 2>&1; then
      "${family}" -w -t mangle -N ${chain_name_output}
      debug "#OUTPUT mangle ($family)"
      # ! --uid-owner 0 — правило применяется ко всем пользователям, кроме root (UID 0).
      # Для всех исходящих UDP-пакетов, отправленных НЕ от root-пользователя, применяется переход в цепочку swave_out (идёт маркировка, перенаправление, маршрутизация и т.д.).
      "${family}" -w -t mangle -A OUTPUT -m owner ! --uid-owner 0 -m conntrack ! --ctstate INVALID -p udp -j ${chain_name_output}
      "${family}" -w -t mangle -A ${chain_name_output} -p udp -j CONNMARK --set-mark "${table_mark_hex}"
    fi
  done
}

# Проверяет существование  цепочки .network.chain_name  в таблицах mangle и nat для IPv4.
# Если цепочка не существует в одной из таблиц, выводит ошибку и возвращает 1.
# В противном случае возвращает 0.
check_chain_ipv4() {
    for table in mangle nat; do
        if ! iptables -t "$table" -nL "${1}" > /dev/null 2>&1; then
            debug "Ошибка: Цепочка ${1} не существует в таблице $table. Сначала создайте её." >&2
            return 1
        fi
    done
    return 0
}

# Получить IPv4
get_exclude_ip4() {

    ipv4_eth=$(ip route get 9.9.9.9 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' ||
    ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' ||
    ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
    )

    [ -n "$ipv4_eth" ] && ipv4_eth="${ipv4_eth}/32 "

    ipv4_exclude=$(echo "$js_SETTING" | jq -r '.network.IPv4_exclusions | join("\n")')
    ipv4_my="$ipv4_eth
            # Добавляем адреса своих VPN интерфейсов и исключения
            $ipv4_exclude"
    echo "$ipv4_my"

}


add_ipv4tables_exclusions() {

    # Проверяем существование цепочки перед началом работы
    if ! check_chain_ipv4 "${1}"; then
        exit 1
    fi

    # Список IPv4-адресов с комментариями (фильтруются автоматически)
    ipv4_list="
        # 1. Локальные адреса (RFC 1918 + специфичные)
        10.0.0.0/8              # Частная сеть (LAN)
        172.16.0.0/12           # Частная сеть (LAN)
        192.168.0.0/16          # Частная сеть (LAN)
        100.64.0.0/10           # CGNAT (ISP-level NAT)

        # 2. Специальные адреса
        0.0.0.0/8               # Исторически 'этот хост'
        127.0.0.0/8             # Loopback (localhost)
        169.254.0.0/16          # Link-local (автоконфигурация без DHCP)
        255.255.255.255/32      # Широковещательный адрес

        # 3. Зарезервированные IANA (не для публичного использования)
        192.0.0.0/24            # IANA Special Purpose
        192.0.2.0/24            # TEST-NET-1 (документация)
        198.51.100.0/24         # TEST-NET-2 (документация)
        203.0.113.0/24          # TEST-NET-3 (документация)
        198.18.0.0/15           # Benchmarking (тестирование)

        # 4. Multicast и зарезервированное будущее
        224.0.0.0/4             # Multicast (групповая рассылка)
        240.0.0.0/4             # Зарезервировано для будущего
    "
    # Затем добавляем динамические адреса
    excluded_ips=$(get_exclude_ip4)
    if [ -n "$excluded_ips" ]; then
        ipv4_list="$ipv4_list
        # Объеденяем все исключения
        $excluded_ips"
    fi

    # Фильтр: удаляем всё, что после '#', затем обрезаем пробелы
    echo "$ipv4_list" | while read -r line; do
        # Удаляем комментарии и лишние пробелы
        # sed -e 's/^[[:space:]]*//' обрезает пробелы в начале,
        # sed -e 's/[[:space:]]*$//' — в конце строки
        ip=$(echo "$line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "$ip" ] && continue  # Пропускаем пустые строки

        for table in mangle nat; do
            # Проверяем, не существует ли правило уже
            if ! iptables -w -t "$table" -C "${1}" -d "$ip" -j RETURN >/dev/null 2>&1; then
                iptables -w -t "$table" -A "${1}" -d "$ip" -j RETURN >> "${LOG_FILE}" 2>&1
                debug "[OK] Добавлено исключение: $ip (таблица: $table)"
            else
                debug "[Пропуск] Правило для $ip уже существует в таблице $table"
            fi
        done
    done
}

# Проверяем, существует ли цепочка .network.chain_name в таблицах mangle и nat
check_chain_ipv6() {

    for table in mangle nat; do
        if ! ip6tables -w -t "$table" -nL "${1}" >/dev/null 2>&1; then
            debug "Ошибка: Цепочка ${1} не существует в таблице $table. Сначала создайте её." >&2
            return 1
        fi
    done
    return 0
}

# Получить IPv4
get_exclude_ip6() {

    ipv6_eth=$(ip route get 2620:fe::fe | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' ||
    ip route get 2606:4700:4700::64 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' ||
    ip route get 2001:4860:4860::8888 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
    )

    [ -n "$ipv6_eth" ] && ipv6_eth="${ipv6_eth}/128 "

    ipv6_exclude=$(echo "$js_SETTING" | jq -r '.network.IPv6_exclusions | join("\n")')
    ipv6_my="$ipv6_eth
            # Добавляем адреса своих VPN интерфейсов и исключения
            $ipv6_exclude"
    echo "$ipv6_my"

}

add_ipv6tables_exclusions() {

    # Проверяем существование цепочки перед началом работы
    if ! check_chain_ipv6 "${1}"; then
        exit 1
    fi

    # Список IPv6-адресов с комментариями (фильтруются автоматически)
    ipv6_list="
        ::/128                   # Неопределенный адрес (аналог 0.0.0.0 в IPv4)
        ::1/128                  # Loopback (аналог 127.0.0.1)
        ::ffff:0:0/96            # IPv4-mapped адреса (встроенный IPv4 в IPv6)
        64:ff9b::/96             # IPv4-IPv6 трансляция (NAT64)
        100::/64                 # Discard-адреса (RFC 6666)
        2001::/32                # Teredo tunneling (устаревший)
        2001:20::/28             # ORCHIDv2 (криптографические идентификаторы)
        2001:db8::/32            # Документационные адреса (аналог 192.0.2.0/24)
        2002::/16                # 6to4 tunneling (устаревший)
        fc00::/7                 # Уникальные локальные адреса (ULA, аналог IPv4 private)
        fe80::/10                # Link-local адреса (аналог 169.254.0.0/16)
        ff00::/8                 # Multicast (аналог 224.0.0.0/4)
    "

    # Затем добавляем динамические адреса
    excluded_ips=$(get_exclude_ip6)
    if [ -n "$excluded_ips" ]; then
        ipv6_list="$ipv6_list
        # Объеденяем все исключения
        $excluded_ips"
    fi


    # Фильтр: удаляем всё, что после '#', затем обрезаем пробелы
    echo "$ipv6_list" | while read -r line; do
        # Удаляем комментарии и лишние пробелы
        # sed -e 's/^[[:space:]]*//' обрезает пробелы в начале,
        # sed -e 's/[[:space:]]*$//' — в конце строки
        ip=$(echo "$line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "$ip" ] && continue  # Пропускаем пустые строки

        for table in mangle nat; do
            # Проверяем, не существует ли правило уже
            if ! ip6tables -w -t "$table" -C "${1}" -d "$ip" -j RETURN >/dev/null 2>&1; then
                ip6tables -w -t "$table" -A "${1}" -d "$ip" -j RETURN >> "${LOG_FILE}" 2>&1
                debug "[OK] Добавлено исключение: $ip (таблица: $table)"
            else
                debug "[Пропуск] Правило для $ip уже существует в таблице $table"
            fi
        done
    done
}

init_iptables
chain_name=$(echo "$js_SETTING" | jq -r '.network.chain_name')
chain_name_output="${chain_name}"_out
add_ipv4tables_exclusions "${chain_name}"
add_ipv4tables_exclusions "${chain_name_output}"
[ "$IPv6" = "true" ] && add_ipv6tables_exclusions "${chain_name}"
[ "$IPv6" = "true" ] && add_ipv6tables_exclusions "${chain_name_output}"


logger -p notice -t "$(basename "$0")" "Activate '"${chain_name}"' routing tables"