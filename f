(function () {
    // Получаем ID для лога
    const logId = $v('P49_LOG_ID');
    if (!logId) return;

    const url = '/ords/web_rnd/l/xv/' + logId;
    let logoutSent = false;

    // Универсальная отправка выхода
    function sendLogout() {
        if (logoutSent) return;
        logoutSent = true;

        // Сначала пробуем sendBeacon
        let ok = false;
        if (navigator.sendBeacon) {
            try {
                ok = navigator.sendBeacon(url, 'x'); // минимальное тело
            } catch (e) {}
        }
        // Если sendBeacon не сработал, fallback на fetch
        if (!ok && window.fetch) {
            try {
                fetch(url, {
                    method: 'POST',
                    body: 'x',
                    keepalive: true,
                    headers: {'Content-Type': 'text/plain'}
                });
            } catch (e) {}
        }
    }

    // Основные события жизненного цикла страницы
    window.addEventListener('pagehide', sendLogout, {capture: true});
    window.addEventListener('beforeunload', sendLogout, {capture: true});
    document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') sendLogout();
    });

    // Для SPA-навигации (APEX)
    document.addEventListener('apexnavigationbegin', evt => {
        if (evt.detail && typeof evt.detail.defer === 'function') {
            evt.detail.defer('resume', () => {
                sendLogout();
                setTimeout(() => evt.detail.resume(), 120);
            });
        } else {
            sendLogout();
        }
    });

    // Таймер бездействия (5 минут)
    let idleTimer;
    function resetIdle() {
        clearTimeout(idleTimer);
        idleTimer = setTimeout(sendLogout, 300000); // 5 минут
    }

    // Сброс таймера по активности пользователя
    ['pointermove', 'keydown', 'click', 'touchstart'].forEach(evt => {
        document.addEventListener(evt, resetIdle, {passive: true});
    });
    resetIdle();

})();
