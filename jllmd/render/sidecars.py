"""Optional monitoring sidecar container definitions for rendered vLLM pods."""

from __future__ import annotations


def sidecars(names: list[str], *, dcgm_config_name: str = "dcgm-custom-metrics") -> tuple[list[dict], list[dict]]:
    containers: list[dict] = []
    volumes: list[dict] = []
    if "dcgm-exporter" in names:
        volumes.append(
            {
                "name": "dcgm-metrics",
                "configMap": {"name": dcgm_config_name},
            }
        )
        containers.append(
            {
                "name": "dcgm-exporter",
                "image": "nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04",
                "imagePullPolicy": "IfNotPresent",
                "args": ["-f", "/etc/dcgm-exporter/custom-counters.csv"],
                "ports": [{"containerPort": 9400, "name": "dcgm", "protocol": "TCP"}],
                "env": [
                    {"name": "NVIDIA_VISIBLE_DEVICES", "value": "all"},
                    {"name": "NVIDIA_DRIVER_CAPABILITIES", "value": "utility"},
                    {"name": "DCGM_EXPORTER_KUBERNETES_GPU_ID_TYPE", "value": "uid"},
                ],
                "volumeMounts": [
                    {
                        "name": "dcgm-metrics",
                        "mountPath": "/etc/dcgm-exporter/custom-counters.csv",
                        "subPath": "custom-counters.csv",
                        "readOnly": True,
                    }
                ],
                "resources": {
                    "requests": {"cpu": "250m", "memory": "512Mi"},
                    "limits": {"memory": "512Mi"},
                },
                "securityContext": {"allowPrivilegeEscalation": False},
            }
        )
    if "node-exporter" in names:
        containers.append(
            {
                "name": "node-exporter",
                "image": "quay.io/prometheus/node-exporter:v1.9.0",
                "imagePullPolicy": "IfNotPresent",
                "args": [
                    "--collector.disable-defaults",
                    "--collector.infiniband",
                    "--collector.netstat",
                    "--collector.pressure",
                    "--collector.schedstat",
                    "--collector.cpu",
                    "--path.sysfs=/host/sys",
                    "--path.procfs=/host/proc",
                ],
                "ports": [{"containerPort": 9100, "name": "node-metrics", "protocol": "TCP"}],
                "volumeMounts": [
                    {"name": "sys", "mountPath": "/host/sys", "readOnly": True},
                    {"name": "proc", "mountPath": "/host/proc", "readOnly": True},
                ],
                "resources": {
                    "requests": {"cpu": "50m", "memory": "64Mi"},
                    "limits": {"memory": "64Mi"},
                },
                "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True},
            }
        )
    return containers, volumes
