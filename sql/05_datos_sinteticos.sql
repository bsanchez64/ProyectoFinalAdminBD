-- =====================================================================
-- 05_datos_sinteticos.sql  -  Sensores, mantenimientos y telemetria
-- DATOS SINTETICOS (generados), declarados asi en el informe.
-- Sirven para: probar la regla R3 y tener VOLUMEN para el tuning (Entrega 3),
-- porque con 2.786 filas reales los indices no muestran diferencia.
--
-- Volumen: cambie :intervalo  ('15 minutes' ~ 2.4 M filas | '1 hour' ~ 600 mil)
-- =====================================================================
SET search_path TO energia, public;
\set intervalo '15 minutes'
\set desde '2024-01-01'
\set hasta '2026-08-31 23:59'

-- 1. Sensores: POTENCIA en todas las plantas activas + uno segun la tecnologia
INSERT INTO sensor (planta_id, tipo, instalado_en)
SELECT p.id, t.tipo, DATE '2023-12-01'
FROM planta p
JOIN fuente_energia f ON f.id = p.fuente_id
CROSS JOIN LATERAL (VALUES
    ('POTENCIA'),
    (CASE f.tecnologia WHEN 'HIDRAULICA' THEN 'CAUDAL'
                       WHEN 'EOLICA'     THEN 'VIENTO'
                       WHEN 'SOLAR'      THEN 'RADIACION'
                       ELSE 'TEMPERATURA' END)
) AS t(tipo)
WHERE p.estado <> 'RETIRADA'          -- una planta retirada no tiene telemetria
ON CONFLICT (planta_id, tipo) DO NOTHING;

-- 2. Mantenimientos: 2 paradas preventivas por planta (no se solapan)
INSERT INTO mantenimiento_planta (planta_id, ventana, tipo, descripcion)
SELECT p.id,
       tstzrange(ini, ini + interval '3 days', '[)'),
       'PREVENTIVO',
       'Mantenimiento programado (sintetico)'
FROM planta p
CROSS JOIN LATERAL (VALUES
    (TIMESTAMPTZ '2024-03-01' + (p.id * interval '5 days')),
    (TIMESTAMPTZ '2025-09-01' + (p.id * interval '4 days'))
) AS v(ini)
WHERE p.estado <> 'RETIRADA'
  AND NOT EXISTS (SELECT 1 FROM mantenimiento_planta m WHERE m.planta_id = p.id);

-- 3. Telemetria masiva. Se desactiva el trigger R3 SOLO durante esta carga
--    historica (equivale a un bulk load); las ventanas de mantenimiento se
--    excluyen en el propio SELECT, asi que los datos igual cumplen la regla.
ALTER TABLE lectura_sensor DISABLE TRIGGER trg_valida_lectura_sensor;

INSERT INTO lectura_sensor (sensor_id, fecha_hora, valor, calidad)
SELECT s.id,
       g.ts,
       round((CASE s.tipo
                WHEN 'POTENCIA'    THEN 50 + random() * 450
                WHEN 'CAUDAL'      THEN 20 + random() * 300
                WHEN 'VIENTO'      THEN random() * 25
                WHEN 'RADIACION'   THEN GREATEST(0, 1000 * sin(pi() * (extract(hour FROM g.ts) - 6) / 12))
                ELSE 25 + random() * 15 END)::numeric, 4),
       CASE WHEN random() < 0.01 THEN 'FALLA'
            WHEN random() < 0.03 THEN 'SOSPECHOSA'
            ELSE 'OK' END
FROM sensor s
CROSS JOIN generate_series(TIMESTAMPTZ :'desde', TIMESTAMPTZ :'hasta', interval :'intervalo') AS g(ts)
WHERE NOT EXISTS (SELECT 1 FROM mantenimiento_planta m
                  WHERE m.planta_id = s.planta_id AND m.ventana @> g.ts)
ON CONFLICT (sensor_id, fecha_hora) DO NOTHING;

ALTER TABLE lectura_sensor ENABLE TRIGGER trg_valida_lectura_sensor;

-- 4. Un sensor queda INACTIVO (para probar R3)
UPDATE sensor SET estado = 'INACTIVO'
WHERE id = (SELECT min(id) FROM sensor WHERE tipo <> 'POTENCIA');

ANALYZE;

SELECT 'sensor' AS tabla, count(*) FROM sensor
UNION ALL SELECT 'mantenimiento_planta', count(*) FROM mantenimiento_planta
UNION ALL SELECT 'lectura_sensor',       count(*) FROM lectura_sensor;
