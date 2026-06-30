"""Backward-compatible YAML normalization for compact user-facing spec syntax."""

from __future__ import annotations

from typing import Any


def normalize_lws(data: Any) -> Any:
    if not isinstance(data, dict):
        return data
    normalized = dict(data)
    if "nodes" in normalized and "size" not in normalized:
        normalized["size"] = normalized.pop("nodes")
    return normalized


def normalize_role(data: Any) -> Any:
    if not isinstance(data, dict):
        return data

    normalized = dict(data)
    _apply_parallelism_alias(normalized)
    _apply_port_alias(normalized)
    _apply_routing_proxy_alias(normalized)
    _apply_concurrency_alias(normalized)
    _apply_vllm_alias(normalized)

    # Fabric is a cluster concern. Ignore old configs that still carry it.
    normalized.pop("fabric_profile", None)
    return normalized


def _apply_parallelism_alias(role: dict[str, Any]) -> None:
    parallelism = role.pop("parallelism", None)
    if not isinstance(parallelism, dict):
        return

    gpus_per_node = parallelism.get("gpus_per_node", parallelism.get("gpus"))
    if gpus_per_node is not None:
        role.setdefault("gpus_per_pod", gpus_per_node)
    if parallelism.get("tp") is not None:
        role.setdefault("tensor_parallel_size", parallelism["tp"])

    dp = parallelism.get("dp")
    if dp is False:
        role.setdefault("data_parallel", {"enabled": False, "local_size": None})
    elif isinstance(dp, int):
        nodes = role.get("lws", {}).get("nodes", role.get("lws", {}).get("size", 1))
        local_size = max(1, dp // nodes) if dp > 1 else None
        role.setdefault("data_parallel", {"enabled": dp > 1, "local_size": local_size})
        role.setdefault("vars", {})["dp_world_requested"] = dp

    if isinstance(parallelism.get("ep"), bool):
        role.setdefault("expert_parallel", {"enabled": parallelism["ep"]})
    if parallelism.get("dp_load_balancing") is not None:
        role.setdefault("dp_load_balancing", parallelism["dp_load_balancing"])


def _apply_port_alias(role: dict[str, Any]) -> None:
    ports = role.pop("ports", None)
    if not isinstance(ports, dict):
        return

    role.setdefault("serving_port_base", ports.get("public", ports.get("serving", 8000)))
    role.setdefault("backend_port_base", ports.get("backend"))
    role.setdefault("routing_sidecar", ports.get("sidecar", False))


def _apply_routing_proxy_alias(role: dict[str, Any]) -> None:
    if "routing_proxy" not in role:
        return
    enabled = bool(role.pop("routing_proxy"))
    role.setdefault("routing_sidecar", enabled)
    if enabled:
        role.setdefault("serving_port_base", 8000)
        role.setdefault("backend_port_base", 8200)


def _apply_concurrency_alias(role: dict[str, Any]) -> None:
    concurrency = role.pop("concurrency", None)
    if not isinstance(concurrency, dict):
        return

    variables = dict(role.get("vars", {}))
    if "max" in concurrency:
        variables.setdefault("max_concurrency", concurrency["max"])
    if "per_gpu" in concurrency:
        variables.setdefault("max_concurrency", concurrency["per_gpu"])
    variables.setdefault("mtp_size", concurrency.get("mtp", 1))
    role["vars"] = variables


def _apply_vllm_alias(role: dict[str, Any]) -> None:
    if "vllm" in role and "vllm_args" not in role:
        role["vllm_args"] = role.pop("vllm")


def apply_cluster_defaults(data: dict[str, Any], *, gpus_per_node: int) -> dict[str, Any]:
    normalized = dict(data)
    roles = []
    for role in normalized.get("roles", []):
        role_data = dict(role)
        if not _has_gpu_override(role_data):
            role_data["gpus_per_pod"] = _infer_gpus_per_pod(role_data, cluster_gpus_per_node=gpus_per_node)
        roles.append(role_data)
    normalized["roles"] = roles
    normalized.pop("cluster", None)
    return normalized


def _has_gpu_override(role: dict[str, Any]) -> bool:
    if any(key in role for key in ("gpus_per_pod", "gpus_per_node", "gpus")):
        return True
    parallelism = role.get("parallelism", {})
    return isinstance(parallelism, dict) and any(key in parallelism for key in ("gpus_per_node", "gpus"))


def _infer_gpus_per_pod(role: dict[str, Any], *, cluster_gpus_per_node: int) -> int:
    parallelism = role.get("parallelism", {})
    lws = role.get("lws", {})
    lws_size = int(lws.get("size", lws.get("nodes", 1)))
    tp_world = int(parallelism.get("tp", 1))
    if tp_world > cluster_gpus_per_node:
        tp_local = max(1, tp_world // lws_size)
    else:
        tp_local = tp_world

    dp = parallelism.get("dp")
    if isinstance(dp, int) and dp > 1:
        dp_local = max(1, dp // lws_size)
        return tp_local * dp_local
    if dp is False:
        return tp_local
    return cluster_gpus_per_node
