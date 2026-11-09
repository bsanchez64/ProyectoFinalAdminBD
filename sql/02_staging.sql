-- =====================================================================
-- 02_staging.sql  -  Tablas de aterrizaje + carga de los CSV
-- Correr con psql DESDE LA RAIZ DEL REPO (las rutas son relativas).
-- El JSON del clima lo carga etl/clima.py en staging.clima_json.
-- =====================================================================

-- Fuente 1: CSV de generacion (datos.gov.co). Todo TEXT porque viene
-- con comillas y coma de miles ("2,000", "2,178.669").
DROP TABLE IF EXISTS staging.generacion_csv;
CREATE TABLE staging.generacion_csv (
    anio TEXT, mes TEXT, fuente TEXT,
    promedio TEXT, maximo TEXT, minimo TEXT, total TEXT, pct TEXT
);
\copy staging.generacion_csv FROM 'data/raw/generacion_por_fuente.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- Fuente 2: API Open-Meteo (JSON). Una fila por zona con la respuesta completa.
CREATE TABLE IF NOT EXISTS staging.clima_json (
    zona          TEXT PRIMARY KEY,
    latitud       NUMERIC(8,5) NOT NULL,
    longitud      NUMERIC(8,5) NOT NULL,
    fuente_codigo TEXT,
    payload       JSONB NOT NULL,
    descargado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Fuente 3: maestra de plantas y operadores (CSV propio, datos de PARATEC/XM)
DROP TABLE IF EXISTS staging.operadores_plantas_csv;
CREATE TABLE staging.operadores_plantas_csv (
    planta TEXT, operador TEXT, fuente_codigo TEXT, departamento TEXT,
    municipio TEXT, capacidad_mw TEXT, vigencia_desde TEXT, estado TEXT
);
\copy staging.operadores_plantas_csv FROM 'data/raw/operadores_plantas.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

SELECT 'generacion_csv' AS tabla, count(*) FROM staging.generacion_csv
UNION ALL SELECT 'operadores_plantas_csv', count(*) FROM staging.operadores_plantas_csv
UNION ALL SELECT 'clima_json', count(*) FROM staging.clima_json;
