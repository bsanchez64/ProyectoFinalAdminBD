"""
clima.py - Fuente 2 (API/JSON): descarga clima diario historico de Open-Meteo
y lo carga crudo en staging.clima_json (una fila por zona, JSONB).

Uso (desde la raiz del repo):
    pip install requests psycopg2-binary
    python etl/clima.py --host localhost --port 5432 --user postgres --password ***** --db energia_co

Si el JSON ya existe en data/raw/ no lo vuelve a descargar (use --forzar para hacerlo).
"""
import argparse
import json
from pathlib import Path

import psycopg2
import requests

URL = "https://archive-api.open-meteo.com/v1/archive"
VARIABLES = "precipitation_sum,shortwave_radiation_sum,wind_speed_10m_max"

# Zonas elegidas segun la fuente de energia que mas influyen (coordenadas aproximadas)
ZONAS = [
    # nombre,                     lat,     lon,    fuente relacionada
    ("Oriente Antioqueno",        6.22,   -75.18, "AGUA"),       # embalses Guatape / San Carlos
    ("Guavio Cundinamarca",       4.78,   -73.38, "AGUA"),
    ("Alta Guajira",             11.71,   -72.27, "VIENTO"),
    ("Cesar Centro",              9.66,   -73.75, "RAD SOLAR"),
]

RAIZ = Path(__file__).resolve().parent.parent
CARPETA = RAIZ / "data" / "raw"


def slug(nombre: str) -> str:
    return nombre.lower().replace(" ", "_")


def descargar(nombre, lat, lon, inicio, fin, forzar=False) -> dict:
    archivo = CARPETA / f"clima_{slug(nombre)}.json"
    if archivo.exists() and not forzar:
        print(f"[cache] {archivo.name}")
        return json.loads(archivo.read_text(encoding="utf-8"))
    params = {
        "latitude": lat, "longitude": lon,
        "start_date": inicio, "end_date": fin,
        "daily": VARIABLES, "timezone": "America/Bogota",
    }
    r = requests.get(URL, params=params, timeout=120)
    r.raise_for_status()
    datos = r.json()
    archivo.write_text(json.dumps(datos), encoding="utf-8")
    print(f"[ok] {archivo.name}: {len(datos['daily']['time'])} dias")
    return datos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", default="5432")
    ap.add_argument("--user", default="postgres")
    ap.add_argument("--password", default="")
    ap.add_argument("--db", default="energia_co")
    ap.add_argument("--inicio", default="2000-01-01")
    ap.add_argument("--fin", default="2026-08-31")   # ultimo mes del CSV de generacion
    ap.add_argument("--forzar", action="store_true")
    a = ap.parse_args()

    CARPETA.mkdir(parents=True, exist_ok=True)
    conn = psycopg2.connect(host=a.host, port=a.port, user=a.user,
                            password=a.password, dbname=a.db)
    with conn, conn.cursor() as cur:
        for nombre, lat, lon, fuente in ZONAS:
            datos = descargar(nombre, lat, lon, a.inicio, a.fin, a.forzar)
            cur.execute(
                """
                INSERT INTO staging.clima_json (zona, latitud, longitud, fuente_codigo, payload)
                VALUES (%s, %s, %s, %s, %s::jsonb)
                ON CONFLICT (zona) DO UPDATE
                   SET payload = EXCLUDED.payload, descargado_en = now()
                """,
                (nombre, lat, lon, fuente, json.dumps(datos)),
            )
    conn.close()
    print("Listo: staging.clima_json cargada.")


if __name__ == "__main__":
    main()
