from __future__ import annotations

import argparse
import os
import sys

from .render import render, render_to_yaml
from .instance import Instance
from .spec import load_spec
from .warnings import collect_warnings


def _render(args: argparse.Namespace, *, routing_only: bool = False) -> int:
    user = args.user or os.environ.get("USER") or "dev"
    spec = load_spec(args.spec)
    _print_warnings(spec)
    sys.stdout.write(render_to_yaml(render(spec, user=user, routing_only=routing_only)))
    return 0


def _print_warnings(spec) -> None:
    for warning in collect_warnings(spec):
        print(f"warning[{warning.code}]: {warning.message}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="j-llm-d")
    sub = parser.add_subparsers(dest="command", required=True)

    render_parser = sub.add_parser("render")
    render_parser.add_argument("spec")
    render_parser.add_argument("--user")
    render_parser.set_defaults(func=lambda args: _render(args, routing_only=False))

    routing_parser = sub.add_parser("render-routing")
    routing_parser.add_argument("spec")
    routing_parser.add_argument("--user")
    routing_parser.set_defaults(func=lambda args: _render(args, routing_only=True))

    instance_parser = sub.add_parser("instance-id")
    instance_parser.add_argument("spec")
    instance_parser.add_argument("--user")
    instance_parser.set_defaults(func=_instance_id)

    name_parser = sub.add_parser("name")
    name_parser.add_argument("spec")
    name_parser.add_argument("component")
    name_parser.add_argument("--user")
    name_parser.set_defaults(func=_name)

    cache_parser = sub.add_parser("cache-path")
    cache_parser.add_argument("spec")
    cache_parser.add_argument("--user")
    cache_parser.set_defaults(func=_cache_path)

    args = parser.parse_args(argv)
    return args.func(args)


def _instance_id(args: argparse.Namespace) -> int:
    user = args.user or os.environ.get("USER") or "dev"
    spec = load_spec(args.spec)
    print(Instance(user=user, release=spec.release).instance_id)
    return 0


def _name(args: argparse.Namespace) -> int:
    user = args.user or os.environ.get("USER") or "dev"
    spec = load_spec(args.spec)
    print(Instance(user=user, release=spec.release).name(args.component))
    return 0


def _cache_path(args: argparse.Namespace) -> int:
    user = args.user or os.environ.get("USER") or "dev"
    spec = load_spec(args.spec)
    instance = Instance(user=user, release=spec.release)
    print(instance.lustre_path("jit-cache", spec.cache.gpu_arch, spec.cache.cuda, spec.cache.vllm_version, spec.release))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
