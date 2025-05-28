(function () {
    var logId = $v('P49_LOG_ID');
    if (!logId) {
        console.error('P49_LOG_ID не найден');
        return;
    }
    var url = '/ords/web_rnd/1/x/' + logId;
    var logoutSent = false;

    // Функция отправки лога выхода
    function sendLogout() {
        if (logoutSent || sessionStorage.getItem('logoutSent')) return;
        logoutSent = true;
        console.log('Отправка лога выхода:', url);

        // Приоритет: sendBeacon -> fetch с keepalive -> синхронный XMLHttpRequest
        try {
            if (navigator.sendBeacon) {
                navigator.sendBeacon(url, ' ');
            } else if (window.fetch) {
                fetch(url, { method: 'POST', keepalive: true })
                    .catch(error => console.error('Ошибка fetch:', error));
            } else {
                // Резервный вариант для старых браузеров
                var xhr = new XMLHttpRequest();
                xhr.open('POST', url, false); // Синхронный запрос
                xhr.send();
            }
        } catch (error) {
            console.error('Ошибка отправки:', error);
        }

        sessionStorage.setItem('logoutSent', 'true');
    }

    // Обработчики событий закрытия/перехода
    window.addEventListener('pagehide', sendLogout, { capture: true });
    window.addEventListener('beforeunload', sendLogout, { capture: true });
    window.addEventListener('unload', sendLogout, { capture: true }); // Добавлено unload
    document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'hidden') {
            sendLogout();
        }
    });

    // Таймер бездействия (30 секунд)
    var idleTimer;
    var idleTimeout = 30000;

    function resetIdle() {
        clearTimeout(idleTimer);
        idleTimer = setTimeout(() => {
            console.log('Таймер бездействия: выход');
            sendLogout();
        }, idleTimeout);
    }

    // Слушатели событий активности
    ['mousemove', 'keydown', 'click', 'touchstart'].forEach(function (evt) {
        document.addEventListener(evt, resetIdle, { passive: true });
    });

    // Инициализация
    resetIdle();
    console.log('Мониторинг активности запущен');
})();