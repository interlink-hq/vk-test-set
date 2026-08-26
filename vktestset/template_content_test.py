from pathlib import Path
import re


def test_default_entrypoint_uses_alpine_for_default_container():
    template = Path(__file__).with_name("templates").joinpath("095-default-entrypoint.yaml").read_text()
    assert re.search(r"- name: busybox-default\s+image: alpine:3.19", template)


def test_secret_envfrom_uses_ascii_status_markers():
    template = Path(__file__).with_name("templates").joinpath("085-secret-envfrom.yaml").read_text()
    assert "✓" not in template
    assert "✗" not in template
    assert "PASS DATABASE_URL: postgresql" in template
