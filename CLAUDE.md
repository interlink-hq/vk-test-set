# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the Virtual Kubelet Test Set (vk-test-set), a Python testing framework for validating InterLink sidecar functionality. It uses pytest to run Kubernetes pod tests against virtual kubelet providers, with templated manifests and validation procedures.

## Key Commands

### Running Tests
- `pytest -vx` - Run all tests with verbose output, stop on first failure
- `pytest -v vktestset/basic_test.py::test_manifest[node-template.yaml]` - Run specific test
- `pytest` - Run all tests with default output

### Environment Setup
- Set `KUBECONFIG` to point to your Kubernetes cluster configuration
- Set `VKTEST_CONFIG` to specify config file (defaults to `vktest_config.yaml`)

### Package Management
- Dependencies managed via `pyproject.toml` using hatchling build system
- Core deps: kubernetes, pytest, jinja2, pydantic, jsonschema2md

## Architecture

### Core Components
- `ConfigManager.py` - Handles test configuration from YAML files
- `ValidationProcedure.py` - Defines test validation logic and cleanup procedures
- `basic_test.py` - Main pytest module with parameterized tests
- `k8s_client.py` - Kubernetes API client wrapper
- `templates/` - Jinja2 manifest templates with embedded validation configs

### Test Flow
1. Templates are rendered with config values and unique UUIDs
2. Manifests are separated from validation configs at `# VALIDATION` marker
3. Kubernetes resources are created via `create_from_yaml`
4. Validation procedures check pod status and logs
5. Cleanup runs regardless of test outcome

### Template Structure
Templates contain:
- Kubernetes manifests (top section)
- `# VALIDATION` separator
- Validation config with timeout, pod checks, log checks, cleanup rules

### Configuration
`vktest_config.yaml` contains:
- `target_nodes` - Virtual kubelet nodes to test
- `required_namespaces` - Namespaces that must exist
- `timeout_multiplier` - Global timeout scaling factor
- `values` - Template variables (namespace, annotations, tolerations)

## Validation System

The validation system supports:
- **Pod Status Checks** - Verify pods reach expected states
- **Log Pattern Matching** - Regex validation of container logs
- **Automatic Cleanup** - Conditional resource deletion
- **Timeout Handling** - Configurable timeouts with multipliers
- **Recoverable vs Fatal Errors** - Different error handling strategies