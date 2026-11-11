"""Lee el topico de Kafka y guarda cada mensaje, tal cual, como una linea del crudo.

El crudo es un archivo por hora de llegada a Kafka, en UTC:
    /app/data/raw/<topico>/2026-11-10T22.log
La hora sale del timestamp que Kafka guarda con cada mensaje (LogAppendTime: la hora en que
llego al broker), no de played_at. Asi el processor sabe cuando llego cada mensaje (la regla
de duplicados se mide por la llegada) sin que el consumer modifique el contenido. El unico
cambio: un salto de linea dentro del mensaje se guarda como espacio (ver as_one_line).

Cada accion y cada error se anotan en /app/logs/consumer.log."""

import logging
import os
import signal
import sys
from datetime import datetime, timezone
from pathlib import Path

from confluent_kafka import TIMESTAMP_NOT_AVAILABLE, Consumer, KafkaError

LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "consumer.log"), logging.StreamHandler()],
)
log = logging.getLogger("consumer")


def raw_file_for(msg, raw_dir):
    """El archivo del crudo que corresponde a la hora (UTC) en que el mensaje llego a Kafka."""
    ts_type, ts_ms = msg.timestamp()
    if ts_type == TIMESTAMP_NOT_AVAILABLE:
        arrived = datetime.now(timezone.utc)
    else:
        arrived = datetime.fromtimestamp(ts_ms / 1000, timezone.utc)
    return raw_dir / f"{arrived:%Y-%m-%dT%H}.log"


def as_one_line(value):
    """El crudo guarda un mensaje por linea. En JSON un salto de linea solo puede ser espacio entre
    elementos (dentro de un texto va escapado como \\n), asi que cambiarlo por un espacio no cambia
    el significado del mensaje: un JSON con sangria de otro productor sigue siendo un solo mensaje."""
    return value.replace(b"\r", b" ").replace(b"\n", b" ")


def close_incomplete_line(raw_file):
    """Si el consumer murio a mitad de una escritura, el archivo termina sin salto de linea. Se
    cierra ese pedazo para que el mensaje que Kafka vuelve a entregar quede en su propia linea."""
    if raw_file.exists() and raw_file.stat().st_size > 0:
        with raw_file.open("rb+") as raw:
            raw.seek(-1, os.SEEK_END)
            if raw.read(1) != b"\n":
                raw.write(b"\n")
                log.warning("%s terminaba con una linea incompleta; se cerro para no mezclarla", raw_file.name)


def stop(signum, frame):
    # docker compose stop manda SIGTERM: salimos por el finally, que cierra el consumer.
    raise SystemExit(0)


try:
    topic = os.environ["KAFKA_TOPIC"]
    bootstrap_servers = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
except KeyError as e:
    log.error("Falta la variable de entorno %s: revisa tu .env y environment: en docker-compose.yml", e)
    sys.exit(1)

# /app/data es el volumen crudo, que el processor tambien ve.
raw_dir = Path("/app/data/raw") / topic
try:
    raw_dir.mkdir(parents=True, exist_ok=True)
    for existing in raw_dir.glob("*.log"):
        close_incomplete_line(existing)
except OSError:
    log.exception("No se pudo crear la carpeta del crudo %s; revisa el volumen crudo", raw_dir)
    sys.exit(1)

try:
    consumer = Consumer({
        "bootstrap.servers": bootstrap_servers,
        "group.id": "ingestion",
        "auto.offset.reset": "earliest",
        "allow.auto.create.topics": True,
        # La libreria confirma a Kafka cada pocos segundos hasta donde leimos. Por omision marca un
        # mensaje como leido en cuanto lo entrega; asi, si el programa muere antes de escribirlo,
        # ese mensaje se perderia. Con esto lo marcamos nosotros (store_offsets) despues de escribirlo.
        # Lo peor que puede pasar es escribir un mensaje dos veces, y el processor quita duplicados.
        "enable.auto.offset.store": False,
    })
    consumer.subscribe([topic])
except Exception:
    log.exception("Configuracion invalida del consumer; revisa KAFKA_BOOTSTRAP_SERVERS y KAFKA_TOPIC")
    sys.exit(1)
signal.signal(signal.SIGTERM, stop)
log.info("Suscrito al topico %s; el crudo se escribe en %s/<hora UTC>.log", topic, raw_dir)

try:
    while True:
        msg = consumer.poll(timeout=1.0)
        if msg is None:
            continue
        if msg.error():
            if msg.error().code() == KafkaError.UNKNOWN_TOPIC_OR_PART:
                # Error conocido al iniciar: el consumer se suscribio antes de que existiera el topico.
                log.warning("El topico %s todavia no existe; se crea automaticamente: %s", topic, msg.error())
            else:
                log.error("Kafka reporto un error: %s", msg.error())
            continue
        if msg.value() is None:
            log.warning("Mensaje vacio en el offset %s; no hay nada que guardar", msg.offset())
            consumer.store_offsets(msg)
            continue
        raw_file = raw_file_for(msg, raw_dir)
        # Modo "ab": se agrega al final, en bytes, como llego. Una linea por mensaje.
        with raw_file.open("ab") as raw:
            raw.write(as_one_line(msg.value()) + b"\n")
        consumer.store_offsets(msg)
        log.info("Guardado en %s (offset %s): %s", raw_file.name, msg.offset(), msg.value().decode("utf-8", "replace"))
except SystemExit:
    log.info("Deteniendo el consumer")
except OSError:
    # Error conocido: no se pudo escribir en el crudo (por ejemplo, el disco esta lleno).
    log.exception("No se pudo escribir en el crudo %s; el consumer termina", raw_dir)
    sys.exit(1)
except Exception:
    log.exception("Error inesperado; el consumer termina y Docker lo volvera a iniciar")
    sys.exit(1)
finally:
    consumer.close()  # confirma a Kafka el ultimo offset guardado
