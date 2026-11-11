"""Demuestra que los conteos de la base de datos coinciden con los eventos unicos enviados.

Comprueba, por cancion:
1. que las reproducciones validas de sent.log (ms_played >= 30000) son las que suma
   song_daily_play y las que suma subscriber_song_play;
2. que las dos tablas suman lo mismo entre si.

Muestra OK si todo coincide o la lista de diferencias, y termina con codigo 0 o 1.
Se ejecuta en el contenedor del processor, que monta el volumen de sent.log:
    docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py"""

import json
import logging
import os
import sys
from collections import Counter
from pathlib import Path

import psycopg

LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
# En verify.log cada linea lleva fecha, hora y nivel; en la consola solo el mensaje, para que la tabla se lea.
file_handler = logging.FileHandler(LOG_DIR / "verify.log")
file_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%dT%H:%M:%S%z"))
console_handler = logging.StreamHandler(sys.stdout)
console_handler.setFormatter(logging.Formatter("%(message)s"))
logging.basicConfig(level=logging.INFO, handlers=[file_handler, console_handler])
log = logging.getLogger("verify")

SENT_FILE = Path("/app/sent/sent.log")
MIN_VALID_MS = 30_000


def expected_from_sent():
    """Reproducciones validas por cancion segun sent.log (sin duplicados por construccion)."""
    expected, event_ids = Counter(), set()
    with SENT_FILE.open(encoding="utf-8") as sent:
        for line in sent:
            msg = json.loads(line)
            if msg["event_id"] in event_ids:  # por si acaso: sent.log no deberia repetir
                continue
            event_ids.add(msg["event_id"])
            if msg["ms_played"] >= MIN_VALID_MS:
                expected[msg["song_id"]] += 1
    return expected, len(event_ids)


def counts_from_db():
    with psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    ) as conn:
        daily = Counter(dict(conn.execute("SELECT song_id, sum(num_rep)::int FROM song_daily_play GROUP BY 1")))
        per_sub = Counter(dict(conn.execute("SELECT song_id, sum(num_rep)::int FROM subscriber_song_play GROUP BY 1")))
    return daily, per_sub


try:
    expected, unique_sent = expected_from_sent()
    daily, per_sub = counts_from_db()
except FileNotFoundError:
    log.error("No existe %s: el producer todavia no ha enviado nada o falta el volumen enviados", SENT_FILE)
    sys.exit(1)
except KeyError as e:
    log.error("Falta la variable de entorno %s: revisa environment: del servicio processor en docker-compose.yml", e)
    sys.exit(1)
except psycopg.OperationalError as e:
    log.error("No se pudo conectar a PostgreSQL: %s", e)
    sys.exit(1)
except Exception:
    log.exception("Error inesperado al leer %s o la base de datos", SENT_FILE)
    sys.exit(1)

log.info("sent.log: %s mensajes originales, %s reproducciones validas", unique_sent, sum(expected.values()))
log.info("song_daily_play: %s | subscriber_song_play: %s", sum(daily.values()), sum(per_sub.values()))
log.info("%-8s %10s %16s %21s", "song_id", "sent.log", "song_daily_play", "subscriber_song_play")

differences = []
for song_id in sorted(set(expected) | set(daily) | set(per_sub)):
    row = (expected[song_id], daily[song_id], per_sub[song_id])
    log.info("%-8s %10s %16s %21s", song_id, *row)
    if len(set(row)) > 1:
        differences.append((song_id, *row))

if differences:
    log.info("DIFERENCIAS (song_id, sent.log, song_daily_play, subscriber_song_play):")
    for diff in differences:
        log.info("  %s", diff)
    sys.exit(1)
log.info("OK")
