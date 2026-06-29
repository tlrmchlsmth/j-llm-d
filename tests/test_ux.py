from pathlib import Path

from jllmd.cluster import load_cluster
from jllmd.instance import Instance
from jllmd.render import render
from jllmd.resolve import resolve_role
from jllmd.spec import DpLoadBalancing, RoutingKind, load_spec


ROOT = Path(__file__).resolve().parents[1]
CLUSTER = load_cluster(ROOT / "clusters" / "oci-gb200-osaka.yaml")


def test_compact_parallelism_and_equations_resolve_to_runtime_values():
    spec = load_spec(ROOT / "models" / "deepseek-v4-gb200" / "pd.yaml", CLUSTER)
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
    spec = load_spec(ROOT / "models" / "deepseek-v4-gb200" / "pd.yaml", CLUSTER)
    role = spec.role("decode")
    resolved = resolve_role(spec, Instance("tester", spec.release), CLUSTER, role)

    assert role.lws.size == 4
    assert role.data_parallel.local_size == 4
    assert role.routing_sidecar is True
    assert role.serving_port_base == 8000
    assert role.backend_port_base == 8200
    assert resolved.env["MAX_TOKENS"] == "1024"


def test_pd_topology_adds_decode_routing_proxy_defaults():
    spec = load_spec(ROOT / "models" / "deepseek-v4-gb200" / "pd.yaml", CLUSTER)
    role = spec.role("decode")

    assert spec.routing.kind == RoutingKind.PD
    assert spec.routing.target_role == "decode"
    assert role.routing_sidecar is True
    assert role.serving_port_base == 8000
    assert role.backend_port_base == 8200


def test_equations_get_explicit_dp_scopes():
    spec = load_spec(ROOT / "models" / "deepseek-v4-gb200" / "pd.yaml", CLUSTER)
    role = spec.role("decode")
    role.computed["env"] = {
        "DP_LOCAL": "dp_local_size",
        "DP_WORLD": "dp_world_size",
    }
    resolved = resolve_role(spec, Instance("tester", spec.release), CLUSTER, role)

    assert resolved.env["DP_LOCAL"] == "4"
    assert resolved.env["DP_WORLD"] == "16"


def test_prefill_tp_spans_lws_nodes():
    spec = load_spec(ROOT / "models" / "deepseek-v4-gb200" / "pd.yaml", CLUSTER)
    role = spec.role("prefill")
    resolved = resolve_role(spec, Instance("tester", spec.release), CLUSTER, role)

    assert role.tensor_parallel_size == 8
    assert role.data_parallel.enabled is False
    assert resolved.vllm_args["trust_remote_code"] is True


def test_single_gpu_no_dp_role_derives_one_gpu_from_tp():
    spec = load_spec(ROOT / "models" / "qwen" / "aggregated.yaml", CLUSTER)
    role = spec.role("decode")

    assert role.gpus_per_pod == 1


def test_cluster_path_templates_feed_cache_dev_and_logs():
    cluster = CLUSTER.with_path_overrides(
        user_root="/vol/{user}",
        cache_root="/cache/{user}/{release}/{gpu_arch}/{cuda}/{vllm_version}",
        dev_venv="/venvs/{user}/{release}",
        dev_source="/src/{user}",
    )
    spec = load_spec(ROOT / "models" / "deepseek-v4-gb200" / "pd.yaml", cluster)
    spec.runtime.dev = True
    role = spec.role("decode")
    instance = Instance("Tester.Name", spec.release)

    resolved = resolve_role(spec, instance, cluster, role)
    objects = render(spec, user="Tester.Name", cluster=cluster)
    lws = next(obj for obj in objects if obj["kind"] == "LeaderWorkerSet" and obj["metadata"]["name"].endswith("decode"))
    script = lws["spec"]["leaderWorkerTemplate"]["workerTemplate"]["spec"]["containers"][0]["args"][0]

    assert resolved.env["VLLM_DEV_VENV"] == "/venvs/tester-name/wide-ep"
    assert resolved.env["VLLM_CACHE_ROOT"] == "/cache/tester-name/wide-ep/gb200/cu13/dev/vllm"
    assert "LOG_DIR=/vol/tester-name/logs/decode" in script
    assert "find /src/tester-name/vllm" in script
    assert "ucx-lib" not in script


def test_pre_launch_hooks_run_before_rank_launch_setup():
    spec = load_spec(ROOT / "models" / "deepseek-v4-gb200" / "pd.yaml", CLUSTER)
    spec.runtime.pre_launch.append("echo runtime-hook")
    role = spec.role("decode")
    role.pre_launch.append("echo role-hook")

    objects = render(spec, user="tester", cluster=CLUSTER)
    lws = next(obj for obj in objects if obj["kind"] == "LeaderWorkerSet" and obj["metadata"]["name"].endswith("decode"))
    script = lws["spec"]["leaderWorkerTemplate"]["workerTemplate"]["spec"]["containers"][0]["args"][0]

    assert script.index("source \"${VLLM_DEV_VENV}/bin/activate\"") < script.index("echo runtime-hook")
    assert script.index("echo runtime-hook") < script.index("echo role-hook")
    assert script.index("echo role-hook") < script.index("DP_SIZE_LOCAL=4")
