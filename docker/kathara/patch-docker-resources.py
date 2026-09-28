#!/usr/bin/env python3
"""Add project-scoped Docker GPU and CPU-set metadata to Kathara 3.8.3.

Kathara intentionally accepts unknown machine metadata, but its Docker manager
does not pass these three resource controls to the Docker SDK.  Keep this as a
small, fail-fast source transformation so a future Kathara update cannot apply
the patch silently to incompatible code.
"""

from pathlib import Path


TARGET = Path(
    "/usr/local/lib/python3.13/site-packages/"
    "Kathara/manager/docker/DockerMachine.py"
)


def replace_once(source: str, old: str, new: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(f"Expected one patch location, found {count}: {old!r}")
    return source.replace(old, new, 1)


text = TARGET.read_text(encoding="utf-8")

text = replace_once(
    text,
    "from docker.types import Ulimit\n",
    "from docker.types import DeviceRequest, Ulimit\n",
)

text = replace_once(
    text,
    """        ulimits = [Ulimit(name=k, soft=v[\"soft\"], hard=v[\"hard\"]) for k, v in machine.get_ulimits().items()]\n\n""",
    """        ulimits = [Ulimit(name=k, soft=v[\"soft\"], hard=v[\"hard\"]) for k, v in machine.get_ulimits().items()]\n\n        cpuset_cpus = machine.meta.get(\"cpuset_cpus\")\n        cpuset_mems = machine.meta.get(\"cpuset_mems\")\n\n        gpu_spec = str(machine.meta.get(\"gpus\", \"\")).strip()\n        device_requests = None\n        if gpu_spec and gpu_spec.lower() != \"none\":\n            if gpu_spec.lower() == \"all\":\n                request = DeviceRequest(count=-1, capabilities=[[\"gpu\"]])\n            else:\n                gpu_ids = [item.strip() for item in gpu_spec.split(\",\") if item.strip()]\n                if not gpu_ids:\n                    raise ValueError(f\"Invalid GPU selection for device `{machine.name}`: `{gpu_spec}`\")\n                request = DeviceRequest(device_ids=gpu_ids, capabilities=[[\"gpu\"]])\n            device_requests = [request]\n\n""",
)

text = replace_once(
    text,
    """                                                              nano_cpus=cpus,\n                                                              ports=ports,\n""",
    """                                                              nano_cpus=cpus,\n                                                              cpuset_cpus=cpuset_cpus,\n                                                              cpuset_mems=cpuset_mems,\n                                                              device_requests=device_requests,\n                                                              ports=ports,\n""",
)

TARGET.write_text(text, encoding="utf-8")
