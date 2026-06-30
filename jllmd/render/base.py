"""Base Kubernetes objects shared by full deployment renders."""

from __future__ import annotations

from ..instance import Instance


def render_service_account(instance: Instance) -> dict:
    return {
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "metadata": {"name": instance.name("model-server"), "labels": instance.labels("model-server")},
    }


def render_dcgm_metrics_configmap(instance: Instance) -> dict:
    return {
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
