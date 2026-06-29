from pathlib import Path

from jllmd.cluster import get_cluster
from jllmd.instance import Instance
from jllmd.resolve import resolve_role
from jllmd.spec import load_spec


ROOT = Path(__file__).resolve().parents[1]


def test_compact_parallelism_and_equations_resolve_to_runtime_values():
    spec = load_spec(ROOT / "configs" / "deepseek-r1-gb200-pd.yaml")
    role = spec.role("decode")
    resolved = resolve_role(spec, Instance("tester", spec.release), get_cluster(spec.cluster), role)

    assert role.gpus_per_pod == 4
    assert role.tensor_parallel_size == 1
    assert role.data_parallel.enabled is True
    assert role.data_parallel.local_size == 4
    assert role.expert_parallel.enabled is True

    assert resolved.env["MAX_TOKENS"] == "1024"
    assert resolved.env["NVSHMEM_QP_DEPTH"] == "2050"
    assert resolved.vllm_args["max_num_batched_tokens"] == 1024
    assert resolved.vllm_args["max_num_seqs"] == 1024
    assert resolved.vllm_args["max_cudagraph_capture_size"] == 1024


def test_equations_get_explicit_dp_scopes():
    spec = load_spec(ROOT / "configs" / "deepseek-r1-gb200-pd.yaml")
    role = spec.role("decode")
    role.computed["env"] = {
        "DP_LOCAL": "dp_local_size",
        "DP_WORLD": "dp_world_size",
    }
    resolved = resolve_role(spec, Instance("tester", spec.release), get_cluster(spec.cluster), role)

    assert resolved.env["DP_LOCAL"] == "4"
    assert resolved.env["DP_WORLD"] == "16"
