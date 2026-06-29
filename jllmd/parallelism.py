from __future__ import annotations

from dataclasses import dataclass

from .spec import RoleSpec


@dataclass(frozen=True)
class ParallelLayout:
    tp_world_size: int
    tp_local_size: int
    dp_local_size: int
    dp_world_size: int


def parallel_layout(role: RoleSpec) -> ParallelLayout:
    tp_local_size = _local_tp_size(role)
    _validate_gpu_partition(role, tp_local_size)

    dp_slots_per_node = role.gpus_per_pod // tp_local_size

    if role.data_parallel.enabled:
        assert role.data_parallel.local_size is not None
        dp_local_size = role.data_parallel.local_size
        if dp_local_size != dp_slots_per_node:
            raise ValueError(
                f"{role.name}: global DP resolves to {dp_local_size} local ranks per node, "
                f"but {role.gpus_per_pod} GPUs with local TP {tp_local_size} leaves {dp_slots_per_node}"
            )
        dp_world_size = role.lws.size * dp_local_size
    else:
        if dp_slots_per_node != 1:
            raise ValueError(
                f"{role.name}: DP is disabled but {role.gpus_per_pod} GPUs with local TP {tp_local_size} "
                f"would create {dp_slots_per_node} local ranks"
            )
        dp_local_size = 1
        dp_world_size = 1

    return ParallelLayout(
        tp_world_size=role.tensor_parallel_size,
        tp_local_size=tp_local_size,
        dp_local_size=dp_local_size,
        dp_world_size=dp_world_size,
    )


def _local_tp_size(role: RoleSpec) -> int:
    if role.tensor_parallel_size <= role.gpus_per_pod:
        return role.tensor_parallel_size
    if role.tensor_parallel_size % role.lws.size != 0:
        raise ValueError(
            f"{role.name}: global TP size {role.tensor_parallel_size} must divide evenly "
            f"across {role.lws.size} LWS nodes"
        )
    return role.tensor_parallel_size // role.lws.size


def _validate_gpu_partition(role: RoleSpec, tp_local_size: int) -> None:
    if tp_local_size < 1 or tp_local_size > role.gpus_per_pod:
        raise ValueError(
            f"{role.name}: local TP size {tp_local_size} must fit within {role.gpus_per_pod} GPUs per node"
        )
    if role.gpus_per_pod % tp_local_size != 0:
        raise ValueError(
            f"{role.name}: {role.gpus_per_pod} GPUs per node must be divisible by local TP size {tp_local_size}"
        )
