-- =====================================================================
-- 01_ddl.sql  -  Modelo fisico: tablas, PK, FK, UNIQUE, CHECK, EXCLUDE
-- Sistema Energetico Colombia
-- =====================================================================
SET search_path TO energia, public;

-- ---------------------------------------------------------------------
-- Catalogos
-- ---------------------------------------------------------------------
CREATE TABLE categoria_fuente (
    id          SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre      VARCHAR(20) NOT NULL UNIQUE
                CHECK (nombre IN ('RENOVABLE', 'NO RENOVABLE')),
    descripcion VARCHAR(200)
);

CREATE TABLE fuente_energia (
    id           SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo       VARCHAR(20) NOT NULL UNIQUE,          -- como viene en el CSV: AGUA, CARBON...
    nombre       VARCHAR(60) NOT NULL,
    tecnologia   VARCHAR(20) NOT NULL
                 CHECK (tecnologia IN ('HIDRAULICA','TERMICA','SOLAR','EOLICA','BIOMASA','OTRA')),
    categoria_id SMALLINT NOT NULL REFERENCES categoria_fuente(id)
);

CREATE TABLE periodo (
    id           INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    anio         SMALLINT NOT NULL CHECK (anio BETWEEN 2000 AND 2100),
    mes          SMALLINT NOT NULL CHECK (mes BETWEEN 1 AND 12),
    fecha_inicio DATE     NOT NULL,
    dias_mes     SMALLINT NOT NULL CHECK (dias_mes BETWEEN 28 AND 31),
    UNIQUE (anio, mes),
    -- la fecha de inicio debe ser coherente con anio/mes
    CHECK (fecha_inicio = make_date(anio, mes, 1))
);

-- ---------------------------------------------------------------------
-- Hechos: generacion mensual por fuente (origen: CSV datos.gov.co)
-- ---------------------------------------------------------------------
CREATE TABLE generacion_mensual (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fuente_id         SMALLINT NOT NULL REFERENCES fuente_energia(id),
    periodo_id        INT      NOT NULL REFERENCES periodo(id),
    promedio_gwh      NUMERIC(20,10) NOT NULL CHECK (promedio_gwh >= 0),
    maximo_gwh        NUMERIC(20,10) NOT NULL CHECK (maximo_gwh   >= 0),
    minimo_gwh        NUMERIC(20,10) NOT NULL CHECK (minimo_gwh   >= 0),
    total_gwh         NUMERIC(20,10) NOT NULL CHECK (total_gwh    >= 0),
    pct_participacion NUMERIC(20,12) NOT NULL CHECK (pct_participacion BETWEEN 0 AND 100),
    origen            VARCHAR(40) NOT NULL DEFAULT 'datos.gov.co (CSV)',
    fecha_carga       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (fuente_id, periodo_id),
    -- regla: el promedio diario esta entre el minimo y el maximo diario
    CONSTRAINT ck_min_prom_max CHECK (minimo_gwh <= promedio_gwh AND promedio_gwh <= maximo_gwh)
);

-- ---------------------------------------------------------------------
-- Maestras de operadores y plantas (origen: CSV propio / PARATEC XM)
-- ---------------------------------------------------------------------
CREATE TABLE operador (
    id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre VARCHAR(80) NOT NULL UNIQUE,
    nit    VARCHAR(15) UNIQUE CHECK (nit ~ '^[0-9]{9}-?[0-9]?$')
);

CREATE TABLE planta (
    id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre        VARCHAR(80) NOT NULL UNIQUE,
    fuente_id     SMALLINT NOT NULL REFERENCES fuente_energia(id),
    departamento  VARCHAR(40) NOT NULL,
    municipio     VARCHAR(60),
    capacidad_mw  NUMERIC(8,2) CHECK (capacidad_mw > 0 AND capacidad_mw < 5000),
    estado        VARCHAR(15) NOT NULL DEFAULT 'OPERACION'
                  CHECK (estado IN ('OPERACION','MANTENIMIENTO','RETIRADA'))
);

-- Que operador opera cada planta y durante que vigencia.
-- EXCLUDE: una planta no puede tener dos operadores con vigencias solapadas.
CREATE TABLE operacion_planta (
    id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    planta_id   INT NOT NULL REFERENCES planta(id),
    operador_id INT NOT NULL REFERENCES operador(id),
    vigencia    DATERANGE NOT NULL CHECK (NOT isempty(vigencia)),
    CONSTRAINT ex_operacion_sin_solape
        EXCLUDE USING gist (planta_id WITH =, vigencia WITH &&)
);

-- Paradas de planta. EXCLUDE: no se solapan dos mantenimientos de la misma planta.
CREATE TABLE mantenimiento_planta (
    id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    planta_id   INT NOT NULL REFERENCES planta(id),
    ventana     TSTZRANGE NOT NULL CHECK (NOT isempty(ventana) AND upper(ventana) - lower(ventana) <= interval '180 days'),
    tipo        VARCHAR(12) NOT NULL CHECK (tipo IN ('PREVENTIVO','CORRECTIVO')),
    descripcion VARCHAR(200),
    CONSTRAINT ex_mantenimiento_sin_solape
        EXCLUDE USING gist (planta_id WITH =, ventana WITH &&)
);

-- ---------------------------------------------------------------------
-- Clima (origen: API Open-Meteo en JSON)
-- ---------------------------------------------------------------------
CREATE TABLE zona_climatica (
    id        SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre    VARCHAR(60) NOT NULL UNIQUE,
    latitud   NUMERIC(8,5) NOT NULL CHECK (latitud  BETWEEN  -4.3 AND 13.5),   -- rango de Colombia
    longitud  NUMERIC(8,5) NOT NULL CHECK (longitud BETWEEN -82.0 AND -66.8),
    fuente_relacionada_id SMALLINT REFERENCES fuente_energia(id)               -- AGUA, VIENTO, RAD SOLAR
);

CREATE TABLE clima_mensual (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    zona_id             SMALLINT NOT NULL REFERENCES zona_climatica(id),
    periodo_id          INT      NOT NULL REFERENCES periodo(id),
    precipitacion_mm    NUMERIC(8,2)  CHECK (precipitacion_mm >= 0),
    radiacion_mj_m2     NUMERIC(8,2)  CHECK (radiacion_mj_m2  >= 0),   -- promedio diario del mes
    viento_max_kmh      NUMERIC(6,2)  CHECK (viento_max_kmh   BETWEEN 0 AND 300),
    dias_con_dato       SMALLINT NOT NULL CHECK (dias_con_dato BETWEEN 1 AND 31),
    UNIQUE (zona_id, periodo_id)
);

-- ---------------------------------------------------------------------
-- Telemetria de sensores (datos sinteticos, sirven para el tuning)
-- ---------------------------------------------------------------------
CREATE TABLE sensor (
    id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    planta_id   INT NOT NULL REFERENCES planta(id),
    tipo        VARCHAR(15) NOT NULL CHECK (tipo IN ('POTENCIA','TEMPERATURA','CAUDAL','RADIACION','VIENTO')),
    estado      VARCHAR(12) NOT NULL DEFAULT 'ACTIVO'
                CHECK (estado IN ('ACTIVO','FALLA','CALIBRANDO','INACTIVO')),
    instalado_en DATE NOT NULL,
    UNIQUE (planta_id, tipo)
);

CREATE TABLE lectura_sensor (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sensor_id  INT NOT NULL REFERENCES sensor(id),
    fecha_hora TIMESTAMPTZ NOT NULL,
    valor      NUMERIC(12,4) NOT NULL,
    calidad    VARCHAR(10) NOT NULL DEFAULT 'OK' CHECK (calidad IN ('OK','SOSPECHOSA','FALLA')),
    UNIQUE (sensor_id, fecha_hora)
);

-- ---------------------------------------------------------------------
-- Auditoria (la llenan los triggers de 04_reglas.sql)
-- ---------------------------------------------------------------------
CREATE TABLE auditoria (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tabla      VARCHAR(60) NOT NULL,
    operacion  VARCHAR(10) NOT NULL CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    usuario    VARCHAR(60) NOT NULL DEFAULT current_user,
    fecha      TIMESTAMPTZ NOT NULL DEFAULT now(),
    datos_old  JSONB,
    datos_new  JSONB
);
