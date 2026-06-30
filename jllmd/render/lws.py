"""LeaderWorkerSet renderer for vLLM roles, including sidecars and fabric mounts."""

from __future__ import annotations

from .common import env_list, secret_env
from .sidecars import sidecars
from ..cluster import Cluster
from ..instance import Instance
from ..launch import build_launch_script
from ..resolve import resolve_role
from ..spec import DeploymentSpec, RoleSpec


def render_lws(spec: DeploymentSpec, instance: Instance, cluster: Cluster, role: RoleSpec) -> dict:
    resolved = resolve_role(spec, instance, cluster, role)

    containers, extra_volumes = sidecars(spec.runtime.sidecars, dcgm_config_name=instance.name("dcgm-metrics"))
    volumes = cluster.base_volumes()
    if role.shm_size:
        volumes[0]["emptyDir"]["sizeLimit"] = role.shm_size
    volumes.extend(extra_volumes)

    container_ports = [
        {"containerPort": port, "name": f"vllm-{idx}", "protocol": "TCP"}
        for idx, port in enumerate(resolved.ports.backend)
    ]
    readiness_ports = resolved.ports.public if role.routing_sidecar else resolved.ports.backend

    init_containers = []
    if role.routing_sidecar:
        init_containers.append(
            {
                "name": "routing-proxy",
                "image": cluster.llm_d.routing_sidecar,
                "imagePullPolicy": "Always",
                "args": [
                    f"--port={resolved.ports.public[0]}",
                    f"--vllm-port={resolved.ports.backend[0]}",
                    f"--data-parallel-size={resolved.ports.rank_count}",
                    "--secure-proxy=false",
                    "--connector=nixlv2",
                ],
                "ports": [
                    {"containerPort": port, "name": f"rank{idx}", "protocol": "TCP"}
                    for idx, port in enumerate(resolved.ports.public)
                ],
                "restartPolicy": "Always",
                "resources": {
                    "requests": {"cpu": 8, "memory": "16Gi"},
                    "limits": {"cpu": 8, "memory": "16Gi"},
                },
                "securityContext": {"allowPrivilegeEscalation": False},
            }
        )

    vllm_container = {
        "name": "vllm",
        "image": spec.model.image,
        "imagePullPolicy": "Always",
        # TODO(security): make these capabilities/runAsRoot explicit strategy knobs instead of the default.
        "securityContext": {
            "capabilities": {"add": ["IPC_LOCK", "SYS_RAWIO"]},
            "runAsGroup": 0,
            "runAsUser": 0,
        },
        "command": ["/bin/bash", "-c"],
        "args": [
            build_launch_script(
                spec,
                role,
                resolved.ports,
                user_root=resolved.user_root,
                dev_source=resolved.dev_source,
                vllm_args=resolved.vllm_args,
            )
        ],
        "env": [secret_env("HF_TOKEN", "hf-secret", "HF_TOKEN"), *env_list(resolved.env)],
        "ports": container_ports,
        "readinessProbe": {
            "exec": {
                "command": [
                    "/bin/bash",
                    "-c",
                    # TODO(readiness): compare with upstream llm-d probes as these templates mature.
                    " && ".join(
                        f"curl -sf http://localhost:{port}/v1/models | grep -q '\"id\"'"
                        for port in readiness_ports
                    ),
                ]
            },
            "periodSeconds": 5,
            "failureThreshold": 120,
        },
        "resources": {
            "requests": {
                "cpu": role.resources.cpu,
                "memory": role.resources.memory,
                "ephemeral-storage": role.resources.ephemeral_storage,
                "nvidia.com/gpu": str(role.resources.gpus),
            },
            "limits": {
                "memory": role.resources.memory,
                "ephemeral-storage": role.resources.ephemeral_storage,
                "nvidia.com/gpu": str(role.resources.gpus),
            },
        },
        "volumeMounts": cluster.volume_mounts(),
        "workingDir": "/code",
    }
    if resolved.resource_claims:
        vllm_container["resources"]["claims"] = [{"name": claim["name"]} for claim in resolved.resource_claims]

    pod_labels = instance.labels("model-server", role.name) | {
        "llm-d.ai/inferenceServing": "true",
        "llm-d.ai/model": spec.model.label_value,
        "llm-d.ai/deployment": spec.topology.value,
    }

    pod_spec = {
        "serviceAccountName": instance.name("model-server"),
        "terminationGracePeriodSeconds": 0,
        "volumes": volumes,
        "containers": [vllm_container, *containers],
    }
    if init_containers:
        pod_spec["initContainers"] = init_containers
    if resolved.resource_claims:
        pod_spec["resourceClaims"] = resolved.resource_claims

    return {
        "apiVersion": "leaderworkerset.x-k8s.io/v1",
        "kind": "LeaderWorkerSet",
        "metadata": {
            "name": instance.name(role.name),
            "labels": instance.labels("lws", role.name)
            | {
                "llm-d.ai/inferenceServing": "true",
                "llm-d.ai/model": spec.model.label_value,
                "llm-d.ai/deployment": spec.topology.value,
            },
        },
        "spec": {
            "replicas": role.lws.replicas,
            "rolloutStrategy": {
                "type": "RollingUpdate",
                "rollingUpdateConfiguration": {"maxUnavailable": "100%"},
            },
            "leaderWorkerTemplate": {
                "size": role.lws.size,
                "workerTemplate": {
                    "metadata": {"labels": pod_labels},
                    "spec": pod_spec,
                },
            },
        },
    }
