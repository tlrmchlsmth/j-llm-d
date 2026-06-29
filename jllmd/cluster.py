from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml


@dataclass(frozen=True)
class Cluster:
    name: str
    gpus_per_node: int
    lustre_pvc: str
    local_nvme_path: str
    shm_size: str
    ucx_net_devices: str
    imex_resource_claim_template: str | None = None
    user_root_template: str = "/mnt/lustre/{user}"
    cache_root_template: str = "/mnt/lustre/{user}/jit-cache/{gpu_arch}/{cuda}/{vllm_version}/{release}"
    dev_venv_template: str = "/mnt/lustre/{user}/vllm-venv"
    dev_source_template: str = "/mnt/lustre/{user}/vllm-dev"

    def base_volumes(self) -> list[dict]:
        return [
            {"name": "dshm", "emptyDir": {"medium": "Memory", "sizeLimit": self.shm_size}},
            {"name": "lustre", "persistentVolumeClaim": {"claimName": self.lustre_pvc}},
            {"name": "local-nvme", "hostPath": {"path": self.local_nvme_path, "type": "Directory"}},
            {"name": "sys", "hostPath": {"path": "/sys", "type": "Directory"}},
            {"name": "proc", "hostPath": {"path": "/proc", "type": "Directory"}},
        ]

    def volume_mounts(self) -> list[dict]:
        return [
            {"name": "dshm", "mountPath": "/dev/shm"},
            {"name": "lustre", "mountPath": "/mnt/lustre"},
            {"name": "local-nvme", "mountPath": "/mnt/local"},
        ]

    def user_root(self, *, user: str, release: str) -> str:
        return self._format_path(self.user_root_template, user=user, release=release)

    def cache_root(self, *, user: str, release: str, gpu_arch: str, cuda: str, vllm_version: str) -> str:
        return self._format_path(
            self.cache_root_template,
            user=user,
            release=release,
            gpu_arch=gpu_arch,
            cuda=cuda,
            vllm_version=vllm_version,
        )

    def dev_venv(self, *, user: str, release: str) -> str:
        return self._format_path(self.dev_venv_template, user=user, release=release)

    def dev_source(self, *, user: str, release: str) -> str:
        return self._format_path(self.dev_source_template, user=user, release=release)

    def with_path_overrides(
        self,
        *,
        user_root: str | None = None,
        cache_root: str | None = None,
        dev_venv: str | None = None,
        dev_source: str | None = None,
    ) -> "Cluster":
        return Cluster(
            name=self.name,
            gpus_per_node=self.gpus_per_node,
            lustre_pvc=self.lustre_pvc,
            local_nvme_path=self.local_nvme_path,
            shm_size=self.shm_size,
            ucx_net_devices=self.ucx_net_devices,
            imex_resource_claim_template=self.imex_resource_claim_template,
            user_root_template=user_root or self.user_root_template,
            cache_root_template=cache_root or self.cache_root_template,
            dev_venv_template=dev_venv or self.dev_venv_template,
            dev_source_template=dev_source or self.dev_source_template,
        )

    def _format_path(self, template: str, **values: str) -> str:
        return template.format(**values)

    def fabric_profile_for(self, *, topology: str, role_name: str, expert_parallel: bool) -> str:
        if not expert_parallel:
            return "standard"
        if role_name == "prefill":
            return "deepep_prefill"
        if role_name == "decode":
            return "deepep_decode"
        return "standard"

    def fabric_env(self, profile: str, context: dict | None = None) -> dict[str, str]:
        env = {
            "TRITON_LIBCUDA_PATH": "/usr/lib64",
            "NVIDIA_GDRCOPY": "enabled",
            "UCX_NET_DEVICES": self.ucx_net_devices,
            "VLLM_ENGINE_READY_TIMEOUT_S": "1800",
        }
        if profile in {"deepep_decode", "deepep_prefill"}:
            env |= {
                "VLLM_USE_NCCL_SYMM_MEM": "1",
                "NCCL_CUMEM_ENABLE": "1",
                "NCCL_MNNVL_ENABLE": "1",
                "NVSHMEM_DISABLE_CUDA_VMM": "0",
            }
        if profile == "deepep_decode":
            env |= {
                "NCCL_NVLS_ENABLE": "1",
                "NVSHMEM_CUMEM_HANDLE_TYPE": "FABRIC",
                "VLLM_DEEPEP_LOW_LATENCY_USE_MNNVL": "1",
                "VLLM_DEEPEP_BUFFER_SIZE_MB": "0",
            }
            if context and "max_concurrency" in context:
                env["NVSHMEM_QP_DEPTH"] = str(int(context["max_concurrency"]) * 2 + 2)
        if profile == "deepep_prefill":
            env |= {
                "NCCL_NVLS_ENABLE": "0",
                "VLLM_DEEPEP_HIGH_THROUGHPUT_FORCE_INTRA_NODE": "1",
                "VLLM_USE_DEEP_GEMM": "1",
            }
        return env


def load_cluster(path: str | Path) -> Cluster:
    with Path(path).open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    paths = data.get("paths", {})
    dev = data.get("dev", {})
    return Cluster(
        name=data["name"],
        gpus_per_node=int(data.get("gpus_per_node", 4)),
        lustre_pvc=data["storage"]["lustre_pvc"],
        local_nvme_path=data["storage"].get("local_nvme_path", "/mnt/numa0"),
        shm_size=data.get("pod_defaults", {}).get("shm_size", "2Gi"),
        ucx_net_devices=data["fabric"]["ucx_net_devices"],
        imex_resource_claim_template=data["fabric"].get("imex_resource_claim_template"),
        user_root_template=paths.get("user_root", "/mnt/lustre/{user}"),
        cache_root_template=paths.get(
            "cache_root",
            "/mnt/lustre/{user}/jit-cache/{gpu_arch}/{cuda}/{vllm_version}/{release}",
        ),
        dev_venv_template=dev.get("venv", "/mnt/lustre/{user}/vllm-venv"),
        dev_source_template=dev.get("source", "/mnt/lustre/{user}/vllm-dev"),
    )
