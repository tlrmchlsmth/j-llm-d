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
    if role.tensor_parallel_size <= role.gpus_per_pod:
        tp_local_size = role.tensor_parallel_size
    else:
        if role.tensor_parallel_size % role.lws.size != 0:
            raise ValueError("tensor_parallel_size must divide evenly across LWS nodes")
        tp_local_size = role.tensor_parallel_size // role.lws.size

    if tp_local_size < 1 or tp_local_size > role.gpus_per_pod:
        raise ValueError("derived local TP size must fit within gpus_per_pod")
    if role.gpus_per_pod % tp_local_size != 0:
        raise ValueError("gpus_per_pod must be divisible by derived local TP size")

    if role.data_parallel.enabled:
        assert role.data_parallel.local_size is not None
        dp_local_size = role.data_parallel.local_size
        dp_world_size = role.lws.size * dp_local_size
    else:
        dp_local_size = role.gpus_per_pod // tp_local_size
        dp_world_size = 1

    return ParallelLayout(
        tp_world_size=role.tensor_parallel_size,
        tp_local_size=tp_local_size,
        dp_local_size=dp_local_size,
        dp_world_size=dp_world_size,
    )
