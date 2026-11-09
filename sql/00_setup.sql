-- =====================================================================
-- 00_setup.sql  -  Extensiones y esquemas
-- Correr conectado a la BD energia_co (createdb energia_co)
-- =====================================================================

-- btree_gist: permite usar columnas normales (=) junto con rangos (&&)
-- dentro de una restriccion EXCLUDE USING gist.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- staging: datos crudos tal cual llegan de cada fuente (todo TEXT/JSONB)
-- energia: modelo limpio y normalizado con todas las reglas de negocio
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS energia;

SET search_path TO energia, public;
