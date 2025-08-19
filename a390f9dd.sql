
-- =====================================================================
-- ЭТАП 3: ОСНОВНАЯ ПРОЦЕДУРА СИНХРОНИЗАЦИИ
-- =====================================================================

CREATE OR REPLACE PACKAGE AD_SYNC_SERVICE.PKG_AD_SYNC AS
    -- Константы
    C_SUCCESS CONSTANT VARCHAR2(20) := 'SUCCESS';
    C_ERROR   CONSTANT VARCHAR2(20) := 'ERROR';
    C_WARNING CONSTANT VARCHAR2(20) := 'WARNING';

    -- Типы
    TYPE t_config_rec IS RECORD (
        ldap_host        VARCHAR2(256),
        ldap_port        NUMBER,
        use_ssl          VARCHAR2(1),
        ssl_port         NUMBER,
        base_dn          VARCHAR2(2000),
        user_base_dn     VARCHAR2(2000),
        group_base_dn    VARCHAR2(2000),
        bind_dn          VARCHAR2(2000),
        bind_password    VARCHAR2(256),
        batch_size       NUMBER,
        max_retries      NUMBER,
        timeout_seconds  NUMBER,
        user_filter      VARCHAR2(4000),
        group_filter     VARCHAR2(4000)
    );

    -- Основные процедуры
    PROCEDURE sync_daily_full;
    PROCEDURE sync_users_only;
    PROCEDURE sync_groups_only;
    PROCEDURE sync_memberships_only;

    -- Служебные функции
    FUNCTION get_config RETURN t_config_rec;
    FUNCTION generate_session_id RETURN VARCHAR2;
    PROCEDURE log_sync_event(
        p_session_id     IN VARCHAR2,
        p_sync_type      IN VARCHAR2,
        p_operation      IN VARCHAR2,
        p_object_id      IN VARCHAR2,
        p_status         IN VARCHAR2,
        p_start_time     IN TIMESTAMP,
        p_end_time       IN TIMESTAMP DEFAULT SYSTIMESTAMP,
        p_records_proc   IN NUMBER DEFAULT 0,
        p_records_succ   IN NUMBER DEFAULT 0,
        p_records_err    IN NUMBER DEFAULT 0,
        p_error_msg      IN VARCHAR2 DEFAULT NULL,
        p_detailed_log   IN CLOB DEFAULT NULL
    );

END PKG_AD_SYNC;
/

CREATE OR REPLACE PACKAGE BODY AD_SYNC_SERVICE.PKG_AD_SYNC AS

    -- Получение конфигурации
    FUNCTION get_config RETURN t_config_rec IS
        l_config t_config_rec;
    BEGIN
        SELECT 
            MAX(CASE WHEN config_name = 'HOST' THEN config_value END),
            TO_NUMBER(MAX(CASE WHEN config_name = 'PORT' THEN config_value END)),
            MAX(CASE WHEN config_name = 'USE_SSL' THEN config_value END),
            TO_NUMBER(MAX(CASE WHEN config_name = 'SSL_PORT' THEN config_value END)),
            MAX(CASE WHEN config_name = 'BASE_DN' THEN config_value END),
            MAX(CASE WHEN config_name = 'USER_BASE_DN' THEN config_value END),
            MAX(CASE WHEN config_name = 'GROUP_BASE_DN' THEN config_value END),
            MAX(CASE WHEN config_name = 'BIND_DN' THEN config_value END),
            MAX(CASE WHEN config_name = 'BIND_PASSWORD' THEN config_value END),
            TO_NUMBER(MAX(CASE WHEN config_name = 'BATCH_SIZE' THEN config_value END)),
            TO_NUMBER(MAX(CASE WHEN config_name = 'MAX_RETRIES' THEN config_value END)),
            TO_NUMBER(MAX(CASE WHEN config_name = 'TIMEOUT_SECONDS' THEN config_value END)),
            MAX(CASE WHEN config_name = 'USER_FILTER' THEN config_value END),
            MAX(CASE WHEN config_name = 'GROUP_FILTER' THEN config_value END)
        INTO 
            l_config.ldap_host,
            l_config.ldap_port,
            l_config.use_ssl,
            l_config.ssl_port,
            l_config.base_dn,
            l_config.user_base_dn,
            l_config.group_base_dn,
            l_config.bind_dn,
            l_config.bind_password,
            l_config.batch_size,
            l_config.max_retries,
            l_config.timeout_seconds,
            l_config.user_filter,
            l_config.group_filter
        FROM ad_sync_config 
        WHERE is_active = 'Y' 
          AND config_group IN ('LDAP', 'SYNC', 'FILTERS');

        RETURN l_config;
    END get_config;

    -- Генерация ID сессии синхронизации
    FUNCTION generate_session_id RETURN VARCHAR2 IS
    BEGIN
        RETURN 'SYNC_' || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') || '_' || 
               LPAD(DBMS_RANDOM.VALUE(1000, 9999), 4, '0');
    END generate_session_id;

    -- Логирование событий синхронизации
    PROCEDURE log_sync_event(
        p_session_id     IN VARCHAR2,
        p_sync_type      IN VARCHAR2,
        p_operation      IN VARCHAR2,
        p_object_id      IN VARCHAR2,
        p_status         IN VARCHAR2,
        p_start_time     IN TIMESTAMP,
        p_end_time       IN TIMESTAMP DEFAULT SYSTIMESTAMP,
        p_records_proc   IN NUMBER DEFAULT 0,
        p_records_succ   IN NUMBER DEFAULT 0,
        p_records_err    IN NUMBER DEFAULT 0,
        p_error_msg      IN VARCHAR2 DEFAULT NULL,
        p_detailed_log   IN CLOB DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO ad_sync_log (
            sync_session_id,
            sync_type,
            sync_operation,
            object_identifier,
            sync_status,
            start_time,
            end_time,
            duration_seconds,
            records_processed,
            records_success,
            records_error,
            error_message,
            detailed_log
        ) VALUES (
            p_session_id,
            p_sync_type,
            p_operation,
            p_object_id,
            p_status,
            p_start_time,
            p_end_time,
            EXTRACT(SECOND FROM (p_end_time - p_start_time)),
            p_records_proc,
            p_records_succ,
            p_records_err,
            p_error_msg,
            p_detailed_log
        );
        COMMIT;
    END log_sync_event;

    -- Синхронизация пользователей
    PROCEDURE sync_users_only IS
        l_config        t_config_rec;
        l_session_id    VARCHAR2(50);
        l_start_time    TIMESTAMP;
        l_session       DBMS_LDAP.session;
        l_retval        PLS_INTEGER;
        l_message       DBMS_LDAP.message;
        l_entry         DBMS_LDAP.message;
        l_attrs         DBMS_LDAP.string_collection;
        l_attr_name     VARCHAR2(256);
        l_ber_element   DBMS_LDAP.ber_element;
        l_vals          DBMS_LDAP.string_collection;

        -- Переменные для данных пользователя
        l_sam_account   VARCHAR2(256);
        l_upn           VARCHAR2(256);
        l_dn            VARCHAR2(2000);
        l_display_name  VARCHAR2(256);
        l_given_name    VARCHAR2(256);
        l_surname       VARCHAR2(256);
        l_email         VARCHAR2(256);
        l_department    VARCHAR2(256);
        l_title         VARCHAR2(256);
        l_manager_dn    VARCHAR2(2000);
        l_phone         VARCHAR2(50);
        l_mobile        VARCHAR2(50);
        l_office        VARCHAR2(256);
        l_company       VARCHAR2(256);
        l_employee_id   VARCHAR2(50);
        l_object_guid   RAW(16);

        l_processed     NUMBER := 0;
        l_success       NUMBER := 0;
        l_errors        NUMBER := 0;
        l_error_msg     VARCHAR2(4000);

    BEGIN
        l_config := get_config();
        l_session_id := generate_session_id();
        l_start_time := SYSTIMESTAMP;

        -- Логируем начало синхронизации
        log_sync_event(
            p_session_id => l_session_id,
            p_sync_type => 'USERS',
            p_operation => 'SYNC_START',
            p_object_id => 'BULK',
            p_status => 'SUCCESS',
            p_start_time => l_start_time
        );

        -- Помечаем всех пользователей как неактивных перед синхронизацией
        UPDATE ad_users SET sync_status = 'INACTIVE', last_sync_date = SYSDATE;

        BEGIN
            -- Инициализация LDAP соединения
            l_session := DBMS_LDAP.init(
                hostname => l_config.ldap_host, 
                portnum => CASE WHEN l_config.use_ssl = 'Y' 
                              THEN l_config.ssl_port 
                              ELSE l_config.ldap_port END
            );

            -- Аутентификация
            l_retval := DBMS_LDAP.simple_bind_s(
                ld => l_session,
                dn => l_config.bind_dn,
                passwd => l_config.bind_password
            );

            -- Определяем атрибуты для извлечения
            l_attrs(1) := 'sAMAccountName';
            l_attrs(2) := 'userPrincipalName';
            l_attrs(3) := 'distinguishedName';
            l_attrs(4) := 'displayName';
            l_attrs(5) := 'givenName';
            l_attrs(6) := 'sn';
            l_attrs(7) := 'mail';
            l_attrs(8) := 'department';
            l_attrs(9) := 'title';
            l_attrs(10) := 'manager';
            l_attrs(11) := 'telephoneNumber';
            l_attrs(12) := 'mobile';
            l_attrs(13) := 'physicalDeliveryOfficeName';
            l_attrs(14) := 'company';
            l_attrs(15) := 'employeeID';
            l_attrs(16) := 'objectGUID';

            -- Поиск пользователей
            l_retval := DBMS_LDAP.search_s(
                ld => l_session,
                base => l_config.user_base_dn,
                scope => DBMS_LDAP.scope_subtree,
                filter => l_config.user_filter,
                attrs => l_attrs,
                attronly => 0,
                res => l_message
            );

            -- Обработка результатов
            l_entry := DBMS_LDAP.first_entry(ld => l_session, msg => l_message);

            WHILE l_entry IS NOT NULL LOOP
                -- Сбрасываем переменные
                l_sam_account := NULL;
                l_upn := NULL;
                l_dn := NULL;
                l_display_name := NULL;
                l_given_name := NULL;
                l_surname := NULL;
                l_email := NULL;
                l_department := NULL;
                l_title := NULL;
                l_manager_dn := NULL;
                l_phone := NULL;
                l_mobile := NULL;
                l_office := NULL;
                l_company := NULL;
                l_employee_id := NULL;
                l_object_guid := NULL;

                -- Получаем атрибуты пользователя
                l_attr_name := DBMS_LDAP.first_attribute(
                    ld => l_session, 
                    ldapentry => l_entry, 
                    ber_elem => l_ber_element
                );

                WHILE l_attr_name IS NOT NULL LOOP
                    l_vals := DBMS_LDAP.get_values(
                        ld => l_session, 
                        ldapentry => l_entry, 
                        attr => l_attr_name
                    );

                    IF l_vals.COUNT > 0 THEN
                        CASE UPPER(l_attr_name)
                            WHEN 'SAMACCOUNTNAME' THEN l_sam_account := l_vals(1);
                            WHEN 'USERPRINCIPALNAME' THEN l_upn := l_vals(1);
                            WHEN 'DISTINGUISHEDNAME' THEN l_dn := l_vals(1);
                            WHEN 'DISPLAYNAME' THEN l_display_name := l_vals(1);
                            WHEN 'GIVENNAME' THEN l_given_name := l_vals(1);
                            WHEN 'SN' THEN l_surname := l_vals(1);
                            WHEN 'MAIL' THEN l_email := l_vals(1);
                            WHEN 'DEPARTMENT' THEN l_department := l_vals(1);
                            WHEN 'TITLE' THEN l_title := l_vals(1);
                            WHEN 'MANAGER' THEN l_manager_dn := l_vals(1);
                            WHEN 'TELEPHONENUMBER' THEN l_phone := l_vals(1);
                            WHEN 'MOBILE' THEN l_mobile := l_vals(1);
                            WHEN 'PHYSICALDELIVERYOFFICENAME' THEN l_office := l_vals(1);
                            WHEN 'COMPANY' THEN l_company := l_vals(1);
                            WHEN 'EMPLOYEEID' THEN l_employee_id := l_vals(1);
                            WHEN 'OBJECTGUID' THEN l_object_guid := HEXTORAW(l_vals(1));
                            ELSE NULL;
                        END CASE;
                    END IF;

                    l_attr_name := DBMS_LDAP.next_attribute(
                        ld => l_session, 
                        ldapentry => l_entry, 
                        ber_elem => l_ber_element
                    );
                END LOOP;

                -- Вставляем/обновляем пользователя
                IF l_sam_account IS NOT NULL THEN
                    BEGIN
                        MERGE INTO ad_users tgt
                        USING (SELECT 
                            NVL(l_sam_account, 'UNKNOWN_' || l_processed) as sam_account_name,
                            l_upn as user_principal_name,
                            l_dn as distinguished_name,
                            l_display_name as display_name,
                            l_given_name as given_name,
                            l_surname as surname,
                            l_email as email_address,
                            l_department as department,
                            l_title as title,
                            l_manager_dn as manager_dn,
                            l_phone as telephone_number,
                            l_mobile as mobile_number,
                            l_office as office_location,
                            l_company as company,
                            l_employee_id as employee_id,
                            l_object_guid as object_guid
                            FROM dual) src
                        ON (tgt.sam_account_name = src.sam_account_name)
                        WHEN MATCHED THEN UPDATE SET
                            user_principal_name = src.user_principal_name,
                            distinguished_name = src.distinguished_name,
                            display_name = src.display_name,
                            given_name = src.given_name,
                            surname = src.surname,
                            email_address = src.email_address,
                            department = src.department,
                            title = src.title,
                            manager_dn = src.manager_dn,
                            telephone_number = src.telephone_number,
                            mobile_number = src.mobile_number,
                            office_location = src.office_location,
                            company = src.company,
                            employee_id = src.employee_id,
                            object_guid = src.object_guid,
                            sync_status = 'ACTIVE',
                            last_sync_date = SYSDATE,
                            sync_attempts = 0,
                            sync_error_message = NULL,
                            modified_by = USER,
                            modified_date = SYSDATE
                        WHEN NOT MATCHED THEN INSERT (
                            user_id,
                            sam_account_name,
                            user_principal_name,
                            distinguished_name,
                            display_name,
                            given_name,
                            surname,
                            email_address,
                            department,
                            title,
                            manager_dn,
                            telephone_number,
                            mobile_number,
                            office_location,
                            company,
                            employee_id,
                            object_guid,
                            sync_status
                        ) VALUES (
                            'U' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS') || '_' || l_processed,
                            src.sam_account_name,
                            src.user_principal_name,
                            src.distinguished_name,
                            src.display_name,
                            src.given_name,
                            src.surname,
                            src.email_address,
                            src.department,
                            src.title,
                            src.manager_dn,
                            src.telephone_number,
                            src.mobile_number,
                            src.office_location,
                            src.company,
                            src.employee_id,
                            src.object_guid,
                            'ACTIVE'
                        );

                        l_success := l_success + 1;

                    EXCEPTION
                        WHEN OTHERS THEN
                            l_errors := l_errors + 1;
                            l_error_msg := SQLERRM;

                            log_sync_event(
                                p_session_id => l_session_id,
                                p_sync_type => 'USERS',
                                p_operation => 'USER_SYNC',
                                p_object_id => l_sam_account,
                                p_status => C_ERROR,
                                p_start_time => l_start_time,
                                p_error_msg => l_error_msg
                            );
                    END;
                END IF;

                l_processed := l_processed + 1;

                -- Коммитим каждые N записей
                IF MOD(l_processed, l_config.batch_size) = 0 THEN
                    COMMIT;
                END IF;

                l_entry := DBMS_LDAP.next_entry(ld => l_session, msg => l_entry);
            END LOOP;

            -- Закрываем LDAP соединение
            l_retval := DBMS_LDAP.unbind_s(ld => l_session);

        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SQLERRM;
                l_retval := DBMS_LDAP.unbind_s(ld => l_session);

                log_sync_event(
                    p_session_id => l_session_id,
                    p_sync_type => 'USERS',
                    p_operation => 'LDAP_ERROR',
                    p_object_id => 'CONNECTION',
                    p_status => C_ERROR,
                    p_start_time => l_start_time,
                    p_error_msg => l_error_msg
                );
                RAISE;
        END;

        -- Удаляем пользователей, которых больше нет в AD
        DELETE FROM ad_users WHERE sync_status = 'INACTIVE';

        COMMIT;

        -- Логируем завершение синхронизации
        log_sync_event(
            p_session_id => l_session_id,
            p_sync_type => 'USERS',
            p_operation => 'SYNC_COMPLETE',
            p_object_id => 'BULK',
            p_status => CASE WHEN l_errors = 0 THEN C_SUCCESS ELSE C_WARNING END,
            p_start_time => l_start_time,
            p_records_proc => l_processed,
            p_records_succ => l_success,
            p_records_err => l_errors
        );

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_sync_event(
                p_session_id => l_session_id,
                p_sync_type => 'USERS',
                p_operation => 'SYNC_FAILED',
                p_object_id => 'BULK',
                p_status => C_ERROR,
                p_start_time => l_start_time,
                p_error_msg => SQLERRM
            );
            RAISE;
    END sync_users_only;

    -- Основная процедура ежедневной синхронизации
    PROCEDURE sync_daily_full IS
        l_session_id    VARCHAR2(50);
        l_start_time    TIMESTAMP;
        l_error_msg     VARCHAR2(4000);
    BEGIN
        l_session_id := generate_session_id();
        l_start_time := SYSTIMESTAMP;

        -- Логируем начало полной синхронизации
        log_sync_event(
            p_session_id => l_session_id,
            p_sync_type => 'FULL_SYNC',
            p_operation => 'DAILY_START',
            p_object_id => 'ALL',
            p_status => 'SUCCESS',
            p_start_time => l_start_time
        );

        BEGIN
            -- Синхронизируем пользователей
            sync_users_only();

            -- Здесь можно добавить синхронизацию групп и членства
            -- sync_groups_only();
            -- sync_memberships_only();

            -- Логируем успешное завершение
            log_sync_event(
                p_session_id => l_session_id,
                p_sync_type => 'FULL_SYNC',
                p_operation => 'DAILY_COMPLETE',
                p_object_id => 'ALL',
                p_status => C_SUCCESS,
                p_start_time => l_start_time
            );

        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SQLERRM;

                log_sync_event(
                    p_session_id => l_session_id,
                    p_sync_type => 'FULL_SYNC',
                    p_operation => 'DAILY_FAILED',
                    p_object_id => 'ALL',
                    p_status => C_ERROR,
                    p_start_time => l_start_time,
                    p_error_msg => l_error_msg
                );

                -- Отправляем уведомление об ошибке
                RAISE;
        END;
    END sync_daily_full;

    -- Заглушки для других процедур
    PROCEDURE sync_groups_only IS
    BEGIN
        NULL; -- Реализуется аналогично sync_users_only
    END;

    PROCEDURE sync_memberships_only IS  
    BEGIN
        NULL; -- Реализуется для синхронизации членства в группах
    END;

END PKG_AD_SYNC;
/
