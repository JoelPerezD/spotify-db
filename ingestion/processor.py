"""Lo ejecuta cron cada 5 minutos (ingestion/crontab). En cada corrida:

1. Lee las lineas del crudo que no ha procesado, segun ingestion_checkpoint.
2. Quita los duplicados por event_id (regla 2).
3. Se queda con las reproducciones validas: ms_played >= 30000 (regla 1).
4. Suma los conteos en subscriber_song_play y song_daily_play (dia en UTC, regla 3).
5. Anota en /app/logs/processor.log cuantos mensajes leyo, cuantos descarto y por que.

Duplicados: un duplicado llega a Kafka, a lo mas, 5 minutos despues que el original. El crudo
tiene un archivo por hora de llegada, asi que el original de un mensaje de la hora H esta en
el archivo de H o en el de H-1. Para reconocer duplicados entre corridas, el processor relee
los event_id ya procesados de esas dos horas; no necesita guardarlos en otro lado.

Todo, incluido el avance del checkpoint, va en UNA transaccion: si algo falla, no se aplica
nada y la siguiente corrida vuelve a intentar las mismas lineas. Ningun mensaje se guarda en
PostgreSQL: solo los conteos y la posicion leida de cada archivo.

Lo que imprime un programa que ejecuta cron no aparece en ningun lado, por eso todo se
escribe en el log."""

import json
import logging
import os
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg

LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "processor.log")],  # sin consola: cron no la muestra
)
log = logging.getLogger("processor")

MIN_VALID_MS = 30_000
LOCK_KEY = 2026_11_04  # candado de PostgreSQL: evita dos corridas a la vez si una tarda mas de 5 min
MAX_EXAMPLES = 3       # cuantas lineas malformadas se copian al log como ejemplo

UPSERT_SUBSCRIBER = """
    INSERT INTO subscriber_song_play (subscriber_id, song_id, num_rep) VALUES (%s, %s, %s)
    ON CONFLICT (subscriber_id, song_id)
    DO UPDATE SET num_rep = subscriber_song_play.num_rep + EXCLUDED.num_rep
"""
UPSERT_DAILY = """
    INSERT INTO song_daily_play (song_id, play_date, num_rep) VALUES (%s, %s, %s)
    ON CONFLICT (song_id, play_date)
    DO UPDATE SET num_rep = song_daily_play.num_rep + EXCLUDED.num_rep
"""
UPSERT_CHECKPOINT = """
    INSERT INTO ingestion_checkpoint (file_name, byte_offset) VALUES (%s, %s)
    ON CONFLICT (file_name) DO UPDATE SET byte_offset = EXCLUDED.byte_offset, updated_at = now()
"""


def parse(line):
    """Convierte una linea del crudo en una reproduccion, o None si no respeta el formato 2.3."""
    try:
        msg = json.loads(line)
        event_id, played_at = msg["event_id"], msg["played_at"]
        subscriber_id, song_id, ms_played = msg["subscriber_id"], msg["song_id"], msg["ms_played"]
        played = datetime.fromisoformat(played_at)
    except (ValueError, TypeError, KeyError):  # JSON roto, falta un campo o played_at invalido
        return None
    ints = (subscriber_id, song_id, ms_played)
    if (not isinstance(event_id, str) or not event_id
            or any(not isinstance(v, int) or isinstance(v, bool) for v in ints)
            or ms_played < 0 or played.tzinfo is None):  # sin zona horaria no se puede pasar a UTC
        return None
    return {
        "event_id": event_id,
        "subscriber_id": subscriber_id,
        "song_id": song_id,
        "ms_played": ms_played,
        "play_date": played.astimezone(timezone.utc).date(),  # regla 3: el dia es en UTC
    }


def read_lines(path, start, end):
    """Las lineas completas entre los bytes start y end. Si el consumer esta escribiendo la
    ultima linea, se deja para la siguiente corrida. Regresa (lineas, byte donde terminaron)."""
    with path.open("rb") as f:
        f.seek(start)
        data = f.read(end - start)
    complete = data[: data.rfind(b"\n") + 1]
    return complete.splitlines(), start + len(complete)


def file_hour(path):
    return datetime.strptime(path.stem, "%Y-%m-%dT%H")


def run(conn, raw_dir):
    if not conn.execute("SELECT pg_try_advisory_xact_lock(%s)", (LOCK_KEY,)).fetchone()[0]:
        log.warning("Otra corrida del processor sigue trabajando; esta se salta")
        return

    # Solo archivos con nombre de hora (AAAA-MM-DDTHH.log); ordenarlos por nombre es ordenarlos por llegada.
    files = sorted(raw_dir.glob("[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9].log"))
    checkpoint = dict(conn.execute("SELECT file_name, byte_offset FROM ingestion_checkpoint"))

    # 1. Lineas nuevas de cada archivo, desde donde se quedo la corrida anterior.
    new_batches = []
    for path in files:
        start = checkpoint.get(path.name, 0)
        lines, end = read_lines(path, start, path.stat().st_size)
        if lines:
            new_batches.append((path, lines, end))
    if not new_batches:
        log.info("Corrida sin mensajes nuevos (%s archivos en el crudo)", len(files))
        return

    # 2. event_id ya procesados que pueden tener duplicados en este lote: horas H y H-1.
    hours = {file_hour(p) + delta for p, _, _ in new_batches for delta in (timedelta(0), timedelta(hours=-1))}
    seen = set()
    for path in files:
        if file_hour(path) in hours and checkpoint.get(path.name, 0) > 0:
            old_lines, _ = read_lines(path, 0, checkpoint[path.name])
            seen.update(e["event_id"] for e in map(parse, old_lines) if e)

    # 3. Filtrar: formato, duplicados, skips e ids que no existen en la base de datos.
    subscribers = {r[0] for r in conn.execute("SELECT subscriber_id FROM subscribers")}
    songs = {r[0] for r in conn.execute("SELECT song_id FROM songs")}
    stats = Counter()
    per_subscriber, per_day = Counter(), Counter()
    for path, lines, _ in new_batches:
        for line in lines:
            stats["leidos"] += 1
            play = parse(line)
            if play is None:
                stats["malformados"] += 1
                if stats["malformados"] <= MAX_EXAMPLES:
                    log.warning("Linea malformada en %s: %r", path.name, line[:200])
                continue
            if play["event_id"] in seen:
                stats["duplicados"] += 1
                continue
            seen.add(play["event_id"])
            if play["ms_played"] < MIN_VALID_MS:
                stats["skips"] += 1
                continue
            if play["subscriber_id"] not in subscribers or play["song_id"] not in songs:
                # Otro productor podria mandar ids que no existen; la llave foranea rechazaria todo el lote.
                stats["ids_inexistentes"] += 1
                continue
            stats["validas"] += 1
            per_subscriber[(play["subscriber_id"], play["song_id"])] += 1
            per_day[(play["song_id"], play["play_date"])] += 1

    # 4. Conteos y checkpoint en la misma transaccion (el COMMIT lo hace el with de main).
    with conn.cursor() as cur:
        cur.executemany(UPSERT_SUBSCRIBER, [(s, g, n) for (s, g), n in per_subscriber.items()])
        cur.executemany(UPSERT_DAILY, [(g, d, n) for (g, d), n in per_day.items()])
        cur.executemany(UPSERT_CHECKPOINT, [(p.name, end) for p, _, end in new_batches])

    log.info(
        "Corrida: %s leidos de %s; %s validas; descartados: %s duplicados, %s skips, %s malformados, "
        "%s con ids inexistentes; filas actualizadas: %s en subscriber_song_play, %s en song_daily_play",
        stats["leidos"], ", ".join(p.name for p, _, _ in new_batches), stats["validas"],
        stats["duplicados"], stats["skips"], stats["malformados"], stats["ids_inexistentes"],
        len(per_subscriber), len(per_day),
    )


def main():
    try:
        # cron no les pasa a sus trabajos las variables del contenedor: llegan porque el command
        # del servicio processor las copia a /etc/environment antes de iniciar cron.
        raw_dir = Path("/app/data/raw") / os.environ["KAFKA_TOPIC"]
        conninfo = dict(
            host=os.environ["POSTGRES_HOST"],
            dbname=os.environ["POSTGRES_DB"],
            user=os.environ["POSTGRES_USER"],
            password=os.environ["POSTGRES_PASSWORD"],
        )
    except KeyError as e:
        log.error("Falta la variable de entorno %s: revisa environment: del servicio processor "
                  "y que su command la copie a /etc/environment", e)
        sys.exit(1)

    if not raw_dir.exists():
        # Error conocido: el consumer todavia no ha guardado ningun mensaje.
        log.warning("El crudo %s todavia no existe", raw_dir)
        return
    try:
        with psycopg.connect(**conninfo) as conn:  # una transaccion: COMMIT al salir, ROLLBACK si hay error
            run(conn, raw_dir)
    except psycopg.OperationalError as e:
        log.error("No se pudo conectar a PostgreSQL; la siguiente corrida lo vuelve a intentar: %s", e)
        sys.exit(1)
    except Exception:
        log.exception("Error inesperado en la corrida; no se aplico ningun cambio (ROLLBACK)")
        sys.exit(1)


if __name__ == "__main__":
    main()
