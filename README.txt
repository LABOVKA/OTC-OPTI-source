OTC OPTI LAUNCHER v7.1 — ИНСТРУКЦИЯ
====================================

1) СБОРКА ПРОГРАММЫ:
   - Дважды нажмите  1-SESTAVIT.bat  - он соберёт лаунчер и оптимизатор.
   - Готовая программа:  dist\OTC-OPTI.exe  (именно её отдавайте клиентам).
   - На странице «Оптимизация» кнопка «Игровой профиль» выбирает поддерживаемые безопасные настройки FPS и отклика; эффект зависит от ПК.

2) ИНСТАЛЯТОР:
   - Сначала соберите OTC-OPTI.exe, затем запустите 3-VYTVORIT-SETUP.bat.
   - Готовый установщик: dist\OTC-OPTI-Setup-Admin.exe. Для сборки нужны Python 3 и компилятор .NET Framework 4.x, входящий в Windows.
   - Установщик запрашивает подтверждение прав администратора, но устанавливает программу только для текущего пользователя в %LOCALAPPDATA%\Programs\OTC OPTI.
   - Setup создаёт ярлыки на рабочем столе и в меню «Пуск» и запись удаления в настройках Windows.
   - Пользовательская лицензия, настройки и цветовые конфиги в %APPDATA%\OtcLoader не удаляются при установке или деинсталляции.
   - «Выразительность цвета» в «Цветах» использует плавную S-кривую системной гамма-коррекции; это не настоящая RGB-насыщенность или GPU-шейдер. Кнопка пресета ставит 125%. Фильтр действует на основной дисплей.

3) СОЗДАНИЕ КЛЮЧЕЙ ДЛЯ КЛИЕНТОВ:
   - PLUS:  python keygen.py make --days 30 --tier plus
   - ULTRA: python keygen.py make --days 30 --tier ultra
   - Бессрочный ключ: python keygen.py make --lifetime --tier plus  (или --tier ultra)
   - Срок задаётся через --days или --hours; Discord-привязка задаётся через --discord.
   - Цены на сайте: PLUS / Premium — 15 ₽ за день, 115 ₽ за месяц, 315 ₽ бессрочно; ULTRA — 25 ₽ за день, 250 ₽ за месяц, 650 ₽ бессрочно.
   - PLUS открывает примерно 55% всех оптимизаций вместе с FREE: отбираются варианты с меньшим воздействием; самые мощные, тестовые и Advanced-настройки остаются в ULTRA.
   - PLUS открывает страницу цветов и конфиги, но не цветовой контраст. ULTRA открывает все функции.
   - Старые ключи Premium продолжают работать с доступом ULTRA.
   - Discord ID покупателя: если указать его ID, ключ будет работать ТОЛЬКО на его аккаунте.
     (Если нажать Enter, ключ будет работать для любого аккаунта).

4) AUTOAKTUALIZACE PRO UŽ ROZDANÉ EXE:
   - Potřebuješ statický HTTPS hosting. Před prvním vydáním spusť příkaz se svou adresou:
     python keygen.py publish --version 7.2 --base-url "https://tvuj-web.cz/otc-updates" --changelog "Popis aktualizace"
   - Příkaz nastaví adresu a verzi v Program.cs a připraví dist\updates. Nahraj odtud payload.ps1 a potom version.json do stejné složky na HTTPS hostingu.
   - Sestav EXE přes 1-SESTAVIT.bat a jednou ho rozešli lidem. Tento loader pak při spuštění kontroluje aktualizace.
   - Pro další verzi zvyš číslo (např. 7.3), znovu spusť publish a nahraj oba soubory stejným způsobem. Nové EXE už posílat nemusíš.
   - Manifest obsahuje verzi, HTTPS adresu payloadu a SHA-256; loader ověří adresu a kontrolní součet před instalací.
   - Aktualizuje se obsah aplikace (payload.ps1), nikoli samotný OTC-OPTI.exe. Změny C# loaderu nebo licencování vyžadují nové EXE.

5) ССЫЛКИ В ПРИЛОЖЕНИИ:
   - python keygen.py links --discord https://discord.gg/XXXX --web https://vash-sait.com
   - После изменения ссылок пересоберите программу (1-SESTAVIT.bat).

6) ПРОВЕРКА И ЛОГИ:
   - Проверка системы:  python keygen.py check
   - Логи работы:  %APPDATA%\OtcLoader\launch.log  (Win+R, вставить путь).

7) ЦВЕТА И КОНФИГИ:
   - Настройка цветового фильтра и сохранение/загрузка именованных конфигов доступны в PLUS и ULTRA; цветовой контраст — только в ULTRA.
   - Конфиги хранятся в %APPDATA%\OtcLoader\color-profiles.
   - Фильтр использует системную гамма-кривую и влияет на весь основной дисплей, а не только на Rust.
     Исходные цвета восстанавливаются при закрытии программы или окончании лицензии; доступна и ручная кнопка восстановления.
   - «Выразительность цвета» — плавная S-кривая гамма-коррекции, не настоящая RGB/GPU-насыщенность. Старые конфиги с полем Saturation остаются совместимыми.
   - Чёрный hologram preview — только декоративный элемент OTC OPTI; он не меняет изображение игры и не создаёт игровой оверлей.
   - Для разрешённых приложений есть отдельный ReShade FX shader `shaders\OTC-Vivid.fx` с RGB-насыщенностью, выборочной vibrance, hue и контрастом. OTC OPTI его не устанавливает; не загружай его в Rust и не обходи ограничения EAC.

Исходный код распространяется по MIT (см. LICENSE); private.pem и keys.log хранятся вне папки проекта в %LOCALAPPDATA%\OTC OPTI\Signing и не должны публиковаться.
