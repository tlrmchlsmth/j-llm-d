"""Top-level render pipeline that emits one YAML-ready object list per deployment."""

from __future__ import annotations

import io

import yaml

from .lws import render_lws
from .routing import render_routing
from ..cluster import Cluster
from ..instance import Instance
from ..spec import DeploymentSpec


def render(spec: DeploymentSpec, *, user: str, cluster: Cluster, routing_only: bool = False) -> list[dict]:
    instance = Instance(user=user, release=spec.release)
    if routing_only:
        return render_routing(spec, instance, cluster)

    objects = [
        {
            "apiVersion": "v1",
            "kind": "ServiceAccount",
            "metadata": {"name": instance.name("model-server"), "labels": instance.labels("model-server")},
        }
    ]
    if any("dcgm-exporter" in spec.runtime.sidecars for _role in spec.roles):
        objects.append(
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {"name": instance.name("dcgm-metrics"), "labels": instance.labels("monitoring")},
                "data": {
                    "custom-counters.csv": "\n".join(
                        [
                            "DCGM_FI_PROF_NVLINK_TX_BYTES, gauge, NVLink transmit bytes per second",
                            "DCGM_FI_PROF_NVLINK_RX_BYTES, gauge, NVLink receive bytes per second",
                            "DCGM_FI_DEV_GPU_UTIL, gauge, GPU utilization",
                            "DCGM_FI_DEV_FB_USED, gauge, Framebuffer memory used",
                            "DCGM_FI_DEV_FB_FREE, gauge, Framebuffer memory free",
                        ]
                    )
                },
            }
        )
    for role in spec.roles:
        objects.append(render_lws(spec, instance, cluster, role))
    objects.extend(render_routing(spec, instance, cluster))
    return objects


def render_to_yaml(objects: list[dict]) -> str:
    stream = io.StringIO()
    yaml.safe_dump_all(objects, stream, sort_keys=False, explicit_start=True)
    return stream.getvalue()
