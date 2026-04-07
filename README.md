# 📦 SBSM — Sing-Box Subscription Manager

Автоматическое управление подписками на прокси-серверы для **sing-box** на OpenWrt.

> Скачивает списки прокси из URL-подписок, валидирует, группирует и генерирует готовую конфигурацию. Есть 2 версии скрипта: 1. sbsm_podkop - скрипт для использования совместно с podkop, 2. sbsm_extended версия для использования совместно с sing-box (эксперементальная, может работать нестабильно)

---

## 🚨 Предупреждение
Данные скрипты не являются средством обхода блокировок, не содержат в себе любых компонентов препятствующих блокировкам, и могут использоваться только в образовательных целях. Не используйте эти скрипты, если вы самостоятельно не отвечаете за свои действия, и не принимаете возможные последствия.

Проект находится в стадии разработки, поэтому может работать некорректно или нестабильно, перед использованием рекомендуется выполнять резервное копирование всех затрагиваемых конфигураций (sing-box: /etc/sing-box/config.json, podkop: /etc/config/podkop)

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
В главном меню перейдите в раздел **Subscriptions**: **3). Settings** → **1. Manage Subscriptions**

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
| **by_country** | Прокси группируются по странам на основе emoji-флага в названии. Каждая страна получает свою urltest-группу. |
| **russia_inside** | Все НЕ-российские прокси в одной группе `russia_inside`, российские — в отдельной `RU`. К группе `russia_inside` применяются правила маршрутизации в зависимости от типа используемого ПО (Настройка Community List для Podkop и SRS-списки для sing-box). |
| **subscription** | Все валидные прокси собираются в одну urltest-группу `subscription`, не затрагивая остальные секции|

**Для sing-box extended** дополнительно доступен выбор режима работы sing-box:
| SB Mode | Описание |
|---------|----------|
| **tun** | Туннельный режим. Весь трафик проходит через tun-интерфейс. Требуется `auto_route: true`. |
| **tproxy_fakeip** | Прозрачный прокси с FakeIP DNS. Трафик перенаправляется через tproxy. |

### 5. Обновите подписки
Вернитесь в главное меню и нажмите **1). Update Subscriptions**. Скрипт скачает подписки, проверит каждый прокси, сгруппирует и сгенерирует конфигурацию, затем перезапустит сервис для применения изменений.

---

## ⏰ Автоматизация через cron (по желанию)

Автоматическое обновление списков прокси можно настроить через cron.

### Пошаговая инструкция для OpenWRT

**1. При необходимости изучите документацию на сайте OpenWRT**
https://openwrt.org/docs/guide-user/base-system/cron

**2. Скачайте и установите скрипт**
Скачайте актуальную версию скрипта с GitHub и поместите его в директорию `/etc/sing-box/`:

```sh
# Создайте директорию, если её ещё нет
mkdir -p /etc/sing-box

# Скачайте скрипт (выберите нужный)
wget -O /etc/sing-box/sbsm_podkop.sh https://raw.githubusercontent.com/archicodee/sbsm/refs/heads/main/sbsm_podkop.sh
# или
wget -O /etc/sing-box/sbsm_extended.sh https://raw.githubusercontent.com/archicodee/sbsm/refs/heads/main/sbsm_extended.sh

# Выдайте права на выполнение
chmod +x /etc/sing-box/sbsm_podkop.sh
# или
chmod +x /etc/sing-box/sbsm_extended.sh
```

**3. Добавьте задачу обновления**
Выберите нужный интервал и добавьте строку:

```sh
# Обновление каждые 6 часов
0 */6 * * * /etc/sing-box/sbsm_extended.sh update >> /var/log/sbsm.log 2>&1

# Обновление раз в день в 3:00 ночи
0 3 * * * /etc/sing-box/sbsm_extended.sh update >> /var/log/sbsm.log 2>&1

# Обновление раз в неделю (понедельник, 4:00)
0 4 * * 1 /etc/sing-box/sbsm_extended.sh update >> /var/log/sbsm.log 2>&1

# Обновление каждые 12 часов
0 */12 * * * /etc/sing-box/sbsm_podkop.sh update >> /var/log/sbsm.log 2>&1
```

**4. Перезапустите cron**
```sh
service cron restart
```

**5. Проверьте, что задача добавлена**
```sh
crontab -l
```

**6. Просмотр лога**
```sh
tail -f /var/log/sbsm.log
```

> **Примечание:** Убедитесь, что скрипты доступны по пути `/etc/sing-box/sbsm_*.sh`, или замените путь на актуальный.

---

## 🌳 Дерево меню

```
┌─────────────────────────────────────────────────┐
│              Главное меню                       │
├─────────────────────────────────────────────────┤
│ 1). Update Subscriptions                        │
│    Скачать подписки, сгруппировать,             │
│    сгенерировать конфиг, перезапустить сервис   │
│                                                 │
│ 2). Check Proxies                               │
│    Проверить текущую базу прокси на             │
│    работоспособность(без скачивания             │
│    новых подписок)                              │
│                                                 │
│ 3). Settings                                    │
│    ├─ Manage Subscriptions                      │
│    │   Управления списком источников подписок   │
│    ├─ Change Mode                               │
│    │   Выбрать режим группировки:               │
│    │   by_country / russia_inside / subscription│           │
│ 0). Exit                                        │
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

- [sing-box-extended](https://github.com/shtorm-7/sing-box-extended)
- [OpenWRT-sing-box-extended](https://github.com/EikeiDev/OpenWRT-sing-box-extended)
- [Podkop](https://github.com/itdoginfo/podkop)
- [Zapret-Manager](https://github.com/StressOzz/Zapret-Manager)
- [runetfreedom](https://github.com/runetfreedom/russia-v2ray-rules-dat)
