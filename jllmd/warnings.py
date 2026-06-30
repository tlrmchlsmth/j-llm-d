"""Non-fatal render warnings for risky or surprising deployment configurations."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .parallelism import parallel_layout
from .spec import DeploymentSpec, DpLoadBalancing, RoleSpec


@dataclass(frozen=True)
class RenderWarning:
    code: str
    message: str


def collect_warnings(spec: DeploymentSpec) -> list[RenderWarning]:
    warnings: list[RenderWarning] = []
    for role in spec.roles:
        warnings.extend(_role_warnings(role))
    return warnings


def _role_warnings(role: RoleSpec) -> list[RenderWarning]:
    warnings: list[RenderWarning] = []
    layout = parallel_layout(role)

    if role.tensor_parallel_size > role.gpus_per_pod and role.tensor_parallel_size % role.lws.size != 0:
        warnings.append(
            RenderWarning(
                "tp-not-evenly-split",
                f"{role.name}: global TP {role.tensor_parallel_size} does not divide evenly across {role.lws.size} LWS nodes",
            )
        )
    if role.gpus_per_pod % layout.tp_local_size != 0:
        warnings.append(
            RenderWarning(
                "gpu-tp-remainder",
                f"{role.name}: {role.gpus_per_pod} GPUs per node is not divisible by local TP {layout.tp_local_size}",
            )
        )
    if role.data_parallel.enabled:
        requested_dp = role.vars.get("dp_world_requested")
        if requested_dp and requested_dp != layout.dp_world_size:
            warnings.append(
                RenderWarning(
                    "dp-not-evenly-split",
                    f"{role.name}: global DP {requested_dp} does not divide evenly across {role.lws.size} LWS nodes; rendering DP {layout.dp_world_size}",
                )
            )
        expected = role.gpus_per_pod // layout.tp_local_size
        if layout.dp_local_size != expected:
            warnings.append(
                RenderWarning(
                    "dp-gpu-partition-mismatch",
                    f"{role.name}: global DP resolves to {layout.dp_local_size} local ranks, but local TP {layout.tp_local_size} leaves {expected}",
                )
            )
    elif role.gpus_per_pod // layout.tp_local_size != 1:
        warnings.append(
            RenderWarning(
                "dp-disabled-multiple-local-ranks",
                f"{role.name}: DP is disabled but local TP {layout.tp_local_size} leaves multiple local rank slots",
            )
        )
    if role.routing_sidecar and role.dp_load_balancing != DpLoadBalancing.EXTERNAL:
        warnings.append(
            RenderWarning(
                "routing-proxy-with-internal-dp",
                f"{role.name}: routing_proxy is set while dp_load_balancing is {role.dp_load_balancing}",
            )
        )
    if role.dp_load_balancing == DpLoadBalancing.EXTERNAL and _api_server_count(role.vllm_args) > 1:
        warnings.append(
            RenderWarning(
                "api-server-count-with-external-dp",
                f"{role.name}: api_server_count > 1 is usually incompatible with external DP load balancing",
            )
        )
    return warnings


def _api_server_count(vllm_args: dict[str, Any]) -> int:
    value = vllm_args.get("api_server_count", vllm_args.get("api-server-count", 1))
    try:
        return int(value)
    except (TypeError, ValueError):
        return 1
