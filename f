(function () {
  /* ----------------------------------------------------------
   * 1. Базовые данные
   * ---------------------------------------------------------- */
  const logId = $v('P49_LOG_ID');               // скрытый элемент-сессия
  if (!logId) { console.error('P49_LOG_ID не найден'); return; }

  const url = `/ords/web_rnd/1/x/${encodeURIComponent(logId)}`;
  const headers = { 'Content-Type': 'text/plain' };
  const body    = 'logout';                     // непустое тело для sendBeacon

  /* ----------------------------------------------------------
   * 2. Отправка запроса (единственная точка)
   * ---------------------------------------------------------- */
  function sendLogout(tag) {
    // чтобы не отправлять повторно (между табами тоже)
    const key = `${tag}-${logId}`;
    if (sessionStorage.getItem(key)) return;
    sessionStorage.setItem(key, 'sent');

    console.log(`Отправка лога [${tag}]:`, url);

    // a) sendBeacon (идеально для закрытия вкладки)
    if (navigator.sendBeacon?.(url, new Blob([body], { type: 'text/plain' }))) {
      return;
    }

    // b) fetch c keepalive
    if (window.fetch) {
      fetch(url, { method: 'POST', body, headers, keepalive: true })
        .catch(err => console.error(`fetch-ошибка [${tag}]`, err));
      return;
    }

    // c) синхронный XHR (старые браузеры)
    try {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', url, false);    // false = синхронно, успевает до unload
      xhr.setRequestHeader('Content-Type', 'text/plain');
      xhr.send(body);
    } catch (err) {
      console.error(`XHR-ошибка [${tag}]`, err);
    }
  }

  /* ----------------------------------------------------------
   * 3. Навигация / закрытие вкладки
   * ---------------------------------------------------------- */
  const navHandler = () => sendLogout('navigation');
  window.addEventListener('pagehide',     navHandler, { capture: true });
  window.addEventListener('beforeunload', navHandler, { capture: true });
  window.addEventListener('unload',       navHandler, { capture: true });

  // Если вкладка теряет фокус (м.б. PWA / iOS)
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') navHandler();
  });

  /* ----------------------------------------------------------
   * 4. Таймер бездействия
   * ---------------------------------------------------------- */
  const idleTimeout = 30_000;   // 30 секунд; измените при необходимости
  let idleTimer;

  function resetIdleTimer() {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => sendLogout('idle'), idleTimeout);
  }

  ['mousemove', 'keydown', 'click', 'touchstart', 'scroll'].forEach(evt =>
    document.addEventListener(evt, resetIdleTimer, { passive: true })
  );

  resetIdleTimer();             // старт при загрузке
  console.log('Система мониторинга запущена');
})();