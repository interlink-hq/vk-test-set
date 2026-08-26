from pathlib import Path
import re


def test_default_entrypoint_uses_alpine_for_default_container():
    template = Path(__file__).with_name("templates").joinpath("095-default-entrypoint.yaml").read_text()
    assert re.search(r"- name: busybox-default\s+image: alpine:3.19", template)
