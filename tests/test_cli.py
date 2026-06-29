from pathlib import Path

from jllmd.cli import main


ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "models" / "deepseek-v4-gb200" / "pd.yaml"
CLUSTER = ROOT / "clusters" / "oci-gb200-osaka.yaml"


def test_cache_path_cli_accepts_cluster_template_override(capsys):
    rc = main(
        [
            "cache-path",
            str(MODEL),
            "--cluster",
            str(CLUSTER),
            "--user",
            "Tester.Name",
            "--cache-root",
            "/tmp/cache/{user}/{release}/{cuda}",
        ]
    )

    assert rc == 0
    assert capsys.readouterr().out.strip() == "/tmp/cache/tester-name/wide-ep/cu13"


def test_render_cli_dev_venv_override(capsys):
    rc = main(
        [
            "render",
            str(MODEL),
            "--cluster",
            str(CLUSTER),
            "--user",
            "tester",
            "--dev",
            "--dev-venv",
            "/custom/venv",
        ]
    )

    assert rc == 0
    assert "name: VLLM_DEV_VENV\n            value: /custom/venv" in capsys.readouterr().out


def test_render_cli_pre_launch_hook(capsys):
    rc = main(
        [
            "render",
            str(MODEL),
            "--cluster",
            str(CLUSTER),
            "--user",
            "tester",
            "--pre-launch",
            "echo cli-hook",
        ]
    )

    assert rc == 0
    assert "echo cli-hook" in capsys.readouterr().out
