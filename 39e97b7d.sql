
-- =====================================================================
-- ЭТАП 4: ПЛАНИРОВЩИК ЗАДАЧ И СИСТЕМА МОНИТОРИНГА
-- =====================================================================

-- 4.1. Создание ежедневного задания синхронизации
BEGIN
    -- Удаляем существующее задание, если оно есть
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'AD_SYNC_SERVICE.DAILY_AD_SYNC');
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;

    -- Создаем ежедневное задание синхронизации
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'AD_SYNC_SERVICE.DAILY_AD_SYNC',
        job_type        => 'PLSQL_BLOCK', 
        job_action      => 'BEGIN AD_SYNC_SERVICE.PKG_AD_SYNC.sync_daily_full; END;',
        start_date      => TRUNC(SYSDATE) + INTERVAL '2' HOUR, -- Начинаем в 02:00
        repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0;BYSECOND=0',
        end_date        => NULL,
        enabled         => TRUE,
        comments        => 'Daily Active Directory synchronization job'
    );

    -- Настраиваем атрибуты задания
    DBMS_SCHEDULER.SET_ATTRIBUTE(
        name      => 'AD_SYNC_SERVICE.DAILY_AD_SYNC',
        attribute => 'MAX_FAILURES',
        value     => 3
    );

    DBMS_SCHEDULER.SET_ATTRIBUTE(
        name      => 'AD_SYNC_SERVICE.DAILY_AD_SYNC',
        attribute => 'MAX_RUNS',
        value     => NULL  -- Неограниченное количество запусков
    );

    DBMS_SCHEDULER.SET_ATTRIBUTE(
        name      => 'AD_SYNC_SERVICE.DAILY_AD_SYNC',
        attribute => 'RESTARTABLE',
        value     => TRUE
    );

    -- Включаем логирование
    DBMS_SCHEDULER.SET_ATTRIBUTE(
        name      => 'AD_SYNC_SERVICE.DAILY_AD_SYNC',
        attribute => 'LOGGING_LEVEL',
        value     => DBMS_SCHEDULER.LOGGING_RUNS
    );

    DBMS_OUTPUT.PUT_LINE('Ежедневное задание синхронизации создано успешно');
END;
/

-- 4.2. Создание задания для мониторинга состояния
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'AD_SYNC_SERVICE.HOURLY_HEALTH_CHECK');
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'AD_SYNC_SERVICE.HOURLY_HEALTH_CHECK',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN AD_SYNC_SERVICE.PKG_AD_MONITORING.check_sync_health; END;',
        start_date      => SYSDATE,
        repeat_interval => 'FREQ=HOURLY;BYMINUTE=30',
        enabled         => TRUE,
        comments        => 'Hourly health check for AD synchronization'
    );

    DBMS_OUTPUT.PUT_LINE('Задание мониторинга создано успешно');
END;
/

-- 4.3. Пакет для мониторинга и уведомлений
CREATE OR REPLACE PACKAGE AD_SYNC_SERVICE.PKG_AD_MONITORING AS
    PROCEDURE check_sync_health;
    PROCEDURE send_notification(
        p_subject IN VARCHAR2,
        p_message IN CLOB,
        p_severity IN VARCHAR2 DEFAULT 'INFO'
    );
    FUNCTION get_last_sync_status RETURN VARCHAR2;
    FUNCTION get_sync_statistics(p_days IN NUMBER DEFAULT 7) RETURN CLOB;
    PROCEDURE generate_daily_report;
END PKG_AD_MONITORING;
/

CREATE OR REPLACE PACKAGE BODY AD_SYNC_SERVICE.PKG_AD_MONITORING AS

    -- Проверка состояния синхронизации
    PROCEDURE check_sync_health IS
        l_last_sync_date    DATE;
        l_last_sync_status  VARCHAR2(20);
        l_error_count       NUMBER;
        l_message           CLOB;
        l_hours_since_sync  NUMBER;
    BEGIN
        -- Получаем информацию о последней синхронизации
        SELECT 
            MAX(created_date),
            MAX(CASE WHEN sync_status = 'SUCCESS' THEN sync_status ELSE 'ERROR' END),
            COUNT(CASE WHEN sync_status = 'ERROR' THEN 1 END)
        INTO 
            l_last_sync_date,
            l_last_sync_status,
            l_error_count
        FROM ad_sync_log 
        WHERE sync_type = 'FULL_SYNC' 
          AND sync_operation IN ('DAILY_COMPLETE', 'DAILY_FAILED')
          AND created_date >= SYSDATE - 2;

        l_hours_since_sync := ROUND((SYSDATE - l_last_sync_date) * 24, 1);

        -- Проверяем различные условия
        IF l_last_sync_date IS NULL THEN
            l_message := 'КРИТИЧЕСКАЯ ОШИБКА: Синхронизация AD никогда не запускалась!';
            send_notification('AD Sync - КРИТИЧЕСКАЯ ОШИБКА', l_message, 'CRITICAL');

        ELSIF l_hours_since_sync > 26 THEN
            l_message := 'ПРЕДУПРЕЖДЕНИЕ: Последняя синхронизация AD была ' || 
                        l_hours_since_sync || ' часов назад (' || 
                        TO_CHAR(l_last_sync_date, 'DD.MM.YYYY HH24:MI') || ')';
            send_notification('AD Sync - ПРОПУЩЕНА СИНХРОНИЗАЦИЯ', l_message, 'WARNING');

        ELSIF l_last_sync_status = 'ERROR' THEN
            l_message := 'ОШИБКА: Последняя синхронизация AD завершилась с ошибкой. ' ||
                        'Время: ' || TO_CHAR(l_last_sync_date, 'DD.MM.YYYY HH24:MI') || CHR(10) ||
                        'Проверьте логи для получения подробной информации.';
            send_notification('AD Sync - ОШИБКА СИНХРОНИЗАЦИИ', l_message, 'ERROR');

        ELSIF l_error_count > 0 THEN
            l_message := 'ПРЕДУПРЕЖДЕНИЕ: За последние 2 дня обнаружено ' || 
                        l_error_count || ' ошибок в процессе синхронизации AD.';
            send_notification('AD Sync - ЕСТЬ ОШИБКИ', l_message, 'WARNING');
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            l_message := 'Ошибка при проверке состояния синхронизации: ' || SQLERRM;
            send_notification('AD Sync - ОШИБКА МОНИТОРИНГА', l_message, 'ERROR');
    END check_sync_health;

    -- Отправка уведомлений
    PROCEDURE send_notification(
        p_subject IN VARCHAR2,
        p_message IN CLOB,
        p_severity IN VARCHAR2 DEFAULT 'INFO'
    ) IS
        l_email_list VARCHAR2(1000);
    BEGIN
        -- Получаем список email для уведомлений
        SELECT config_value
        INTO l_email_list
        FROM ad_sync_config
        WHERE config_name = 'EMAIL_NOTIFICATIONS'
          AND is_active = 'Y';

        -- Логируем уведомление
        INSERT INTO ad_sync_log (
            sync_session_id,
            sync_type,
            sync_operation,
            object_identifier,
            sync_status,
            start_time,
            error_message,
            detailed_log
        ) VALUES (
            'NOTIFICATION_' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'),
            'MONITORING',
            'NOTIFICATION',
            p_severity,
            'SUCCESS',
            SYSTIMESTAMP,
            p_subject,
            p_message
        );

        COMMIT;

        -- Здесь можно добавить реальную отправку email через UTL_MAIL или APEX_MAIL
        DBMS_OUTPUT.PUT_LINE('УВЕДОМЛЕНИЕ [' || p_severity || ']: ' || p_subject);
        DBMS_OUTPUT.PUT_LINE(p_message);

    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Не прерываем выполнение из-за проблем с уведомлениями
    END send_notification;

    -- Получение статуса последней синхронизации
    FUNCTION get_last_sync_status RETURN VARCHAR2 IS
        l_status VARCHAR2(100);
    BEGIN
        SELECT 
            'Последняя синхронизация: ' || 
            TO_CHAR(MAX(created_date), 'DD.MM.YYYY HH24:MI') || 
            ' (Статус: ' || 
            MAX(sync_status) || 
            ', Записей: ' || 
            MAX(records_processed) || ')'
        INTO l_status
        FROM ad_sync_log
        WHERE sync_type = 'FULL_SYNC'
          AND sync_operation IN ('DAILY_COMPLETE', 'DAILY_FAILED')
          AND created_date >= SYSDATE - 7;

        RETURN NVL(l_status, 'Синхронизация не выполнялась');
    END get_last_sync_status;

    -- Получение статистики синхронизации
    FUNCTION get_sync_statistics(p_days IN NUMBER DEFAULT 7) RETURN CLOB IS
        l_stats CLOB;
    BEGIN
        SELECT 
            'Статистика синхронизации за последние ' || p_days || ' дней:' || CHR(10) ||
            '- Всего синхронизаций: ' || COUNT(*) || CHR(10) ||
            '- Успешных: ' || COUNT(CASE WHEN sync_status = 'SUCCESS' THEN 1 END) || CHR(10) ||
            '- С ошибками: ' || COUNT(CASE WHEN sync_status = 'ERROR' THEN 1 END) || CHR(10) ||
            '- Всего обработано записей: ' || SUM(NVL(records_processed, 0)) || CHR(10) ||
            '- Средняя длительность: ' || ROUND(AVG(duration_seconds), 1) || ' сек' || CHR(10) ||
            '- Максимальная длительность: ' || MAX(duration_seconds) || ' сек'
        INTO l_stats
        FROM ad_sync_log
        WHERE sync_type = 'FULL_SYNC'
          AND created_date >= SYSDATE - p_days;

        RETURN l_stats;
    END get_sync_statistics;

    -- Генерация ежедневного отчета
    PROCEDURE generate_daily_report IS
        l_report CLOB;
        l_user_count NUMBER;
        l_group_count NUMBER;
        l_last_sync_status VARCHAR2(20);
    BEGIN
        -- Получаем статистику
        SELECT COUNT(*) INTO l_user_count FROM ad_users WHERE sync_status = 'ACTIVE';
        SELECT COUNT(*) INTO l_group_count FROM ad_groups WHERE sync_status = 'ACTIVE';

        SELECT MAX(sync_status) 
        INTO l_last_sync_status
        FROM ad_sync_log 
        WHERE sync_type = 'FULL_SYNC' 
          AND created_date >= TRUNC(SYSDATE);

        -- Формируем отчет
        l_report := '=== ЕЖЕДНЕВНЫЙ ОТЧЕТ AD СИНХРОНИЗАЦИИ ===' || CHR(10) ||
                   'Дата: ' || TO_CHAR(SYSDATE, 'DD.MM.YYYY') || CHR(10) || CHR(10) ||
                   '1. Текущее состояние:' || CHR(10) ||
                   '   - Активных пользователей: ' || l_user_count || CHR(10) ||
                   '   - Активных групп: ' || l_group_count || CHR(10) ||
                   '   - Статус последней синхронизации: ' || NVL(l_last_sync_status, 'НЕТ ДАННЫХ') || CHR(10) || CHR(10) ||
                   '2. ' || get_sync_statistics(1) || CHR(10) || CHR(10) ||
                   '3. Статистика за неделю:' || CHR(10) ||
                   get_sync_statistics(7);

        -- Отправляем отчет
        send_notification('AD Sync - Ежедневный отчет', l_report, 'INFO');

    END generate_daily_report;

END PKG_AD_MONITORING;
/

-- 4.4. Создание представлений для мониторинга
CREATE OR REPLACE VIEW AD_SYNC_SERVICE.V_AD_SYNC_DASHBOARD AS
SELECT 
    'ПОСЛЕДНЯЯ_СИНХРОНИЗАЦИЯ' as metric_name,
    TO_CHAR(MAX(created_date), 'DD.MM.YYYY HH24:MI') as metric_value,
    CASE 
        WHEN MAX(created_date) < SYSDATE - 1.1 THEN 'CRITICAL'
        WHEN MAX(created_date) < SYSDATE - 1.0 THEN 'WARNING'
        ELSE 'OK'
    END as status
FROM ad_sync_log 
WHERE sync_type = 'FULL_SYNC' AND sync_operation = 'DAILY_COMPLETE'
UNION ALL
SELECT 
    'АКТИВНЫХ_ПОЛЬЗОВАТЕЛЕЙ' as metric_name,
    TO_CHAR(COUNT(*)) as metric_value,
    CASE 
        WHEN COUNT(*) = 0 THEN 'CRITICAL'
        WHEN COUNT(*) < 10 THEN 'WARNING'
        ELSE 'OK'
    END as status
FROM ad_users 
WHERE sync_status = 'ACTIVE'
UNION ALL
SELECT 
    'ОШИБОК_ЗА_СУТКИ' as metric_name,
    TO_CHAR(COUNT(*)) as metric_value,
    CASE 
        WHEN COUNT(*) > 10 THEN 'CRITICAL'
        WHEN COUNT(*) > 0 THEN 'WARNING'
        ELSE 'OK'
    END as status
FROM ad_sync_log 
WHERE sync_status = 'ERROR' AND created_date >= SYSDATE - 1;

-- 4.5. Создание отчета по синхронизации для APEX
CREATE OR REPLACE VIEW AD_SYNC_SERVICE.V_AD_SYNC_REPORT AS
SELECT 
    l.sync_session_id,
    l.sync_type,
    l.sync_operation,
    l.sync_status,
    l.start_time,
    l.end_time,
    l.duration_seconds,
    l.records_processed,
    l.records_success,
    l.records_error,
    l.error_message,
    CASE l.sync_status
        WHEN 'SUCCESS' THEN 'success'
        WHEN 'ERROR' THEN 'danger'
        WHEN 'WARNING' THEN 'warning'
        ELSE 'info'
    END as status_class
FROM ad_sync_log l
WHERE l.created_date >= SYSDATE - 30  -- Последние 30 дней
ORDER BY l.created_date DESC;

-- Предоставляем права на объекты схеме APEX
GRANT SELECT ON AD_SYNC_SERVICE.V_AD_SYNC_DASHBOARD TO APEX_230100; -- Замените на вашу схему APEX
GRANT SELECT ON AD_SYNC_SERVICE.V_AD_SYNC_REPORT TO APEX_230100;
GRANT SELECT ON AD_SYNC_SERVICE.AD_USERS TO APEX_230100;
GRANT SELECT ON AD_SYNC_SERVICE.AD_GROUPS TO APEX_230100;
GRANT SELECT ON AD_SYNC_SERVICE.AD_USER_GROUPS TO APEX_230100;
GRANT SELECT ON AD_SYNC_SERVICE.AD_SYNC_LOG TO APEX_230100;
