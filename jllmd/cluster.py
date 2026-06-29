from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Cluster:
    name: str
    lustre_pvc: str
    local_nvme_path: str
    shm_size: str
    ucx_net_devices: str
    imex_resource_claim_template: str | None = None

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


GB200 = Cluster(
    name="gb200",
    lustre_pvc="lustre-pvc-vllm",
    local_nvme_path="/mnt/numa0",
    shm_size="2Gi",
    ucx_net_devices="mlx5_0:1,mlx5_1:1,mlx5_3:1,mlx5_4:1",
    imex_resource_claim_template="llm-d-dev-claim",
)


def get_cluster(name: str) -> Cluster:
    if name == "gb200":
        return GB200
    raise ValueError(f"unknown cluster: {name}")
