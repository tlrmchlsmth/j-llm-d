"""Tests for the multi-tenant instance naming, selector, and path invariants."""

from jllmd.instance import Instance


def test_names_are_prefixed_and_hostname_safe():
    instance = Instance(user="Very.Long_User.Name", release="release-with-a-name-that-is-far-too-long-for-hostnames")
    name = instance.name("decode-with-another-long-component-name")

    assert name.startswith(instance.instance_id[:20])
    assert len(name) <= 63


def test_selectors_are_disjoint_across_instances():
    a = Instance(user="alice", release="wide-ep")
    b = Instance(user="bob", release="wide-ep")

    selector = a.pod_selector("decode")
    b_labels = b.labels("model-server", "decode")

    assert any(b_labels.get(key) != value for key, value in selector.items())


def test_lustre_paths_are_user_scoped():
    assert Instance("alice", "x").lustre_path("jit-cache") != Instance("bob", "x").lustre_path("jit-cache")
