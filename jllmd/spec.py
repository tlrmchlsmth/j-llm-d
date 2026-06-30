"""Pydantic models and loader for user-authored deployment YAML specs."""

from __future__ import annotations

from enum import StrEnum
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import AliasChoices, BaseModel, ConfigDict, Field, field_validator, model_validator

from .cluster import Cluster
from .normalize import apply_cluster_defaults, normalize_lws, normalize_role


class TopologyKind(StrEnum):
    AGGREGATED = "aggregated"
    PD = "pd"
    DECODE_BENCH = "decode_bench"


class RoutingKind(StrEnum):
    LOAD_AWARE = "load_aware"
    RANDOM = "random"
    PD = "pd"
    DISABLED = "disabled"


class DpLoadBalancing(StrEnum):
    INTERNAL = "internal"
    EXTERNAL = "external"


class DataParallelSpec(BaseModel):
    enabled: bool = False
    local_size: int | None = None

    @model_validator(mode="after")
    def validate_local_size(self) -> "DataParallelSpec":
        if self.enabled and (self.local_size is None or self.local_size < 1):
            raise ValueError("data_parallel.local_size is required when data_parallel.enabled is true")
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
    gpus_per_pod: int = Field(4, ge=1, validation_alias=AliasChoices("gpus_per_pod", "gpus_per_node", "gpus"))
    tensor_parallel_size: int = Field(1, ge=1, validation_alias=AliasChoices("tensor_parallel_size", "tp"))
    data_parallel: DataParallelSpec = Field(default_factory=DataParallelSpec)
    expert_parallel: ExpertParallelSpec = Field(default_factory=ExpertParallelSpec)
    serving_port_base: int = 8000
    backend_port_base: int | None = None
    routing_sidecar: bool = False
    dp_load_balancing: DpLoadBalancing = DpLoadBalancing.INTERNAL
    kv_transfer_config: dict[str, Any] | None = None
    vllm_args: dict[str, Any] = Field(default_factory=dict)
    env: dict[str, str] = Field(default_factory=dict)
    pre_launch: list[str] = Field(default_factory=list)
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
        if self.routing_sidecar and self.backend_port_base is None:
            self.backend_port_base = 8200
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
    pre_launch: list[str] = Field(default_factory=list)
    sidecars: list[str] = Field(default_factory=lambda: ["dcgm-exporter", "node-exporter"])


class RoutingSpec(BaseModel):
    kind: RoutingKind | None = None
    epp_image: str | None = None
    plugin_config: dict[str, Any] | None = None
    replicas: int = Field(1, ge=1)
    target_role: str | None = None


class CacheSpec(BaseModel):
    gpu_arch: str = "gb200"
    cuda: str = "cu13"
    vllm_version: str = "dev"


class DeploymentSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")

    release: str
    namespace: str = "vllm"
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

    @model_validator(mode="after")
    def apply_topology_defaults(self) -> "DeploymentSpec":
        if self.routing.kind is None:
            self.routing.kind = RoutingKind.PD if self.topology == TopologyKind.PD else RoutingKind.LOAD_AWARE
        if self.routing.target_role is None:
            self.routing.target_role = "decode"
        if self.topology == TopologyKind.PD:
            decode = self.role("decode")
            decode.dp_load_balancing = DpLoadBalancing.EXTERNAL
            decode.routing_sidecar = True
            decode.serving_port_base = 8000
            decode.backend_port_base = 8200
        return self

    def role(self, name: str) -> RoleSpec:
        for role in self.roles:
            if role.name == name:
                return role
        raise KeyError(f"unknown role: {name}")


def load_spec(path: str | Path, cluster: Cluster | None = None) -> DeploymentSpec:
    with Path(path).open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if cluster is not None:
        data = apply_cluster_defaults(data, gpus_per_node=cluster.gpus_per_node)
    return DeploymentSpec.model_validate(data)
