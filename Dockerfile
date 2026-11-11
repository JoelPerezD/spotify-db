# Imagen de los tres programas de la ingesta: producer, consumer y processor.
# Cada servicio de docker-compose.yml elige cual ejecuta con su command:.

# Linux Debian minimo con Python 3.13, la version fijada en .python-version
FROM python:3.13-slim

# cron ejecuta el processor cada 5 minutos (ingestion/crontab).
# El sed cambia los repositorios de Debian de http:// a https://: en algunas redes
# un proxy o antivirus altera el HTTP sin cifrar y apt-get falla con "Bad header line".
RUN sed -i 's#http://#https://#g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update && apt-get install -y --no-install-recommends cron && rm -rf /var/lib/apt/lists/*

# uv instala las librerias exactas de uv.lock
RUN pip install --no-cache-dir uv

# Lo que Python escribe en la consola aparece de inmediato en docker compose logs
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Primero las dependencias y despues el codigo: editar un .py no reinstala las librerias
COPY pyproject.toml uv.lock ./
RUN uv sync --locked

# El codigo: app_simulator/ simula la app (otro equipo) e ingestion/ es nuestro sistema
COPY app_simulator/ app_simulator/
COPY ingestion/ ingestion/

# Instala el horario del processor como el de root, el usuario de los contenedores
RUN crontab ingestion/crontab
