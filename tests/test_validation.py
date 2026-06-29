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
