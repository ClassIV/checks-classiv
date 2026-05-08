# Railway-compatible Dockerfile for checks.classiv.com.
# Mirrors docker/Dockerfile (upstream) but replaces `--mount=type=bind` with
# explicit COPY from the builder stage, since Railway's metal builder only
# supports `type=cache` mounts.

FROM python:3.14.4-slim-trixie AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY requirements.txt /tmp
RUN \
    apt-get update && \
    apt-get install -y build-essential libffi-dev libpq-dev libmariadb-dev libcurl4-openssl-dev pkg-config
RUN pip wheel --wheel-dir /wheels apprise uwsgi mysqlclient minio==7.2.20 "psycopg[c]" -r /tmp/requirements.txt

COPY . /opt/healthchecks/
RUN \
    rm -rf /opt/healthchecks/.git && \
    rm -rf /opt/healthchecks/stuff

FROM python:3.14.4-slim-trixie

RUN useradd --system hc
ENV PYTHONUNBUFFERED=1
WORKDIR /opt/healthchecks

RUN \
    apt-get update && \
    apt-get install -y libcurl4t64 libpq5 libmariadb3 && \
    rm -rf /var/apt/cache && \
    rm -rf /var/lib/apt/lists

COPY --from=builder /wheels /tmp/wheels
RUN \
    pip install --upgrade pip && \
    pip install --no-cache /tmp/wheels/*.whl && \
    rm -rf /tmp/wheels

COPY --from=builder /opt/healthchecks/ /opt/healthchecks/
COPY docker/fetchstatus.py /opt/healthchecks/

RUN \
    rm -f /opt/healthchecks/hc/local_settings.py && \
    DEBUG=False SECRET_KEY=build-key ./manage.py collectstatic --noinput && \
    DEBUG=False SECRET_KEY=build-key ./manage.py compress

RUN mkdir /data && chown hc /data

USER hc

ENV USE_GZIP_MIDDLEWARE=True
HEALTHCHECK --start-period=20s --start-interval=5s --interval=60s --retries=1 CMD ./fetchstatus.py
CMD [ "uwsgi", "/opt/healthchecks/docker/uwsgi.ini"]
