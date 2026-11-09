-- =====================================================================
-- 07_pruebas_reglas.sql  -  Cada regla de negocio con un caso que DEBE fallar
-- Cada prueba corre en su propio bloque y reporta OK si la BD la rechazo.
-- Salida esperada: solo lineas "OK ..." (NOTICE). Tomar captura = evidencia.
-- =====================================================================
SET search_path TO energia, public;
SET client_min_messages TO notice;
\pset tuples_only on

-- Helper: ejecuta un SQL y verifica que falle
CREATE OR REPLACE FUNCTION pg_temp.debe_fallar(p_nombre TEXT, p_sql TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        -- si llego aqui, NO fallo: forzar el error de la prueba
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'NO_FALLO';
    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM = 'NO_FALLO' THEN
                RAISE WARNING 'FALLA LA PRUEBA  %  (la BD acepto el dato)', p_nombre;
            ELSE
                RAISE NOTICE 'OK  %  -> %', p_nombre, SQLERRM;
            END IF;
        WHEN OTHERS THEN
            RAISE NOTICE 'OK  %  -> [%] %', p_nombre, SQLSTATE, SQLERRM;
    END;
END $$;

-- ---------- CHECK -----------------------------------------------------
SELECT pg_temp.debe_fallar('CHECK mes 1..12',
  $$INSERT INTO periodo (anio, mes, fecha_inicio, dias_mes) VALUES (2030, 13, '2030-12-01', 31)$$);

SELECT pg_temp.debe_fallar('CHECK fecha_inicio coherente',
  $$INSERT INTO periodo (anio, mes, fecha_inicio, dias_mes) VALUES (2030, 5, '2030-06-01', 31)$$);

SELECT pg_temp.debe_fallar('CHECK minimo <= promedio <= maximo',
  $$UPDATE generacion_mensual SET minimo_gwh = maximo_gwh + 1
    WHERE id = (SELECT min(id) FROM generacion_mensual)$$);

SELECT pg_temp.debe_fallar('CHECK participacion 0..100',
  $$UPDATE generacion_mensual SET pct_participacion = 150
    WHERE id = (SELECT min(id) FROM generacion_mensual)$$);

SELECT pg_temp.debe_fallar('CHECK estado de planta',
  $$UPDATE planta SET estado = 'APAGADA' WHERE id = (SELECT min(id) FROM planta)$$);

SELECT pg_temp.debe_fallar('CHECK estado de sensor',
  $$UPDATE sensor SET estado = 'ROTO' WHERE id = (SELECT min(id) FROM sensor)$$);

SELECT pg_temp.debe_fallar('CHECK latitud dentro de Colombia',
  $$INSERT INTO zona_climatica (nombre, latitud, longitud) VALUES ('Madrid', 40.4, -3.7)$$);

-- ---------- UNIQUE / FK ------------------------------------------------
SELECT pg_temp.debe_fallar('UNIQUE fuente + periodo (duplicado)',
  $$INSERT INTO generacion_mensual (fuente_id, periodo_id, promedio_gwh, maximo_gwh, minimo_gwh, total_gwh, pct_participacion)
    SELECT fuente_id, periodo_id, promedio_gwh, maximo_gwh, minimo_gwh, total_gwh, pct_participacion
    FROM generacion_mensual LIMIT 1$$);

SELECT pg_temp.debe_fallar('FK fuente inexistente',
  $$INSERT INTO planta (nombre, fuente_id, departamento) VALUES ('Fantasma', 999, 'Antioquia')$$);

-- ---------- EXCLUDE (solapamientos temporales) ------------------------
SELECT pg_temp.debe_fallar('EXCLUDE dos operadores a la vez en la misma planta',
  $$INSERT INTO operacion_planta (planta_id, operador_id, vigencia)
    SELECT planta_id, operador_id, daterange('2025-01-01', '2025-12-31')
    FROM operacion_planta LIMIT 1$$);

SELECT pg_temp.debe_fallar('EXCLUDE mantenimientos solapados',
  $$INSERT INTO mantenimiento_planta (planta_id, ventana, tipo)
    SELECT planta_id, tstzrange(lower(ventana) + interval '1 day', upper(ventana) + interval '1 day'), 'CORRECTIVO'
    FROM mantenimiento_planta LIMIT 1$$);

-- ---------- TRIGGERS PL/pgSQL -----------------------------------------
SELECT pg_temp.debe_fallar('R1 total > promedio x dias del mes',
  $$UPDATE generacion_mensual SET total_gwh = promedio_gwh * 40
    WHERE id = (SELECT min(id) FROM generacion_mensual)$$);

-- R2 es diferido: se valida al cerrar la transaccion, por eso se fuerza
-- con SET CONSTRAINTS ... IMMEDIATE dentro del bloque.
SELECT pg_temp.debe_fallar('R2 participacion del mes debe sumar 100',
  $$SET CONSTRAINTS trg_valida_suma_participacion IMMEDIATE;
    UPDATE generacion_mensual SET pct_participacion = pct_participacion + 5
    WHERE id = (SELECT min(id) FROM generacion_mensual)$$);

SELECT pg_temp.debe_fallar('R3 lectura de sensor INACTIVO',
  $$INSERT INTO lectura_sensor (sensor_id, fecha_hora, valor)
    SELECT id, now(), 10 FROM sensor WHERE estado = 'INACTIVO' LIMIT 1$$);

SELECT pg_temp.debe_fallar('R3 lectura durante mantenimiento',
  $$INSERT INTO lectura_sensor (sensor_id, fecha_hora, valor)
    SELECT s.id, lower(m.ventana) + interval '1 hour', 10
    FROM mantenimiento_planta m JOIN sensor s ON s.planta_id = m.planta_id AND s.estado = 'ACTIVO'
    LIMIT 1$$);

SELECT pg_temp.debe_fallar('R4 operador nuevo en planta RETIRADA',
  $$UPDATE planta SET estado = 'RETIRADA' WHERE id = (SELECT max(id) FROM planta);
    INSERT INTO operacion_planta (planta_id, operador_id, vigencia)
    VALUES ((SELECT max(id) FROM planta), (SELECT min(id) FROM operador), daterange('2030-01-01', NULL))$$);

\pset tuples_only off

-- ---------- R5 Auditoria (caso positivo: debe registrar) --------------
BEGIN;
UPDATE planta SET capacidad_mw = 100 WHERE id = (SELECT min(id) FROM planta);
SELECT tabla, operacion, usuario, datos_old ->> 'capacidad_mw' AS antes,
       datos_new ->> 'capacidad_mw' AS despues
FROM auditoria ORDER BY id DESC LIMIT 1;
ROLLBACK;
