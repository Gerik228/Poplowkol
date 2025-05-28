/* ========================================================================
 *  Universal APEX Logout / Idle / Navigation tracker
 *  (c) 2024  — вставьте в “Execute when Page Loads”
 * ====================================================================== */
(function () {

  /* --------------------------------------------------------------------
   * 0. Конфигурация
   * ------------------------------------------------------------------ */
  const ITEM_LOG_ID      = 'P49_LOG_ID';          // hidden-item с ID лога
  const ORDS_PREFIX      = '/ords/web_rnd/1/x/';  // ваш ORDS-модуль и версия
  const IDLE_TIMEOUT_MS  = 3 * 60 * 1000;         // 3 мин бездействия → idle-logout
  const ADD_SCROLL_EVENT = true;                  // true = scroll тоже сбрасывает idle
  const DEBUG            = true;                  // console.log на всю механику
  const AUTH_HEADER      = null;                  // "Bearer <token>" | null

  /* --------------------------------------------------------------------
   * 1. Получаем log_id из сессии
   * ------------------------------------------------------------------ */
  const logId = $v(ITEM_LOG_ID);
  if (!logId) {
    console.error(`[audit] Hidden item ${ITEM_LOG_ID} не найден — скрипт остановлен`);
    return;
  }

  /* --------------------------------------------------------------------
   * 2. Набор URL-ов под разные «причины» выхода
   *    /x/:log_id/:reason  →  :reason = navigation | idle | button | error
   * ------------------------------------------------------------------ */
  const mkUrl = (reason) =>
    `${ORDS_PREFIX}${encodeURIComponent(logId)}/${reason}`;

  /* общий пакет опций для fetch */
  const commonFetch = {
    method   : 'POST',
    body     : 'logout',                       // любые непустые данные
    headers  : { 'Content-Type': 'text/plain' },
    keepalive: true
  };
  if (AUTH_HEADER) commonFetch.headers['Authorization'] = AUTH_HEADER;

  const bodyBlob = new Blob(['logout'], { type: 'text/plain' }); // для sendBeacon

  /* --------------------------------------------------------------------
   * 3. Отправляем запрос ровно ОДИН раз по каждому событию (idle/nav/btn)
   * ------------------------------------------------------------------ */
  const sentFlags = Object.create(null);        // in-memory тоже (на случай refresh)
  function send(reason) {
    const flag = `${reason}-${logId}`;
    if (sentFlags[flag] || sessionStorage.getItem(flag)) return;   // защита 2-уровневая
    sentFlags[flag] = true;
    sessionStorage.setItem(flag, '1');

    const url = mkUrl(reason);
    DEBUG && console.log(`[audit] send '${reason}' →`, url);

    /* A) sendBeacon — идеальный вариант закрытия вкладки */
    if (navigator.sendBeacon) {
      try {
        if (navigator.sendBeacon(url, bodyBlob)) return;
      } catch (_) {/* fallthrough */}
    }

    /* B) fetch c keep-alive */
    if (window.fetch) {
      fetch(url, commonFetch).catch(e => DEBUG && console.error('[audit] fetch', e));
      return;
    }

    /* C) Legacy — синхронный XHR */
    try {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', url, false);                        // false — sync
      xhr.setRequestHeader('Content-Type', 'text/plain');
      if (AUTH_HEADER) xhr.setRequestHeader('Authorization', AUTH_HEADER);
      xhr.send('logout');
    } catch (e) { DEBUG && console.error('[audit] xhr', e); }
  }

  /* --------------------------------------------------------------------
   * 4. Навигация / закрытие вкладки
   * ------------------------------------------------------------------ */
  const navExit = () => send('navigation');
  window.addEventListener('pagehide',     navExit, { capture: true });
  window.addEventListener('beforeunload', navExit, { capture: true });
  window.addEventListener('unload',       navExit, { capture: true });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') navExit();
  });

  /* --------------------------------------------------------------------
   * 5. APEX-submit внутри одной вкладки (SPA / PJAX)
   * ------------------------------------------------------------------ */
  document.addEventListener('apexbeforepagesubmit', navExit);

  /* --------------------------------------------------------------------
   * 6. Idle-таймер (бездействие пользователя)
   * ------------------------------------------------------------------ */
  let idleTimer;
  const resetIdle = () => {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => send('idle'), IDLE_TIMEOUT_MS);
  };

  const userEvents = ['mousemove', 'keydown', 'click', 'touchstart'];
  if (ADD_SCROLL_EVENT) userEvents.push('scroll');
  userEvents.forEach(evt =>
    document.addEventListener(evt, resetIdle, { passive: true })
  );
  resetIdle();                                         // старт

  /* --------------------------------------------------------------------
   * 7. Экспортируем хелпер для явной кнопки «Выход»
   * ------------------------------------------------------------------ */
  window.apexAuditLogoutButton = () => send('button');  // используйте в DA/JS

  DEBUG && console.log('[audit] initialised, logId =', logId);
})();