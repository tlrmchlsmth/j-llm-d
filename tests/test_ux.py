from pathlib import Path

from jllmd.cluster import load_cluster
from jllmd.instance import Instance
from jllmd.resolve import resolve_role
from jllmd.spec import DpLoadBalancing, RoutingKind, load_spec


ROOT = Path(__file__).resolve().parents[1]
CLUSTER = load_cluster(ROOT / "clusters" / "oci-gb200-osaka.yaml")


def test_compact_parallelism_and_equations_resolve_to_runtime_values():
    spec = load_spec(ROOT / "configs" / "deepseek-r1-gb200-pd.yaml", CLUSTER)
    role = spec.role("decode")
    resolved = resolve_role(spec, Instance("tester", spec.release), CLUSTER, role)

    assert role.gpus_per_pod == 4
    assert role.tensor_parallel_size == 1
    assert role.data_parallel.enabled is True
    assert role.data_parallel.local_size == 4
    assert role.expert_parallel.enabled is True
    assert role.dp_load_balancing == DpLoadBalancing.EXTERNAL

    assert resolved.env["MAX_TOKENS"] == "1024"
    assert resolved.env["NVSHMEM_QP_DEPTH"] == "2050"
    assert resolved.vllm_args["max_num_batched_tokens"] == 1024
    assert resolved.vllm_args["max_num_seqs"] == 1024
    assert resolved.vllm_args["max_cudagraph_capture_size"] == 1024


def test_dp_is_global_and_local_dp_is_derived_from_lws_nodes():
    spec = load_spec(ROOT / "configs" / "deepseek-r1-gb200-pd.yaml", CLUSTER)
    role = spec.role("decode")
    resolved = resolve_role(spec, Instance("tester", spec.release), CLUSTER, role)

    assert role.lws.size == 4
    assert role.data_parallel.local_size == 4
    assert role.routing_sidecar is True
    assert role.serving_port_base == 8000
    assert role.backend_port_base == 8200
    assert resolved.env["MAX_TOKENS"] == "1024"


def test_pd_topology_adds_decode_routing_proxy_defaults():
    spec = load_spec(ROOT / "configs" / "deepseek-r1-gb200-pd.yaml", CLUSTER)
    role = spec.role("decode")

    assert spec.routing.kind == RoutingKind.PD
    assert spec.routing.target_role == "decode"
    assert role.routing_sidecar is True
    assert role.serving_port_base == 8000
    assert role.backend_port_base == 8200


def test_equations_get_explicit_dp_scopes():
    spec = load_spec(ROOT / "configs" / "deepseek-r1-gb200-pd.yaml", CLUSTER)
    role = spec.role("decode")
    role.computed["env"] = {
        "DP_LOCAL": "dp_local_size",
        "DP_WORLD": "dp_world_size",
    }
    resolved = resolve_role(spec, Instance("tester", spec.release), CLUSTER, role)

    assert resolved.env["DP_LOCAL"] == "4"
    assert resolved.env["DP_WORLD"] == "16"


def test_prefill_tp_spans_lws_nodes():
    spec = load_spec(ROOT / "configs" / "deepseek-r1-gb200-pd.yaml", CLUSTER)
    role = spec.role("prefill")
    resolved = resolve_role(spec, Instance("tester", spec.release), CLUSTER, role)

    assert role.tensor_parallel_size == 8
    assert role.data_parallel.enabled is False
    assert resolved.vllm_args["trust_remote_code"] is True


def test_single_gpu_no_dp_role_derives_one_gpu_from_tp():
    spec = load_spec(ROOT / "configs" / "qwen-gb200-agg.yaml", CLUSTER)
    role = spec.role("decode")

    assert role.gpus_per_pod == 1
