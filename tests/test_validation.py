import pytest
from pydantic import ValidationError

from jllmd.spec import DeploymentSpec


def _spec_with_role(role: dict) -> dict:
    return {
        "release": "bad",
        "cluster": "gb200",
        "topology": "aggregated",
        "model": {"id": "model", "image": "image"},
        "routing": {"kind": "disabled"},
        "roles": [role],
    }


def test_global_dp_must_divide_lws_nodes():
    with pytest.raises(ValidationError, match="parallelism.dp must divide evenly"):
        DeploymentSpec.model_validate(
            _spec_with_role(
                {
                    "name": "decode",
                    "lws": {"nodes": 4},
                    "parallelism": {"gpus": 4, "tp": 1, "dp": 10, "ep": True},
                }
            )
        )


def test_global_tp_must_divide_lws_nodes_when_it_spans_nodes():
    with pytest.raises(ValidationError, match="global TP size 10 must divide evenly"):
        DeploymentSpec.model_validate(
            _spec_with_role(
                {
                    "name": "prefill",
                    "lws": {"nodes": 3},
                    "parallelism": {"gpus": 4, "tp": 10, "dp": False, "ep": True},
                }
            )
        )


def test_no_dp_requires_tp_to_cover_all_local_gpus():
    with pytest.raises(ValidationError, match="DP is disabled"):
        DeploymentSpec.model_validate(
            _spec_with_role(
                {
                    "name": "prefill",
                    "lws": {"nodes": 1},
                    "parallelism": {"gpus": 4, "tp": 2, "dp": False, "ep": True},
                }
            )
        )


def test_global_dp_must_match_local_gpu_partition():
    with pytest.raises(ValidationError, match="global DP resolves"):
        DeploymentSpec.model_validate(
            _spec_with_role(
                {
                    "name": "decode",
                    "lws": {"nodes": 4},
                    "parallelism": {"gpus": 4, "tp": 2, "dp": 4, "ep": True},
                }
            )
        )


def test_routing_proxy_sets_default_port_bases():
    spec = DeploymentSpec.model_validate(
        _spec_with_role(
                {
                    "name": "decode",
                    "lws": {"nodes": 4},
                    "parallelism": {"gpus": 4, "tp": 1, "dp": 16, "ep": True},
                    "dp_load_balancing": "external",
                    "routing_proxy": True,
                }
            )
    )

    role = spec.role("decode")
    assert role.routing_sidecar is True
    assert role.serving_port_base == 8000
    assert role.backend_port_base == 8200


def test_routing_proxy_requires_external_dp_load_balancing():
    with pytest.raises(ValidationError, match="routing_sidecar requires"):
        DeploymentSpec.model_validate(
            _spec_with_role(
                {
                    "name": "decode",
                    "lws": {"nodes": 4},
                    "parallelism": {"gpus": 4, "tp": 1, "dp": 16, "ep": True},
                    "routing_proxy": True,
                }
            )
        )


def test_pd_topology_sets_decode_proxy_without_role_flag():
    spec = DeploymentSpec.model_validate(
        {
            "release": "pd",
            "cluster": "gb200",
            "topology": "pd",
            "model": {"id": "model", "image": "image"},
            "routing": {"kind": "pd"},
            "roles": [
                {
                    "name": "decode",
                    "lws": {"nodes": 4},
                    "parallelism": {"gpus": 4, "tp": 1, "dp": 16, "ep": True},
                },
                {
                    "name": "prefill",
                    "lws": {"nodes": 2},
                    "parallelism": {"gpus": 4, "tp": 8, "dp": False, "ep": True},
                },
            ],
        }
    )

    assert spec.role("decode").routing_sidecar is True
    assert spec.role("decode").dp_load_balancing == "external"
    assert spec.role("decode").backend_port_base == 8200
    assert spec.role("prefill").routing_sidecar is False
