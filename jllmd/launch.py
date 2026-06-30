"""Build the per-pod shell script that prepares the environment and starts vLLM."""

from __future__ import annotations

import json
import shlex
from typing import Any

from .dp_ports import RolePorts
from .parallelism import parallel_layout
from .spec import DeploymentSpec, RoleSpec


def _flag_name(name: str) -> str:
    return "--" + name.replace("_", "-")


def _format_arg(name: str, value: Any) -> list[str]:
    flag = _flag_name(name)
    if isinstance(value, bool):
        return [flag] if value else []
    if isinstance(value, (dict, list)):
        return [flag, shlex.quote(json.dumps(value, separators=(",", ":")))]
    return [flag, shlex.quote(str(value))]


def build_launch_script(
    spec: DeploymentSpec,
    role: RoleSpec,
    ports: RolePorts,
    *,
    user_root: str,
    dev_source: str,
    vllm_args: dict[str, Any] | None = None,
) -> str:
    layout = parallel_layout(role)
    lines = [
        "set -euo pipefail",
        f"LOG_DIR={shlex.quote(user_root + '/logs/' + role.name)}",
        'mkdir -p "$LOG_DIR"',
        'LOG_FILE="$LOG_DIR/${HOSTNAME}_$(date +%Y%m%d-%H%M%S).log"',
        'exec > >(tee -a "$LOG_FILE") 2>&1',
        'echo "=== Pod $HOSTNAME started at $(date -Iseconds) ==="',
        "",
        f"FORK_REPO={shlex.quote(spec.runtime.fork_repo)}",
        f"FORK_BRANCH={shlex.quote(spec.runtime.fork_branch)}",
        'if [ -n "$FORK_BRANCH" ] && [ -d /opt/vllm-source ]; then',
        "  cd /opt/vllm-source",
        '  git remote add fork "$FORK_REPO" 2>/dev/null || git remote set-url fork "$FORK_REPO"',
        '  git fetch fork "$FORK_BRANCH"',
        '  git checkout "fork/$FORK_BRANCH"',
        "  cd -",
        "fi",
        "",
        f"find {shlex.quote(dev_source + '/vllm')} -name __pycache__ -type d -exec rm -rf {{}} + 2>/dev/null || true",
        'if [ -n "${VLLM_DEV_VENV:-}" ] && [ -d "${VLLM_DEV_VENV}" ]; then',
        '  echo "Using dev venv at ${VLLM_DEV_VENV}"',
        '  source "${VLLM_DEV_VENV}/bin/activate"',
        "elif [ -f /opt/vllm/bin/activate ]; then",
        "  source /opt/vllm/bin/activate",
        "fi",
        "",
    ]
    hooks = [*spec.runtime.pre_launch, *role.pre_launch]
    if hooks:
        lines += [
            "echo '=== Running pre-launch hooks ==='",
            *hooks,
            "",
        ]

    if role.data_parallel.enabled:
        lines += [
            f"DP_SIZE_LOCAL={layout.dp_local_size}",
            f"DP_SIZE={layout.dp_world_size}",
            "START_RANK=$(( ${LWS_WORKER_INDEX:-0} * DP_SIZE_LOCAL ))",
        ]
    else:
        lines += ["DP_SIZE_LOCAL=1", "START_RANK=0"]

    lines += [
        "",
        "for R in $(seq 0 $((DP_SIZE_LOCAL - 1))); do",
        f"  GPU_START=$((R * {layout.tp_local_size}))",
        f"  GPUS=$(seq -s, $GPU_START $((GPU_START + {layout.tp_local_size} - 1)))",
        "  RANK=$((START_RANK + R))",
        f"  PORTS=({' '.join(str(port) for port in ports.backend)})",
        "  PORT=${PORTS[$R]}",
    ]

    base_args = [
        "vllm",
        "serve",
        shlex.quote(spec.model.id),
        "--device-ids",
        "$GPUS",
        "--port",
        "$PORT",
        "--tensor-parallel-size",
        str(layout.tp_world_size),
    ]
    if role.expert_parallel.enabled:
        base_args.append("--enable-expert-parallel")
    if role.data_parallel.enabled:
        base_args += [
            "--data-parallel-size",
            "$DP_SIZE",
            "--data-parallel-rank",
            "$RANK",
            "--data-parallel-size-local",
            "1",
            "--data-parallel-address",
            "${LWS_LEADER_ADDRESS}",
            "--data-parallel-rpc-port",
            "5555",
        ]
    if role.kv_transfer_config:
        base_args += ["--kv_transfer_config", shlex.quote(json.dumps(role.kv_transfer_config, separators=(",", ":")))]
    if spec.model.served_name:
        base_args += ["--served-model-name", shlex.quote(spec.model.served_name)]
    for name, value in (vllm_args or role.vllm_args).items():
        base_args.extend(_format_arg(name, value))

    cmd = " ".join(base_args)
    lines += [
        "  VLLM_CACHE_ROOT=${VLLM_CACHE_ROOT}/rank${RANK} \\",
        "  FLASHINFER_CACHE_DIR=${FLASHINFER_CACHE_DIR}/rank${RANK} \\",
        f"  FLASH_ATTENTION_CUTE_DSL_CACHE_DIR=${{FLASH_ATTENTION_CUTE_DSL_CACHE_DIR}}/{role.name}_rank${{RANK}} \\",
        f"  TILELANG_CACHE_DIR=${{TILELANG_CACHE_DIR}}/{role.name}_rank${{RANK}} \\",
        f"  {cmd} &",
        "done",
        "",
        "wait -n",
        "kill $(jobs -p) 2>/dev/null || true",
        "exit 1",
    ]
    return "\n".join(lines)
