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
    _apply_concurrency_alias(normalized)
    _apply_vllm_alias(normalized)

    # Fabric is a cluster concern. Ignore old configs that still carry it.
    normalized.pop("fabric_profile", None)
    return normalized


def _apply_parallelism_alias(role: dict[str, Any]) -> None:
    parallelism = role.pop("parallelism", None)
    if not isinstance(parallelism, dict):
        return

    if parallelism.get("gpus") is not None:
        role.setdefault("gpus_per_pod", parallelism["gpus"])
    if parallelism.get("tp") is not None:
        role.setdefault("tensor_parallel_size", parallelism["tp"])

    dp = parallelism.get("dp")
    if isinstance(dp, bool):
        role.setdefault("data_parallel", {"enabled": dp, "local_size": role.get("gpus_per_pod") if dp else None})
    elif isinstance(dp, int):
        role.setdefault("data_parallel", {"enabled": dp > 1, "local_size": dp if dp > 1 else None})

    if isinstance(parallelism.get("ep"), bool):
        role.setdefault("expert_parallel", {"enabled": parallelism["ep"]})


def _apply_port_alias(role: dict[str, Any]) -> None:
    ports = role.pop("ports", None)
    if not isinstance(ports, dict):
        return

    role.setdefault("serving_port_base", ports.get("public", ports.get("serving", 8000)))
    role.setdefault("backend_port_base", ports.get("backend"))
    role.setdefault("routing_sidecar", ports.get("sidecar", False))


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
