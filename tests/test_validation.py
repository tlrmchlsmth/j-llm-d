from jllmd.spec import DeploymentSpec
from jllmd.warnings import collect_warnings


def _spec_with_role(role: dict) -> dict:
    return {
        "release": "bad",
        "topology": "aggregated",
        "model": {"id": "model", "image": "image"},
        "routing": {"kind": "disabled"},
        "roles": [role],
    }


def test_global_dp_mismatch_warns():
    spec = DeploymentSpec.model_validate(
        _spec_with_role(
            {
                "name": "decode",
                "lws": {"size": 4},
                "parallelism": {"gpus_per_node": 4, "tp": 1, "dp": 10, "ep": True},
            }
        )
    )

    assert any(w.code == "dp-not-evenly-split" for w in collect_warnings(spec))


def test_global_tp_mismatch_warns():
    spec = DeploymentSpec.model_validate(
        _spec_with_role(
            {
                "name": "prefill",
                "lws": {"size": 3},
                "parallelism": {"gpus_per_node": 4, "tp": 10, "dp": False, "ep": True},
            }
        )
    )

    assert any(w.code == "tp-not-evenly-split" for w in collect_warnings(spec))


def test_no_dp_multiple_rank_slots_warns():
    spec = DeploymentSpec.model_validate(
        _spec_with_role(
            {
                "name": "prefill",
                "lws": {"size": 1},
                "parallelism": {"gpus_per_node": 4, "tp": 2, "dp": False, "ep": True},
            }
        )
    )

    assert any(w.code == "dp-disabled-multiple-local-ranks" for w in collect_warnings(spec))


def test_global_dp_local_partition_warns():
    spec = DeploymentSpec.model_validate(
        _spec_with_role(
            {
                "name": "decode",
                "lws": {"size": 4},
                "parallelism": {"gpus_per_node": 4, "tp": 2, "dp": 4, "ep": True},
            }
        )
    )

    assert any(w.code == "dp-gpu-partition-mismatch" for w in collect_warnings(spec))


def test_routing_proxy_sets_default_port_bases():
    spec = DeploymentSpec.model_validate(
        _spec_with_role(
            {
                "name": "decode",
                "lws": {"size": 4},
                "parallelism": {"gpus_per_node": 4, "tp": 1, "dp": 16, "ep": True},
                "dp_load_balancing": "external",
                "routing_proxy": True,
            }
        )
    )

    role = spec.role("decode")
    assert role.routing_sidecar is True
    assert role.serving_port_base == 8000
    assert role.backend_port_base == 8200


def test_routing_proxy_with_internal_dp_warns():
    spec = DeploymentSpec.model_validate(
        _spec_with_role(
            {
                "name": "decode",
                "lws": {"size": 4},
                "parallelism": {"gpus_per_node": 4, "tp": 1, "dp": 16, "ep": True},
                "routing_proxy": True,
            }
        )
    )

    assert any(w.code == "routing-proxy-with-internal-dp" for w in collect_warnings(spec))


def test_external_dp_with_multiple_api_servers_warns():
    spec = DeploymentSpec.model_validate(
        _spec_with_role(
            {
                "name": "decode",
                "lws": {"size": 4},
                "parallelism": {"gpus_per_node": 4, "tp": 1, "dp": 16, "ep": True},
                "dp_load_balancing": "external",
                "vllm": {"api_server_count": 4},
            }
        )
    )

    assert any(w.code == "api-server-count-with-external-dp" for w in collect_warnings(spec))


def test_pd_topology_sets_decode_proxy_without_role_flag():
    spec = DeploymentSpec.model_validate(
        {
            "release": "pd",
            "topology": "pd",
            "model": {"id": "model", "image": "image"},
            "roles": [
                {
                    "name": "decode",
                    "lws": {"size": 4},
                    "parallelism": {"gpus_per_node": 4, "tp": 1, "dp": 16, "ep": True},
                },
                {
                    "name": "prefill",
                    "lws": {"size": 2},
                    "parallelism": {"gpus_per_node": 4, "tp": 8, "dp": False, "ep": True},
                },
            ],
        }
    )

    assert spec.role("decode").routing_sidecar is True
    assert spec.role("decode").dp_load_balancing == "external"
    assert spec.role("decode").backend_port_base == 8200
    assert spec.role("prefill").routing_sidecar is False


def test_legacy_lws_nodes_and_gpus_aliases_still_parse():
    spec = DeploymentSpec.model_validate(
        _spec_with_role(
            {
                "name": "decode",
                "lws": {"nodes": 4},
                "parallelism": {"gpus": 4, "tp": 1, "dp": 16, "ep": True},
            }
        )
    )

    role = spec.role("decode")
    assert role.lws.size == 4
    assert role.gpus_per_pod == 4
