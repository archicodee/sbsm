# 📦 SBSM — Sing-Box Subscription Manager

Автоматическое управление подписками на прокси-серверы для **sing-box** на OpenWrt.

> Скачивает списки прокси из URL-подписок, валидирует, группирует и генерирует готовую конфигурацию.

---

## ⚡ Быстрый запуск

### Для Podkop (UCI конфигурация)
```sh
sh <(wget -O - https://raw.githubusercontent.com/archicodee/sbsm/refs/heads/main/sbsm_podkop.sh)
```

### Для sing-box extended (прямой config.json)
```sh
sh <(wget -O - https://raw.githubusercontent.com/archicodee/sbsm/refs/heads/main/sbsm_extended.sh)
```

---

## 📖 Первичная настройка

### 1. Запустите скрипт
Выполните одну из команд выше. Откроется интерактивное меню.

### 2. Зайдите в настройки
В главном меню выберите **Settings** → **Subscriptions**

### 3. Добавьте списки подписок
Введите URL ваших подписок (по одной на строку). Поддерживаются как прямые ссылки, так и base64-кодированные подписки:
```
https://example.com/subscription.txt
https://example.com/base64-subscription
```

### 4. Выберите режим работы
В настройках выберите режим группировки прокси:

| Режим | Описание |
|-------|----------|
| **by_country** | Прокси группируются по странам на основе emoji-флага в названии. Каждая страна получает свою urltest-группу. Идеально когда нужны разные страны. |
| **russia_inside** | Все НЕ-российские прокси в одной группе `russia_inside`, российские — в отдельной `RU`. К группе `russia_inside` применяются SRS-правила маршрутизации (geosite + geoip заблокированных в РФ ресурсов). Рекомендовано для обхода блокировок. |
| **subscription** | Все валидные прокси собираются в одну urltest-группу `subscription`. Самый простой режим — sing-box сам выбирает лучший прокси. |

**Для sing-box extended** дополнительно доступен выбор режима работы:
| SB Mode | Описание |
|---------|----------|
| **tun** | Туннельный режим. Весь трафик проходит через tun-интерфейс. Требуется `auto_route: true`. |
| **tproxy_fakeip** | Прозрачный прокси с FakeIP DNS. Трафик перенаправляется через tproxy. |

### 5. Обновите подписки
Вернитесь в главное меню и нажмите **Update Subscriptions**. Скрипт скачает подписки, проверит каждый прокси, сгруппирует и сгенерирует конфигурацию.

---

## ⏰ Автоматизация через cron (опционально)

Автоматическое обновление прокси настраивается через cron. Это **необязательный** шаг — скрипт отлично работает и вручную.

### Пошаговая инструкция для OpenWRT

**1. Установите cron (если не установлен)**
```sh
opkg update
opkg install cron
/etc/init.d/cron enable
/etc/init.d/cron start
```

**2. Откройте crontab**
```sh
crontab -e
```

**3. Добавьте задачу обновления**
Выберите нужный интервал и добавьте строку:

```sh
# Обновление каждые 6 часов
0 */6 * * * /usr/bin/sbsm_extended.sh update >> /var/log/sbsm.log 2>&1

# Обновление раз в день в 3:00 ночи
0 3 * * * /usr/bin/sbsm_extended.sh update >> /var/log/sbsm.log 2>&1

# Обновление раз в неделю (понедельник, 4:00)
0 4 * * 1 /usr/bin/sbsm_extended.sh update >> /var/log/sbsm.log 2>&1

# Обновление каждые 12 часов
0 */12 * * * /usr/bin/sbsm_podkop.sh update >> /var/log/sbsm.log 2>&1
```

**4. Перезапустите cron**
```sh
/etc/init.d/cron restart
```

**5. Проверьте, что задача добавлена**
```sh
crontab -l
```

**6. Просмотр лога**
```sh
tail -f /var/log/sbsm.log
```

> **Примечание:** Убедитесь, что скрипты доступны по пути `/usr/bin/sbsm_*.sh`, или замените путь на актуальный.

---

## 🌳 Дерево меню

```
┌─────────────────────────────────────────────────┐
│              Главное меню                       │
├─────────────────────────────────────────────────┤
│ 1. Update Subscriptions                         │
│    Скачать подписки, сгруппировать,             │
│    сгенерировать конфиг, перезапустить сервис   │
│                                                 │
│ 2. Build Config                                 │
│    Сгенерировать config.json из текущей базы    │
│    (без скачивания новых подписок)              │
│                                                 │
│ 3. Settings                                     │
│    ├─ Change Mode                               │
│    │   Выбрать режим группировки:               │
│    │   by_country / russia_inside / subscription│
│    │                                            │
│    ├─ Change Sing-Box Mode (только extended)    │
│    │   Выбрать режим: tun / tproxy_fakeip       │
│    │                                            │
│    ├─ Add Subscription URL                      │
│    │   Добавить URL подписки в список           │
│    │                                            │
│    └─ Remove Subscription URL                   │
│        Удалить URL подписки по номеру           │
│                                                 │
│ 0. Exit                                         │
│    Выход из скрипта                             │
└─────────────────────────────────────────────────┘
```

---

## 🌍 Поддерживаемые протоколы

| Протокол | Podkop | Extended |
|----------|:------:|:--------:|
| VLESS (+ xhttp) | ❌ | ✅ |
| Shadowsocks | ✅ | ✅ |
| Trojan | ✅ | ✅ |
| Hysteria2/hy2 | ✅ | ✅ |
| VMess | ❌ | ✅ |
| TUIC | ❌ | ✅ |
| SOCKS4/4A/5 | ✅ | ✅ |

---

## 🙏 Благодарности

- [sing-box-extended](https://github.com/shtorm-7/sing-box-extended) — расширенная версия sing-box
- [Podkop](https://github.com/EikeiDev/podkop) — интеграция с OpenWrt
- [runetfreedom rules](https://github.com/runetfreedom/russia-v2ray-rules-dat) — SRS-списки для маршрутизации
