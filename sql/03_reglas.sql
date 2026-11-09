-- =====================================================================
-- 03_reglas.sql  -  Reglas de negocio en PL/pgSQL (triggers)
-- Se crean ANTES de cargar datos para que la carga misma pase por ellas.
-- =====================================================================
SET search_path TO energia, public;

-- ---------------------------------------------------------------------
-- R1. Generacion total del mes no puede superar promedio diario x dias del mes.
--     (el CSV calcula total = promedio x dias con generacion, asi que nunca
--      deberia pasar de los dias calendario)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_valida_total_generacion()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_dias SMALLINT;
BEGIN
    SELECT dias_mes INTO v_dias FROM periodo WHERE id = NEW.periodo_id;

    IF NEW.total_gwh > NEW.promedio_gwh * v_dias + 0.01 THEN
        RAISE EXCEPTION 'R1: total_gwh (%) supera promedio_gwh x % dias (%)',
            NEW.total_gwh, v_dias, round(NEW.promedio_gwh * v_dias, 4)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_valida_total_generacion
BEFORE INSERT OR UPDATE ON generacion_mensual
FOR EACH ROW EXECUTE FUNCTION fn_valida_total_generacion();

-- ---------------------------------------------------------------------
-- R2. La participacion (%) de todas las fuentes en un mes debe sumar 100.
--     Constraint trigger DIFERIDO: valida al COMMIT, cuando ya estan
--     todas las filas del mes (si no, fallaria en la primera fila).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_valida_suma_participacion()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_periodo INT := COALESCE(NEW.periodo_id, OLD.periodo_id);
    v_suma    NUMERIC;
BEGIN
    SELECT COALESCE(sum(pct_participacion), 0) INTO v_suma
    FROM generacion_mensual WHERE periodo_id = v_periodo;

    -- un periodo puede quedar vacio (se borraron todas sus filas)
    IF v_suma <> 0 AND abs(v_suma - 100) > 0.01 THEN
        RAISE EXCEPTION 'R2: la participacion del periodo % suma % (debe ser 100)',
            v_periodo, round(v_suma, 4) USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_valida_suma_participacion
AFTER INSERT OR UPDATE OR DELETE ON generacion_mensual
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_valida_suma_participacion();

-- ---------------------------------------------------------------------
-- R3. Lecturas de sensor: el sensor debe estar activo/calibrando y la
--     planta no puede estar en una ventana de mantenimiento.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_valida_lectura_sensor()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_estado VARCHAR;
    v_planta INT;
BEGIN
    SELECT estado, planta_id INTO v_estado, v_planta
    FROM sensor WHERE id = NEW.sensor_id;

    IF v_estado = 'INACTIVO' THEN
        RAISE EXCEPTION 'R3: el sensor % esta INACTIVO, no acepta lecturas', NEW.sensor_id
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM mantenimiento_planta m
               WHERE m.planta_id = v_planta AND m.ventana @> NEW.fecha_hora) THEN
        RAISE EXCEPTION 'R3: la planta % esta en mantenimiento en %', v_planta, NEW.fecha_hora
            USING ERRCODE = 'check_violation';
    END IF;

    -- un sensor en FALLA solo puede reportar calidad FALLA o SOSPECHOSA
    IF v_estado = 'FALLA' AND NEW.calidad = 'OK' THEN
        NEW.calidad := 'SOSPECHOSA';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_valida_lectura_sensor
BEFORE INSERT OR UPDATE ON lectura_sensor
FOR EACH ROW EXECUTE FUNCTION fn_valida_lectura_sensor();

-- ---------------------------------------------------------------------
-- R4. Una planta RETIRADA no puede recibir un operador nuevo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_valida_operacion_planta()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT estado FROM planta WHERE id = NEW.planta_id) = 'RETIRADA'
       AND upper_inf(NEW.vigencia) THEN
        RAISE EXCEPTION 'R4: la planta % esta RETIRADA, no puede tener operacion abierta', NEW.planta_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_valida_operacion_planta
BEFORE INSERT OR UPDATE ON operacion_planta
FOR EACH ROW EXECUTE FUNCTION fn_valida_operacion_planta();

-- ---------------------------------------------------------------------
-- R5. Auditoria de cambios en tablas criticas (UPDATE / DELETE).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_auditoria()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO auditoria (tabla, operacion, datos_old, datos_new)
    VALUES (TG_TABLE_NAME, TG_OP,
            CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP IN ('UPDATE','INSERT') THEN to_jsonb(NEW) END);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_auditoria_generacion
AFTER UPDATE OR DELETE ON generacion_mensual
FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_planta
AFTER UPDATE OR DELETE ON planta
FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_operacion
AFTER INSERT OR UPDATE OR DELETE ON operacion_planta
FOR EACH ROW EXECUTE FUNCTION fn_auditoria();
