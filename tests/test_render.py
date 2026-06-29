from pathlib import Path

import yaml

from jllmd.render import render, render_to_yaml
from jllmd.spec import load_spec


ROOT = Path(__file__).resolve().parents[1]


def _objects(config: str) -> list[dict]:
    spec = load_spec(ROOT / "configs" / config)
    return render(spec, user="tester")


def _find(objects: list[dict], kind: str, name_suffix: str | None = None) -> dict:
    for obj in objects:
        if obj["kind"] != kind:
            continue
        if name_suffix is None or obj["metadata"]["name"].endswith(name_suffix):
            return obj
    raise AssertionError(f"missing {kind} {name_suffix or ''}")


def test_rendered_yaml_parses():
    objects = _objects("deepseek-r1-gb200-pd.yaml")
    parsed = list(yaml.safe_load_all(render_to_yaml(objects)))

    assert len(parsed) == len(objects)


def test_dp_ports_feed_container_readiness_and_inferencepool():
    objects = _objects("deepseek-r1-gb200-pd.yaml")
    lws = _find(objects, "LeaderWorkerSet", "decode")
    container = lws["spec"]["leaderWorkerTemplate"]["workerTemplate"]["spec"]["containers"][0]
    infpool = _find(objects, "InferencePool")

    assert [p["containerPort"] for p in container["ports"]] == [8200, 8201, 8202, 8203]
    readiness = container["readinessProbe"]["exec"]["command"][-1]
    assert "localhost:8000" in readiness
    assert "localhost:8003" in readiness
    assert [p["number"] for p in infpool["spec"]["targetPorts"]] == [8000, 8001, 8002, 8003]


def test_no_dp_qwen_uses_single_port_and_no_dp_flags():
    objects = _objects("qwen-gb200-agg.yaml")
    lws = _find(objects, "LeaderWorkerSet", "decode")
    container = lws["spec"]["leaderWorkerTemplate"]["workerTemplate"]["spec"]["containers"][0]
    script = container["args"][0]
    infpool = _find(objects, "InferencePool")

    assert [p["containerPort"] for p in container["ports"]] == [8000]
    assert "--data-parallel-size" not in script
    assert [p["number"] for p in infpool["spec"]["targetPorts"]] == [8000]


def test_inferencepool_selector_is_instance_scoped():
    objects = _objects("deepseek-r1-gb200-pd.yaml")
    infpool = _find(objects, "InferencePool")

    assert infpool["spec"]["selector"]["app.kubernetes.io/instance"] == "tester-wide-ep"
    assert infpool["spec"]["selector"]["llm-d.ai/role"] == "decode"
