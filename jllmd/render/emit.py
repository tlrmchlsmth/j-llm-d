"""Top-level render pipeline that emits one YAML-ready object list per deployment."""

from __future__ import annotations

import io

import yaml

from .base import render_dcgm_metrics_configmap, render_service_account
from .lws import render_lws
from .routing import render_routing
from ..cluster import Cluster
from ..instance import Instance
from ..spec import DeploymentSpec


def render(spec: DeploymentSpec, *, user: str, cluster: Cluster, routing_only: bool = False) -> list[dict]:
    instance = Instance(user=user, release=spec.release)
    if routing_only:
        return render_routing(spec, instance, cluster)

    objects = [render_service_account(instance)]
    if any("dcgm-exporter" in spec.runtime.sidecars for _role in spec.roles):
        objects.append(render_dcgm_metrics_configmap(instance))
    for role in spec.roles:
        objects.append(render_lws(spec, instance, cluster, role))
    objects.extend(render_routing(spec, instance, cluster))
    return objects


def render_to_yaml(objects: list[dict], *, header: list[str] | None = None) -> str:
    stream = io.StringIO()
    for line in header or []:
        stream.write(f"# {line}\n")
    yaml.safe_dump_all(objects, stream, sort_keys=False, explicit_start=True)
    return stream.getvalue()
