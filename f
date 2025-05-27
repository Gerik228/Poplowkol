document.body.style.overflow = 'hidden';
(function(){
    const logId = $v('P40_LOG_ID');
    if (!logId) return;
    
    const logoutUrl = `/ords/web_rmd/l/a/${logId}`;
    let sent = false;

    function sendLogout(source) {
        if (sent) return;
        sent = true;
        const logData = `LOGOUT from ${source} at ${new Date().toLocaleTimeString()}`;
        
        // Отправляем данные в теле запроса
        navigator.sendBeacon(logoutUrl, logData);
    }

    let idleTimer;
    function resetIdleTimer() {
        clearTimeout(idleTimer);
        // 5 минут = 300000 мс
        idleTimer = setTimeout(() => sendLogout('idle:5m'), 300000);
    }

    // Обработчики пользовательской активности
    ['mousemove', 'keydown', 'click', 'touchstart'].forEach(event => {
        document.addEventListener(event, resetIdleTimer, { passive: true });
    });

    resetIdleTimer();
    
    // Основной обработчик для обнаружения покидания страницы
    document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') {
            sendLogout('visibilitychange');
        }
    });

    // Дополнительные обработчики для совместимости
    window.addEventListener('pagehide', () => sendLogout('pagehide'));
    window.addEventListener('beforeunload', () => sendLogout('beforeunload'));
    
    // Обработчик APEX-специфичных событий навигации
    document.addEventListener('oraapexnavigation', (evt) => {
        sendLogout('apex-navigation');
    });
})();
