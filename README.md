# 📦 SBSM — Sing-Box Subscription Manager

Автоматическое управление подписками на прокси-серверы для **sing-box** на OpenWrt.

**Версия:** 0.4.1

---

## 🚀 Быстрый старт

### Для Podkop (UCI)
```sh
./sbsm_podkop.sh update
```

### Для sing-box extended (прямой config.json)
```sh
./sbsm_extended.sh update
```

---

## 📋 Режимы работы

| Режим | Описание |
|-------|----------|
| **by_country** | Группировка прокси по странам (emoji-флаг) |
| **russia_inside** | RU отдельно, остальные вместе + SRS маршрутизация |
| **subscription** | Все прокси в одну группу |

---

## 🔧 Команды

| Команда | Описание |
|---------|----------|
| `fetch` | Скачать подписки с валидацией |
| `build` | Сгенерировать config.json |
| `update` | Полный цикл: fetch + build + restart |
| `status` | Статус системы |
| `validate` | Валидация всех прокси |
| `mode [MODE]` | Режим группировки |
| `sb_mode [MODE]` | Режим sing-box: `tun` / `tproxy_fakeip` |
| `subs list/add/remove` | Управление подписками |
| `menu` | Интерактивное меню |

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

## 📄 Благодарности

- [sing-box-extended](https://github.com/shtorm-7/sing-box-extended)
- [Podkop](https://github.com/EikeiDev/podkop)
- [runetfreedom rules](https://github.com/runetfreedom/russia-v2ray-rules-dat)
