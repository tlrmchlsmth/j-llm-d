from __future__ import annotations

from enum import StrEnum
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import AliasChoices, BaseModel, ConfigDict, Field, field_validator, model_validator

from .normalize import normalize_lws, normalize_role


class TopologyKind(StrEnum):
    AGGREGATED = "aggregated"
    PD = "pd"
    DECODE_BENCH = "decode_bench"


class RoutingKind(StrEnum):
    LOAD_AWARE = "load_aware"
    RANDOM = "random"
    PD = "pd"
    DISABLED = "disabled"


class DataParallelSpec(BaseModel):
    enabled: bool = False
    local_size: int | None = None

    @model_validator(mode="after")
    def validate_local_size(self) -> "DataParallelSpec":
        if self.enabled and (self.local_size is None or self.local_size < 1):
            raise ValueError("data_parallel.local_size is required when data_parallel.enabled is true")
        if not self.enabled and self.local_size not in (None, 1):
            raise ValueError("data_parallel.local_size must be omitted or 1 when DP is disabled")
        return self


class ExpertParallelSpec(BaseModel):
    enabled: bool = False


class LwsSpec(BaseModel):
    size: int = Field(1, ge=1)
    replicas: int = Field(1, ge=1)

    @model_validator(mode="before")
    @classmethod
    def compact_aliases(cls, data: Any) -> Any:
        return normalize_lws(data)


class ResourceSpec(BaseModel):
    cpu: str = "32"
    memory: str = "512Gi"
    gpus: int = Field(4, ge=0)
    ephemeral_storage: str = "128Gi"


class RoleSpec(BaseModel):
    name: str
    lws: LwsSpec = Field(default_factory=LwsSpec)
    gpus_per_pod: int = Field(4, ge=1, validation_alias=AliasChoices("gpus_per_pod", "gpus"))
    tensor_parallel_size: int = Field(1, ge=1, validation_alias=AliasChoices("tensor_parallel_size", "tp"))
    data_parallel: DataParallelSpec = Field(default_factory=DataParallelSpec)
    expert_parallel: ExpertParallelSpec = Field(default_factory=ExpertParallelSpec)
    serving_port_base: int = 8000
    backend_port_base: int | None = None
    routing_sidecar: bool = False
    kv_transfer_config: dict[str, Any] | None = None
    vllm_args: dict[str, Any] = Field(default_factory=dict)
    env: dict[str, str] = Field(default_factory=dict)
    vars: dict[str, Any] = Field(default_factory=dict)
    computed: dict[str, dict[str, Any]] = Field(default_factory=dict)
    resources: ResourceSpec = Field(default_factory=ResourceSpec)
    shm_size: str | None = None

    @model_validator(mode="before")
    @classmethod
    def compact_shape(cls, data: Any) -> Any:
        return normalize_role(data)

    @model_validator(mode="after")
    def validate_parallelism(self) -> "RoleSpec":
        if self.tensor_parallel_size <= self.gpus_per_pod:
            local_tp_size = self.tensor_parallel_size
        else:
            if self.tensor_parallel_size % self.lws.size != 0:
                raise ValueError("tensor_parallel_size must divide evenly across LWS nodes")
            local_tp_size = self.tensor_parallel_size // self.lws.size
        if local_tp_size < 1 or local_tp_size > self.gpus_per_pod:
            raise ValueError("derived local TP size must fit within gpus_per_pod")
        if self.gpus_per_pod % local_tp_size != 0:
            raise ValueError("gpus_per_pod must be divisible by derived local TP size")
        if self.data_parallel.enabled:
            assert self.data_parallel.local_size is not None
            if self.data_parallel.local_size * local_tp_size != self.gpus_per_pod:
                raise ValueError("data_parallel.local_size * local_tp_size must equal gpus_per_pod")
        return self


class ModelSpec(BaseModel):
    id: str
    label: str | None = None
    image: str
    served_name: str | None = None
    hf_home: str = "/mnt/local/hf_cache"

    @property
    def label_value(self) -> str:
        return self.label or self.id.rsplit("/", 1)[-1]


class RuntimeSpec(BaseModel):
    dev: bool = False
    dev_venv: str | None = None
    fork_repo: str = ""
    fork_branch: str = ""
    env: dict[str, str] = Field(default_factory=dict)
    sidecars: list[str] = Field(default_factory=lambda: ["dcgm-exporter", "node-exporter"])


class RoutingSpec(BaseModel):
    kind: RoutingKind = RoutingKind.LOAD_AWARE
    epp_image: str = "ghcr.io/llm-d/llm-d-inference-scheduler:v0.8.0"
    replicas: int = Field(1, ge=1)
    target_role: str = "decode"


class CacheSpec(BaseModel):
    gpu_arch: str = "gb200"
    cuda: str = "cu13"
    vllm_version: str = "dev"


class DeploymentSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")

    release: str
    namespace: str = "vllm"
    cluster: Literal["gb200"] = "gb200"
    topology: TopologyKind
    model: ModelSpec
    roles: list[RoleSpec]
    routing: RoutingSpec = Field(default_factory=RoutingSpec)
    runtime: RuntimeSpec = Field(default_factory=RuntimeSpec)
    cache: CacheSpec = Field(default_factory=CacheSpec)
    vars: dict[str, Any] = Field(default_factory=dict)

    @field_validator("roles")
    @classmethod
    def require_unique_roles(cls, roles: list[RoleSpec]) -> list[RoleSpec]:
        names = [role.name for role in roles]
        if len(names) != len(set(names)):
            raise ValueError("role names must be unique")
        return roles

    def role(self, name: str) -> RoleSpec:
        for role in self.roles:
            if role.name == name:
                return role
        raise KeyError(f"unknown role: {name}")


def load_spec(path: str | Path) -> DeploymentSpec:
    with Path(path).open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    return DeploymentSpec.model_validate(data)
