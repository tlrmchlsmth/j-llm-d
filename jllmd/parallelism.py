"""Derive local and global TP/DP layout from a role's parallelism settings."""

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
    dp_slots_per_node = max(1, role.gpus_per_pod // tp_local_size)

    if role.data_parallel.enabled:
        assert role.data_parallel.local_size is not None
        dp_local_size = role.data_parallel.local_size
        dp_world_size = role.lws.size * dp_local_size
    else:
        dp_local_size = max(1, dp_slots_per_node)
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
    return max(1, role.tensor_parallel_size // role.lws.size)
