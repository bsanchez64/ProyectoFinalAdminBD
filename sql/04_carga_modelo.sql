-- =====================================================================
-- 04_carga_modelo.sql  -  Transformacion staging -> modelo (energia)
-- Idempotente: se puede correr varias veces (ON CONFLICT DO NOTHING).
-- =====================================================================
SET search_path TO energia, public;

-- 1. Categorias -------------------------------------------------------
INSERT INTO categoria_fuente (nombre, descripcion) VALUES
  ('RENOVABLE',    'Hidraulica, solar, eolica y biomasa'),
  ('NO RENOVABLE', 'Combustibles fosiles')
ON CONFLICT (nombre) DO NOTHING;

-- 2. Fuentes (codigo exacto del CSV -> tecnologia y categoria) --------
INSERT INTO fuente_energia (codigo, nombre, tecnologia, categoria_id)
SELECT v.codigo, v.nombre, v.tecnologia, c.id
FROM (VALUES
  ('AGUA',        'Agua (hidroelectrica)',      'HIDRAULICA', 'RENOVABLE'),
  ('RAD SOLAR',   'Radiacion solar',            'SOLAR',      'RENOVABLE'),
  ('VIENTO',      'Viento (eolica)',            'EOLICA',     'RENOVABLE'),
  ('BAGAZO',      'Bagazo de cana',             'BIOMASA',    'RENOVABLE'),
  ('BIOGAS',      'Biogas',                     'BIOMASA',    'RENOVABLE'),
  ('BIOMASA',     'Biomasa',                    'BIOMASA',    'RENOVABLE'),
  ('CARBON',      'Carbon',                     'TERMICA',    'NO RENOVABLE'),
  ('GAS',         'Gas natural',                'TERMICA',    'NO RENOVABLE'),
  ('ACPM',        'ACPM (diesel)',              'TERMICA',    'NO RENOVABLE'),
  ('COMBUSTOLEO', 'Combustoleo',                'TERMICA',    'NO RENOVABLE'),
  ('JET-A1',      'Jet A1',                     'TERMICA',    'NO RENOVABLE'),
  ('GLP',         'Gas licuado de petroleo',    'TERMICA',    'NO RENOVABLE'),
  ('OTROS',       'Otros combustibles',         'OTRA',       'NO RENOVABLE')
) AS v(codigo, nombre, tecnologia, categoria)
JOIN categoria_fuente c ON c.nombre = v.categoria
ON CONFLICT (codigo) DO NOTHING;

-- Control: ninguna fuente del CSV puede quedar sin mapear
DO $$
DECLARE v_faltantes TEXT;
BEGIN
  SELECT string_agg(DISTINCT s.fuente, ', ') INTO v_faltantes
  FROM staging.generacion_csv s
  LEFT JOIN energia.fuente_energia f ON f.codigo = trim(s.fuente)
  WHERE f.id IS NULL;
  IF v_faltantes IS NOT NULL THEN
    RAISE EXCEPTION 'Fuentes del CSV sin mapear: %', v_faltantes;
  END IF;
END $$;

-- 3. Periodos (ene-2000 a dic-2026) ----------------------------------
INSERT INTO periodo (anio, mes, fecha_inicio, dias_mes)
SELECT extract(year FROM d)::smallint,
       extract(month FROM d)::smallint,
       d::date,
       extract(day FROM (d + interval '1 month - 1 day'))::smallint
FROM generate_series('2000-01-01'::date, '2026-12-01'::date, interval '1 month') AS d
ON CONFLICT (anio, mes) DO NOTHING;

-- 4. Hechos de generacion (limpieza de comas de miles) ---------------
INSERT INTO generacion_mensual
      (fuente_id, periodo_id, promedio_gwh, maximo_gwh, minimo_gwh, total_gwh, pct_participacion)
SELECT f.id, p.id,
       replace(s.promedio, ',', '')::numeric,
       replace(s.maximo,   ',', '')::numeric,
       replace(s.minimo,   ',', '')::numeric,
       replace(s.total,    ',', '')::numeric,
       replace(s.pct,      ',', '')::numeric
FROM staging.generacion_csv s
JOIN fuente_energia f ON f.codigo = trim(s.fuente)
JOIN periodo p ON p.anio = replace(s.anio, ',', '')::int
              AND p.mes  = s.mes::int
ON CONFLICT (fuente_id, periodo_id) DO NOTHING;

-- 5. Operadores y plantas (CSV propio) -------------------------------
INSERT INTO operador (nombre)
SELECT DISTINCT trim(operador) FROM staging.operadores_plantas_csv
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO planta (nombre, fuente_id, departamento, municipio, capacidad_mw, estado)
SELECT trim(s.planta), f.id, trim(s.departamento), NULLIF(trim(s.municipio), ''),
       NULLIF(trim(s.capacidad_mw), '')::numeric,
       COALESCE(NULLIF(upper(trim(s.estado)), ''), 'OPERACION')
FROM staging.operadores_plantas_csv s
JOIN fuente_energia f ON f.codigo = trim(s.fuente_codigo)
ON CONFLICT (nombre) DO NOTHING;

-- Vigencia desde la FPO de PARATEC hasta vigencia_hasta (vacia = sigue operando).
-- Si vigencia_desde esta vacia se usa 2000-01-01 (inicio del dataset).
-- Una planta RETIRADA debe traer vigencia_hasta, o la regla R4 rechaza la fila.
INSERT INTO operacion_planta (planta_id, operador_id, vigencia)
SELECT pl.id, o.id,
       daterange(COALESCE(NULLIF(trim(s.vigencia_desde), '')::date, '2000-01-01'),
                 NULLIF(trim(s.vigencia_hasta), '')::date, '[)')
FROM staging.operadores_plantas_csv s
JOIN planta   pl ON pl.nombre = trim(s.planta)
JOIN operador o  ON o.nombre  = trim(s.operador)
WHERE NOT EXISTS (SELECT 1 FROM operacion_planta x WHERE x.planta_id = pl.id);

-- 6. Clima: JSON diario -> agregado mensual ---------------------------
INSERT INTO zona_climatica (nombre, latitud, longitud, fuente_relacionada_id)
SELECT c.zona, c.latitud, c.longitud, f.id
FROM staging.clima_json c
LEFT JOIN fuente_energia f ON f.codigo = c.fuente_codigo
ON CONFLICT (nombre) DO NOTHING;

WITH diario AS (
    SELECT c.zona,
           t.fecha::date AS fecha,
           (c.payload -> 'daily' -> 'precipitation_sum'       ->> (t.i - 1)::int)::numeric AS lluvia,
           (c.payload -> 'daily' -> 'shortwave_radiation_sum' ->> (t.i - 1)::int)::numeric AS radiacion,
           (c.payload -> 'daily' -> 'wind_speed_10m_max'      ->> (t.i - 1)::int)::numeric AS viento
    FROM staging.clima_json c
    CROSS JOIN LATERAL jsonb_array_elements_text(c.payload -> 'daily' -> 'time')
               WITH ORDINALITY AS t(fecha, i)
)
INSERT INTO clima_mensual (zona_id, periodo_id, precipitacion_mm, radiacion_mj_m2, viento_max_kmh, dias_con_dato)
SELECT z.id, p.id,
       round(sum(d.lluvia), 2),
       round(avg(d.radiacion), 2),
       round(max(d.viento), 2),
       count(d.lluvia)
FROM diario d
JOIN zona_climatica z ON z.nombre = d.zona
JOIN periodo p ON p.fecha_inicio = date_trunc('month', d.fecha)::date
GROUP BY z.id, p.id
HAVING count(d.lluvia) > 0
ON CONFLICT (zona_id, periodo_id) DO NOTHING;

-- Resumen de la carga --------------------------------------------------
SELECT 'fuente_energia' AS tabla, count(*) FROM fuente_energia
UNION ALL SELECT 'periodo',            count(*) FROM periodo
UNION ALL SELECT 'generacion_mensual', count(*) FROM generacion_mensual
UNION ALL SELECT 'operador',           count(*) FROM operador
UNION ALL SELECT 'planta',             count(*) FROM planta
UNION ALL SELECT 'operacion_planta',   count(*) FROM operacion_planta
UNION ALL SELECT 'zona_climatica',     count(*) FROM zona_climatica
UNION ALL SELECT 'clima_mensual',      count(*) FROM clima_mensual;
