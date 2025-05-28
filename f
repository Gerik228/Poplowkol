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
        if (logoutSent) return;
        logoutSent = true;
        console.log('Отправка лога выхода:', url);

        // Используем sendBeacon или fetch
        if (navigator.sendBeacon) {
            navigator.sendBeacon(url, ' ');
        } else if (window.fetch) {
            fetch(url, { method: 'POST', keepalive: true })
                .catch(error => console.error('Ошибка отправки:', error));
        }

        // Дополнительная защита от повторных отправок
        sessionStorage.setItem('logoutSent', 'true');
    }

    // Обработчики событий завершения сессии
    window.addEventListener('pagehide', sendLogout, { capture: true });
    window.addEventListener('beforeunload', sendLogout, { capture: true });
    document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'hidden') {
            sendLogout();
        }
    });

    // Таймер бездействия (30 секунд)
    var idleTimer;
    var idleTimeout = 30000; // 30 секунд

    function resetIdle() {
        console.log('Активность: таймер сброшен');
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

    // Инициализация таймера
    resetIdle();
    console.log('Мониторинг бездействия запущен');
})();