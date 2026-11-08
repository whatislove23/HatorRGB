# HatorRGB

Нативний застосунок для macOS (рядок меню), що керує підсвіткою **HATOR Gaming Keyboard** (USB `0416:b23c`, чип Nuvoton NUC121).

## Збірка та встановлення

```bash
./build-app.sh --install   # збирає HatorRGB.app, копіює в ~/Applications і запускає
```

Потрібні Xcode / Command Line Tools (Swift 5.9+) і macOS 13+.

## Можливості

- **Ефекти:** Static, Breathe, Wave, Neon, Snake, Reactive, Aurora, Ripple. Можна задати колір, колір фону, яскравість, швидкість, напрямок і режим веселки.
- **Поклавішно:** окреме вікно-редактор. Фарбуєш клавіші кліком або протягуванням, ⌥-клік бере колір з клавіші. Можна залити все одним кольором і зберігати пресети.
- **Калібрування розкладки:** застосунок по черзі запалює кожен із 132 світлодіодів, а ти натискаєш клавішу, що світиться. Так редактор показує точну розкладку саме твоєї моделі.
- **F1–F12 як медіаклавіші** (як на MacBook): яскравість, Mission Control, Spotlight, Launchpad, сон, музика, гучність. Кожну клавішу можна перепризначити. Працює лише для HATOR, через `hidutil` (UserKeyMapping) на рівні драйвера, без дозволів Accessibility. Коли застосунок закривається, перепризначення знімається. Якщо в тебе є Karabiner-Elements, вимкни в ньому перехоплення HATOR (Devices → Modify events = off), бо інакше він обійде це перепризначення.
- Налаштування зберігаються. Після перепідключення клавіатури застосунок сам відновлює підсвітку. Є опція автозапуску при вході в систему.

## CLI

```bash
.build/release/hator effect wave --rainbow --speed 3
.build/release/hator effect static --color 00ffaa --brightness 2
.build/release/hator fill ff0000
.build/release/hator slot 17          # запалити один слот, для дослідження
```

## Протокол

Vendor HID-інтерфейс: usage page `0xFF1B`, report ID 1, output-репорти по 63 байти.

- `07 00 00 00 0E <effect> <brightness 0-4> <speed 0-4> <fg RGB> <bg RGB> <direction> <rainbow>` — встановлює ефект для клавіш. Команда `08` з `0D` замість `0E` робить те саме для логотипа.
- `09 00 00 <msg 0-7> <len> <RGB…>` — поклавішні кольори: 8 повідомлень, разом 6×22 = 132 слоти. Канали насичуються на `0xC1`. Після них надсилається ефект `0x0A` (custom).

Протокол взято з [дослідження Pulsar PCMK TKL](https://gist.github.com/DanielGibson/cd92c5faa6b2e0426351dc44193c6182) і перевірено на HATOR.
