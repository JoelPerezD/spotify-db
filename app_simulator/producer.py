"""Simula la app de Spotify: cada INTERVAL_SECONDS segundos alguien reproduce una cancion
y se publica en Kafka un mensaje con el formato fijo de las reproducciones:
{"event_id", "subscriber_id", "song_id", "played_at" (ISO 8601 con zona horaria), "ms_played"}.

Para que la ingesta tenga casos dificiles, el simulador genera:
- skips: una proporcion SKIP_RATE de mensajes con ms_played < 30000;
- duplicados: una proporcion DUPLICATE_RATE se vuelve a enviar, identica, entre 0 y
  MAX_DUPLICATE_DELAY_SECONDS segundos despues del original;
- modo sin conexion: played_at es un momento al azar de los ultimos MAX_PLAY_AGE_DAYS dias,
  con la zona horaria del telefono (no siempre UTC).

Cada original que Kafka confirma se anota en /app/sent/sent.log (sin duplicados): es la
referencia de verify.py. Cada accion y cada error se anotan en /app/logs/producer.log."""

import heapq
import itertools
import json
import logging
import os
import random
import signal
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
from confluent_kafka import Producer

LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "producer.log"), logging.StreamHandler()],
)
log = logging.getLogger("producer")

SENT_FILE = Path("/app/sent/sent.log")
# Duplicados programados: (momento de envio, desempate, mensaje). heapq entrega primero el mas proximo.
pending_duplicates = []
tie_breaker = itertools.count()
MIN_VALID_MS = 30_000  # menos de 30 s es un skip: no cuenta como reproduccion
# Zonas horarias de los telefonos simulados. El processor las pasa a UTC (los dias se definen en UTC).
PHONE_TIMEZONES = [timezone(timedelta(hours=h)) for h in (-7, -6, -5, -3, 0, 1)]


def read_config():
    """Lee y valida la configuracion del .env (llega por environment: del compose)."""
    config = {
        "topic": os.environ["KAFKA_TOPIC"],
        "bootstrap_servers": os.environ["KAFKA_BOOTSTRAP_SERVERS"],
        "interval": float(os.environ["INTERVAL_SECONDS"]),
        "skip_rate": float(os.environ["SKIP_RATE"]),
        "duplicate_rate": float(os.environ["DUPLICATE_RATE"]),
        "max_duplicate_delay": float(os.environ["MAX_DUPLICATE_DELAY_SECONDS"]),
        "max_play_age_days": float(os.environ["MAX_PLAY_AGE_DAYS"]),
    }
    if config["interval"] <= 0:
        raise ValueError("INTERVAL_SECONDS debe ser mayor que 0")
    for name in ("skip_rate", "duplicate_rate"):
        if not 0 <= config[name] <= 1:
            raise ValueError(f"{name.upper()} debe estar entre 0 y 1")
    if not 0 <= config["max_duplicate_delay"] <= 300:
        raise ValueError("MAX_DUPLICATE_DELAY_SECONDS debe estar entre 0 y 300")
    if config["max_play_age_days"] <= 0:
        raise ValueError("MAX_PLAY_AGE_DAYS debe ser mayor que 0")
    return config


def read_catalog():
    """Lee de PostgreSQL los suscriptores y las canciones que existen, con su duracion en ms."""
    with psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    ) as conn:
        subscriber_ids = [r[0] for r in conn.execute("SELECT subscriber_id FROM subscribers ORDER BY 1")]
        durations = dict(
            conn.execute("SELECT song_id, (EXTRACT(EPOCH FROM duration) * 1000)::int FROM songs ORDER BY 1")
        )
    return subscriber_ids, durations


def new_play(subscriber_ids, durations, config):
    """Inventa una reproduccion con el formato fijo de los mensajes."""
    song_id = random.choice(list(durations))
    if random.random() < config["skip_rate"]:
        ms_played = random.randint(0, MIN_VALID_MS - 1)
    else:
        ms_played = random.randint(MIN_VALID_MS, max(MIN_VALID_MS, durations[song_id]))
    age = timedelta(seconds=random.uniform(0, config["max_play_age_days"] * 86_400))
    played_at = (datetime.now(timezone.utc) - age).astimezone(random.choice(PHONE_TIMEZONES))
    return {
        "event_id": str(uuid.uuid4()),
        "subscriber_id": random.choice(subscriber_ids),
        "song_id": song_id,
        "played_at": played_at.replace(microsecond=0).isoformat(),
        "ms_played": ms_played,
    }


def report_original(err, msg):
    """Kafka llama a esta funcion cuando confirma, o no, que guardo un original."""
    value = msg.value().decode("utf-8")
    if err is not None:
        log.error("Kafka no guardo el mensaje %s: %s", value, err)
        return
    # Solo lo que Kafka confirmo entra a sent.log: si no, verify.py esperaria mensajes que nunca llegaron.
    with SENT_FILE.open("a", encoding="utf-8") as sent:
        sent.write(value + "\n")
    log.info("Enviado (offset %s): %s", msg.offset(), value)
    # El duplicado se programa hasta aqui, con el original ya guardado: si se programara al enviarlo
    # y Kafka no lo confirmara, se contaria un duplicado cuyo original no esta en sent.log.
    if random.random() < config["duplicate_rate"]:
        send_at = time.monotonic() + random.uniform(0, config["max_duplicate_delay"])
        heapq.heappush(pending_duplicates, (send_at, next(tie_breaker), value))


def report_duplicate(err, msg):
    value = msg.value().decode("utf-8")
    if err is not None:
        log.error("Kafka no guardo el duplicado %s: %s", value, err)
    else:
        log.info("Duplicado enviado (offset %s): %s", msg.offset(), value)


def stop(signum, frame):
    # docker compose stop manda SIGTERM. Salimos limpio para enviar lo pendiente (finally).
    raise SystemExit(0)


try:
    config = read_config()
    producer = Producer({"bootstrap.servers": config["bootstrap_servers"]})
    subscriber_ids, durations = read_catalog()
except KeyError as e:
    log.error("Falta la variable de entorno %s: revisa tu .env y environment: en docker-compose.yml", e)
    sys.exit(1)
except ValueError as e:
    log.error("Configuracion invalida en el .env: %s", e)
    sys.exit(1)
except psycopg.OperationalError as e:
    # Error conocido al iniciar: PostgreSQL todavia no acepta conexiones.
    # El programa termina con error y Docker lo vuelve a iniciar (restart: on-failure).
    log.error("No se pudo conectar a PostgreSQL; Docker volvera a iniciar el producer: %s", e)
    sys.exit(1)
except Exception:
    log.exception("Error inesperado al iniciar")
    sys.exit(1)

if not subscriber_ids or not durations:
    log.error("No hay suscriptores o canciones en la base de datos: no hay nada que simular")
    sys.exit(1)

SENT_FILE.parent.mkdir(parents=True, exist_ok=True)
signal.signal(signal.SIGTERM, stop)
log.info(
    "Publicando en %s cada %ss (skips %s, duplicados %s hasta %ss despues, played_at de los ultimos %s dias); "
    "suscriptores %s, canciones %s",
    config["topic"], config["interval"], config["skip_rate"], config["duplicate_rate"],
    config["max_duplicate_delay"], config["max_play_age_days"], subscriber_ids, list(durations),
)

next_play_at = time.monotonic()
try:
    while True:
        now = time.monotonic()
        while pending_duplicates and pending_duplicates[0][0] <= now:
            _, _, value = heapq.heappop(pending_duplicates)
            producer.produce(config["topic"], value=value, on_delivery=report_duplicate)
        if now >= next_play_at:
            value = json.dumps(new_play(subscriber_ids, durations, config))
            producer.produce(config["topic"], value=value, on_delivery=report_original)
            next_play_at += config["interval"]
        # poll() atiende las confirmaciones de Kafka (llama a report_*, que programa los duplicados)
        # mientras espera al siguiente envio.
        wake_at = min([next_play_at] + [d[0] for d in pending_duplicates[:1]])
        producer.poll(max(0.0, min(1.0, wake_at - time.monotonic())))
except SystemExit:
    log.info("Deteniendo el producer; %s duplicados programados no se enviaran", len(pending_duplicates))
except Exception:
    log.exception("Error inesperado; el producer termina y Docker lo volvera a iniciar")
    sys.exit(1)
finally:
    # Espera a que Kafka confirme lo que ya se puso en la cola, para que sent.log quede completo.
    producer.flush(10)
