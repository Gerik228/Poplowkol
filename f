(function () {
    var logId = $v('P49_LOG_ID');
    if (!logId) {
        console.error('P49_LOG_ID не найден');
        return;
    }
    var url = '/ords/web_rnd/1/x/' + logId;

    // Отдельные флаги для разных сценариев
    var navigationLogoutSent = false;
    var idleLogoutSent = false;

    // ==============================================
    // 1. Логика для закрытия/перехода на другую страницу
    // ==============================================
    function handleNavigationExit() {
        if (navigationLogoutSent || sessionStorage.getItem('navigationLogoutSent')) return;
        navigationLogoutSent = true;
        console.log('Лог выхода (навигация):', url);

        // Отправка запроса
        try {
            if (navigator.sendBeacon) {
                navigator.sendBeacon(url, ' ');
            } else if (window.fetch) {
                fetch(url, { method: 'POST', keepalive: true });
            } else {
                var xhr = new XMLHttpRequest();
                xhr.open('POST', url, false);
                xhr.send();
            }
        } catch (error) {
            console.error('Ошибка отправки (навигация):', error);
        }

        sessionStorage.setItem('navigationLogoutSent', 'true');
    }

    // Обработчики событий навигации
    window.addEventListener('pagehide', handleNavigationExit, { capture: true });
    window.addEventListener('beforeunload', handleNavigationExit, { capture: true });
    window.addEventListener('unload', handleNavigationExit, { capture: true });
    document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'hidden') {
            handleNavigationExit();
        }
    });

    // ==============================================
    // 2. Логика для таймера бездействия
    // ==============================================
    function handleIdleExit() {
        if (idleLogoutSent || sessionStorage.getItem('idleLogoutSent')) return;
        idleLogoutSent = true;
        console.log('Лог выхода (бездействие):', url);

        // Отправка запроса
        try {
            fetch(url, { method: 'POST' })
                .catch(error => console.error('Ошибка отправки (бездействие):', error));
        } catch (error) {
            console.error('Ошибка:', error);
        }

        sessionStorage.setItem('idleLogoutSent', 'true');
    }

    // Таймер бездействия (30 секунд)
    var idleTimer;
    var idleTimeout = 30000;

    function resetIdleTimer() {
        clearTimeout(idleTimer);
        idleTimer = setTimeout(handleIdleExit, idleTimeout);
        console.log('Таймер сброшен');
    }

    // Слушатели активности
    ['mousemove', 'keydown', 'click', 'touchstart'].forEach(function (evt) {
        document.addEventListener(evt, resetIdleTimer, { passive: true });
    });

    // Инициализация
    resetIdleTimer();
    console.log('Система мониторинга запущена');
})();