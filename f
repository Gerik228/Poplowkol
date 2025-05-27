(function () {
    var logId = $v('P49_LOG_ID');
    if (!logId) return;

    var url = '/ords/web_rnd/l/xv/' + logId;
    var logoutSent = false;

    function sendLogout() {
        if (logoutSent) return;
        logoutSent = true;
        // Пробуем sendBeacon
        if (navigator.sendBeacon) {
            navigator.sendBeacon(url, '');
        } else if (window.fetch) {
            fetch(url, {method: 'POST', keepalive: true});
        }
    }

    // Основные события
    window.addEventListener('pagehide', sendLogout, {capture:true});
    window.addEventListener('beforeunload', sendLogout, {capture:true});
    document.addEventListener('visibilitychange', function(){
        if (document.visibilityState === 'hidden') sendLogout();
    });

    // Таймер бездействия
    var idleTimer;
    function resetIdle() {
        clearTimeout(idleTimer);
        idleTimer = setTimeout(sendLogout, 300000);
    }
    ['mousemove','keydown','click','touchstart'].forEach(function(evt){
        document.addEventListener(evt, resetIdle, {passive:true});
    });
    resetIdle();
})();
