-- =====================================================================
-- 06_vistas_consultas.sql  -  Vistas y bateria de consultas avanzadas
-- (GROUP BY / HAVING, funciones de ventana, JOINs, CTEs, subconsultas)
-- Estas mismas consultas son las que se optimizan en la Entrega 3.
-- =====================================================================
SET search_path TO energia, public;

-- ---------------------------------------------------------------------
-- VISTAS
-- ---------------------------------------------------------------------

-- V1. Base desnormalizada: cada hecho con su fuente, categoria y fecha
CREATE OR REPLACE VIEW v_generacion_detalle AS
SELECT g.id, p.anio, p.mes, p.fecha_inicio, f.codigo AS fuente, f.tecnologia,
       c.nombre AS categoria, g.promedio_gwh, g.maximo_gwh, g.minimo_gwh,
       g.total_gwh, g.pct_participacion
FROM generacion_mensual g
JOIN fuente_energia   f ON f.id = g.fuente_id
JOIN categoria_fuente c ON c.id = f.categoria_id
JOIN periodo          p ON p.id = g.periodo_id;

-- V2. Generacion anual por fuente
CREATE OR REPLACE VIEW v_generacion_anual_fuente AS
SELECT anio, fuente, tecnologia, categoria,
       round(sum(total_gwh), 2) AS total_gwh,
       count(*)                 AS meses_con_dato
FROM v_generacion_detalle
GROUP BY anio, fuente, tecnologia, categoria;

-- V3. Participacion renovable vs no renovable por mes
CREATE OR REPLACE VIEW v_participacion_categoria_mensual AS
SELECT anio, mes, categoria,
       round(sum(total_gwh), 2)         AS total_gwh,
       round(sum(pct_participacion), 2) AS pct
FROM v_generacion_detalle
GROUP BY anio, mes, categoria;

-- V4. Plantas con su operador vigente hoy
CREATE OR REPLACE VIEW v_plantas_operador_vigente AS
SELECT pl.nombre AS planta, f.codigo AS fuente, pl.departamento, pl.municipio,
       pl.capacidad_mw, pl.estado, o.nombre AS operador, op.vigencia
FROM planta pl
JOIN fuente_energia f    ON f.id = pl.fuente_id
LEFT JOIN operacion_planta op ON op.planta_id = pl.id AND op.vigencia @> current_date
LEFT JOIN operador o          ON o.id = op.operador_id;

-- ---------------------------------------------------------------------
-- CONSULTAS
-- ---------------------------------------------------------------------

-- Q1. (GROUP BY + HAVING) Fuentes que superaron 1.000 GWh en algun anio
--     y cuantos anios lo lograron
SELECT fuente, count(*) FILTER (WHERE total_gwh > 1000) AS anios_sobre_1000, round(max(total_gwh), 2) AS mejor_anio_gwh
FROM v_generacion_anual_fuente
GROUP BY fuente
HAVING max(total_gwh) > 1000
ORDER BY mejor_anio_gwh DESC;

-- Q2. (WINDOW RANK) Ranking de fuentes por generacion en cada anio
SELECT anio, fuente, total_gwh,
       RANK() OVER (PARTITION BY anio ORDER BY total_gwh DESC) AS puesto
FROM v_generacion_anual_fuente
WHERE anio >= 2020
ORDER BY anio, puesto;

-- Q3. (WINDOW LAG) Variacion mes a mes de la generacion hidraulica
SELECT anio, mes, total_gwh,
       total_gwh - LAG(total_gwh) OVER (ORDER BY anio, mes) AS variacion_gwh,
       round(100 * (total_gwh / NULLIF(LAG(total_gwh) OVER (ORDER BY anio, mes), 0) - 1), 2) AS variacion_pct
FROM v_generacion_detalle
WHERE fuente = 'AGUA'
ORDER BY anio, mes;

-- Q4. (WINDOW SUM acumulada) Acumulado anual de generacion total del pais
SELECT anio, mes, round(sum(total_gwh), 2) AS total_mes,
       round(SUM(sum(total_gwh)) OVER (PARTITION BY anio ORDER BY mes), 2) AS acumulado_anio
FROM v_generacion_detalle
GROUP BY anio, mes
ORDER BY anio, mes;

-- Q5. (WINDOW media movil) Media movil de 12 meses del carbon
SELECT anio, mes, total_gwh,
       round(AVG(total_gwh) OVER (ORDER BY anio, mes
                                  ROWS BETWEEN 11 PRECEDING AND CURRENT ROW), 2) AS media_movil_12m
FROM v_generacion_detalle
WHERE fuente = 'CARBON'
ORDER BY anio, mes;

-- Q6. (FIRST_VALUE) Crecimiento de solar y eolica desde su primer mes
SELECT fuente, anio, mes, total_gwh,
       FIRST_VALUE(total_gwh) OVER w AS primer_mes_gwh,
       round(total_gwh / NULLIF(FIRST_VALUE(total_gwh) OVER w, 0), 1) AS veces_vs_inicio
FROM v_generacion_detalle
WHERE fuente IN ('RAD SOLAR', 'VIENTO')
WINDOW w AS (PARTITION BY fuente ORDER BY anio, mes)
ORDER BY fuente, anio, mes;

-- Q7. (CTE + subconsulta) Meses en que la termica (CARBON + GAS) supero
--     su promedio historico: senal de sequia / El Nino
WITH termica AS (
    SELECT anio, mes, sum(total_gwh) AS gwh
    FROM v_generacion_detalle
    WHERE fuente IN ('CARBON', 'GAS')
    GROUP BY anio, mes
)
SELECT anio, mes, round(gwh, 2) AS termica_gwh,
       round(gwh / (SELECT avg(gwh) FROM termica), 2) AS veces_promedio
FROM termica
WHERE gwh > (SELECT avg(gwh) FROM termica) * 1.3
ORDER BY veces_promedio DESC;

-- Q8. (JOIN con fuente JSON) Correlacion lluvia vs generacion hidraulica
SELECT z.nombre AS zona,
       round(corr(c.precipitacion_mm, g.total_gwh)::numeric, 3) AS correlacion,
       count(*) AS meses
FROM clima_mensual c
JOIN zona_climatica z    ON z.id = c.zona_id
JOIN generacion_mensual g ON g.periodo_id = c.periodo_id
JOIN fuente_energia f     ON f.id = g.fuente_id AND f.codigo = 'AGUA'
GROUP BY z.nombre;

-- Q9. (JOIN multiple + LEFT JOIN) Plantas, operador vigente y proximo mantenimiento
SELECT v.planta, v.fuente, v.operador, v.estado,
       min(lower(m.ventana)) FILTER (WHERE lower(m.ventana) > now()) AS proximo_mantenimiento,
       count(m.id) AS mantenimientos_registrados
FROM v_plantas_operador_vigente v
JOIN planta pl ON pl.nombre = v.planta
LEFT JOIN mantenimiento_planta m ON m.planta_id = pl.id
GROUP BY v.planta, v.fuente, v.operador, v.estado
ORDER BY v.planta;

-- Q10. (Telemetria + HAVING) Sensores con mas de 1% de lecturas en FALLA por mes
SELECT pl.nombre AS planta, s.tipo, date_trunc('month', l.fecha_hora)::date AS mes,
       count(*) FILTER (WHERE l.calidad = 'FALLA') AS fallas,
       count(*) AS lecturas,
       round(100.0 * count(*) FILTER (WHERE l.calidad = 'FALLA') / count(*), 2) AS pct_falla
FROM lectura_sensor l
JOIN sensor s  ON s.id = l.sensor_id
JOIN planta pl ON pl.id = s.planta_id
WHERE l.fecha_hora >= '2026-01-01'
GROUP BY pl.nombre, s.tipo, date_trunc('month', l.fecha_hora)
HAVING 100.0 * count(*) FILTER (WHERE l.calidad = 'FALLA') / count(*) > 1
ORDER BY pct_falla DESC
LIMIT 20;

-- Q11. (Telemetria + ventana) Potencia promedio diaria de una planta y su
--      diferencia contra el dia anterior (consulta pesada para el tuning)
SELECT dia, round(prom, 2) AS potencia_prom,
       round(prom - LAG(prom) OVER (ORDER BY dia), 2) AS vs_dia_anterior
FROM (
    SELECT date_trunc('day', l.fecha_hora) AS dia, avg(l.valor) AS prom
    FROM lectura_sensor l
    JOIN sensor s  ON s.id = l.sensor_id AND s.tipo = 'POTENCIA'
    JOIN planta pl ON pl.id = s.planta_id AND pl.nombre = 'Hidroituango'
    WHERE l.fecha_hora BETWEEN '2026-06-01' AND '2026-08-31'
    GROUP BY 1
) d
ORDER BY dia;

-- Q12. Participacion renovable por anio (usa la vista V3) y su posicion
SELECT anio, round(avg(pct), 2) AS pct_renovable_prom,
       DENSE_RANK() OVER (ORDER BY avg(pct) DESC) AS puesto_mas_renovable
FROM v_participacion_categoria_mensual
WHERE categoria = 'RENOVABLE'
GROUP BY anio
ORDER BY anio;
