# ProyectoFinalAdminBD
Sistema Energético Colombia — Producción de electricidad por fuente de combustible.
Administración de Bases de Datos (ED1302) · PostgreSQL local + AWS RDS.

## Estructura

```
data/raw/generacion_por_fuente.csv  Fuente 1 (CSV)  - datos.gov.co, 2.786 filas, ene-2000 a ago-2026
data/raw/clima_*.json               Fuente 2 (JSON) - API Open-Meteo, la crea etl/clima.py
data/raw/operadores_plantas.csv     Fuente 3 (maestra) - plantas y operadores (datos de PARATEC/XM)
docs/mer.png, docs/mer.mmd          Diagrama entidad-relación
etl/clima.py                        Descarga el clima y lo carga en staging.clima_json
sql/00_setup.sql                    Extensión btree_gist + esquemas staging y energia
sql/01_ddl.sql                      Tablas con PK, FK, UNIQUE, CHECK y EXCLUDE
sql/02_staging.sql                  Tablas de aterrizaje + \copy de los CSV
sql/03_reglas.sql                   Triggers PL/pgSQL (R1..R5)
sql/04_carga_modelo.sql             staging -> modelo (idempotente)
sql/05_datos_sinteticos.sql         Sensores, mantenimientos y ~2,2 M lecturas (para el tuning)
sql/06_vistas_consultas.sql         4 vistas + 12 consultas (HAVING, ventanas, JOINs, CTE)
sql/07_pruebas_reglas.sql           Casos que deben fallar, uno por regla
```

## Cómo correrlo (desde la raíz del repo)

Requisitos: PostgreSQL 16 (misma versión que usaremos en RDS) y Python 3.

```bash
createdb -U postgres energia_co

psql -U postgres -d energia_co -v ON_ERROR_STOP=1 -f sql/00_setup.sql
psql -U postgres -d energia_co -v ON_ERROR_STOP=1 -f sql/01_ddl.sql
psql -U postgres -d energia_co -v ON_ERROR_STOP=1 -f sql/02_staging.sql

pip install requests psycopg2-binary
python etl/clima.py --user postgres --password TU_CLAVE --db energia_co

psql -U postgres -d energia_co -v ON_ERROR_STOP=1 -f sql/03_reglas.sql
psql -U postgres -d energia_co -v ON_ERROR_STOP=1 -f sql/04_carga_modelo.sql
psql -U postgres -d energia_co -v ON_ERROR_STOP=1 -f sql/05_datos_sinteticos.sql
psql -U postgres -d energia_co -f sql/06_vistas_consultas.sql
psql -U postgres -d energia_co -f sql/07_pruebas_reglas.sql
```

En Windows: si `psql` no se reconoce, agregue `C:\Program Files\PostgreSQL\16\bin` al PATH.
Si el `\copy` da error de codificación, ejecute antes `SET client_encoding TO 'UTF8';` o `chcp 65001` en la consola.

Para empezar de cero: `dropdb -U postgres energia_co` y repetir.

## Reglas de negocio implementadas

| Regla | Tipo | Dónde |
| --- | --- | --- |
| mes 1..12, año 2000..2100, fecha coherente | CHECK | periodo |
| mínimo ≤ promedio ≤ máximo; % entre 0 y 100 | CHECK | generacion_mensual |
| una fila por fuente y mes | UNIQUE | generacion_mensual |
| estados válidos de planta y sensor | CHECK | planta, sensor |
| coordenadas dentro de Colombia | CHECK | zona_climatica |
| una planta no tiene dos operadores a la vez | EXCLUDE (gist) | operacion_planta |
| mantenimientos de una planta no se solapan | EXCLUDE (gist) | mantenimiento_planta |
| R1 total ≤ promedio × días del mes | Trigger | generacion_mensual |
| R2 la participación del mes suma 100 % | Constraint trigger diferido | generacion_mensual |
| R3 sin lecturas de sensor inactivo ni en mantenimiento | Trigger | lectura_sensor |
| R4 planta retirada no recibe operador nuevo | Trigger | operacion_planta |
| R5 auditoría de cambios | Trigger | generacion_mensual, planta, operacion_planta |

## Pendientes antes de la Entrega 1

- `data/raw/operadores_plantas.csv` tiene 13 plantas con capacidad, fecha de puesta en operación (FPO) y estado tomados de PARATEC (XM) el 09-11-2026.
  `vigencia_desde` es la FPO de la planta (simplificación: el operador actual pudo llegar después).
  Termozipa suma sus unidades ZIPAEMG 2 a 5. Jepírachi está RETIRADA (desconectada del SIN el 2023-10-09).
- Los datos de `05_datos_sinteticos.sql` son generados; decirlo así en el informe.

## Para la Entrega 2 (AWS RDS)

```bash
pg_dump -U postgres -Fc -d energia_co -f energia_co.dump
```
