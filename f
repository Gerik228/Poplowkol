смотри, этот код должен отрабатывать в oracle apex 23.1 
execute when page load
так же на фото код рестфул модуля .
просто тот код , который ты отправил выше не работают

Спасибо за фото и детали!  
Вижу, что у тебя REST-модуль, который обновляет таблицу BI_PORTAL_AUDIT_LOG, выставляет logout_time и duration_sec.  
Также вижу, что duration_sec сейчас закомментирован и выставляется в null.

Давай разберём по шагам, чтобы всё работало именно в Oracle APEX 23.1 при загрузке страницы (execute when page load):

---

## 1. Исправленный PL/SQL для REST-модуля

Твой PL/SQL можно упростить и сделать корректный расчёт duration_sec в секундах:

```sql
BEGIN
  UPDATE BI_PORTAL_AUDIT_LOG
     SET logout_time = SYSTIMESTAMP,
         duration_sec = ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(login_time AS DATE)) * 86400)
   WHERE log_id = :log_id
     AND logout_time IS NULL;
  COMMIT;
END;
```

- `SYSTIMESTAMP` — актуальное время выхода.
- `duration_sec` — разница между SYSTIMESTAMP и login_time в секундах.
- `:log_id` — параметр, который ты должен передавать из клиента.

---

## 2. Как правильно вызвать REST-модуль из APEX при уходе пользователя

В APEX **execute when page load** не сработает для сценария "пользователь покидает страницу".  
Тебе нужно вызывать REST-модуль именно при уходе пользователя (закрытие, переход, 5 минут idle).

### Вот рабочий JS-код для APEX (вставь в "Function and Global Variable Declaration" или на страницу):

```javascript
(function () {
    // Получаем log_id из элемента страницы (например, скрытое поле P49_LOG_ID)
    var logId = $v('P49_LOG_ID');
    if (!logId) return;

    var url = '/ords/web_rnd/l/xv/' + logId;
    var logoutSent = false;

    function sendLogout() {
        if (logoutSent) return;
        logoutSent = true;
        if (navigator.sendBeacon) {
            try {
                navigator.sendBeacon(url, '');
            } catch (e) {}
        } else if (window.fetch) {
            try {
                fetch(url, {method: 'POST', keepalive: true});
            } catch (e) {}
        }
    }

    // События ухода
    window.addEventListener('pagehide', sendLogout, {capture:true});
    window.addEventListener('beforeunload', sendLogout, {capture:true});
    document.addEventListener('visibilitychange', function(){
        if (document.visibilityState === 'hidden') sendLogout();
    });

    // Idle-таймер 5 минут
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
```

---

## 3. Как это работает

- **log_id** берётся из скрытого поля страницы (например, P49_LOG_ID).
- **url** — путь к твоему REST-модулю (проверь, что он совпадает с тем, что в APEX RESTful).
- **sendLogout** вызывается при любых сценариях ухода или 5 мин бездействия.
- **logoutSent** — защита от повторной отправки.
- **duration_sec** корректно рассчитывается на сервере.

---

## 4. Важно!

- В JS обязательно подставь правильное имя скрытого поля с log_id.
- Если REST-модуль требует авторизации — убедись, что сессия не истекает до отправки запроса.
- Если REST-модуль настроен на POST, то url должен быть вида `/ords/your_schema/your_module/:log_id`.

---

## 5. Проверка

1. Открой страницу, посмотри в консоли, что ошибок нет.
2. Проверь, что при закрытии вкладки или 5 мин бездействия в BI_PORTAL_AUDIT_LOG появляется logout_time и duration_sec.

---

Если не работает — пришли ошибку из консоли браузера или из журнала REST-модуля APEX, помогу доработать!

Цитаты:
[1] 1000004222.jpg https://pplx-res.cloudinary.com/image/upload/v1748389824/user_uploads/26298554/e1f852c9-fce4-4d73-bd4b-4dd4d93e48ed/1000004222.jpg
