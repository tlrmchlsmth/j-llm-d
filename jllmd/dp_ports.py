"""Derive public/backend serving ports from the local data-parallel layout."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class RolePorts:
    public: list[int]
    backend: list[int]

    @property
    def rank_count(self) -> int:
        return len(self.public)


def derive_ports(
    *,
    data_parallel_enabled: bool,
    data_parallel_local_size: int | None,
    public_base: int = 8000,
    backend_base: int | None = None,
) -> RolePorts:
    if data_parallel_enabled:
        if not data_parallel_local_size or data_parallel_local_size < 1:
            raise ValueError("data_parallel.local_size must be >= 1 when DP is enabled")
        rank_count = data_parallel_local_size
    else:
        rank_count = 1

    backend_start = backend_base if backend_base is not None else public_base
    return RolePorts(
        public=[public_base + offset for offset in range(rank_count)],
        backend=[backend_start + offset for offset in range(rank_count)],
    )
