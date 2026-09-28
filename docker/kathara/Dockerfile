FROM python:3.13-slim-bookworm

ARG KATHARA_VERSION=3.8.3

RUN python -m pip install --no-cache-dir "kathara==${KATHARA_VERSION}"

COPY patch-docker-resources.py /tmp/patch-docker-resources.py
RUN python /tmp/patch-docker-resources.py \
    && rm /tmp/patch-docker-resources.py \
    && python -m compileall -q /usr/local/lib/python3.13/site-packages/Kathara/manager/docker/DockerMachine.py

COPY kathara.conf /root/.config/kathara.conf

ENTRYPOINT ["python", "-m", "kathara"]
CMD ["--help"]
