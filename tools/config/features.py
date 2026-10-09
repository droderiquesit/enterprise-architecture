"""Profile `features` -> component settings (environments/profiles/README.md "Feature mapping").

A profile's `features` block is a set of high-level switches. They become effective only through this
table: each feature writes one or more settings paths of the components listed here. The result is the
LOWEST-precedence layer of a component's rendered settings:

    feature mapping  <  profile component_settings.<id>  <  environment components.<id>

Only components that are rendered pick up their part, and only the settings paths listed for that
component change, so a feature edit re-selects exactly the affected components (fingerprints hash the
rendered settings). Unknown feature keys are an error; features that have no settings equivalent are
listed in DOCUMENTED_ONLY and are accepted but not rendered.
"""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Tuple

# Deployment roots whose `settings` declare `trace_sample_ratio` (OTEL_TRACES_SAMPLER_ARG).
TRACE_SAMPLED_DEPLOYMENTS = [
    "deploy-core-aks",
    "deploy-core-aca",
    "deploy-durable",
    "deploy-functions",
    "deploy-partner-sim",
    "deploy-dbadapters",
    "deploy-appservice",
    "deploy-jobs",
    "deploy-vm-workloads",
]

RUM_APP = "hello-frontend"


def _identity(v):
    return v


def _bool(v):
    if not isinstance(v, bool):
        raise ValueError(f"expected a boolean, got {v!r}")
    return v


def _ratio(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not 0 <= v <= 1:
        raise ValueError(f"expected a number in 0..1, got {v!r}")
    return v


def _percent(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not 0 <= v <= 100:
        raise ValueError(f"expected a percentage 0..100, got {v!r}")
    return v


def _choice(*allowed):
    def f(v):
        if v not in allowed:
            raise ValueError(f"expected one of {', '.join(allowed)}, got {v!r}")
        return v
    return f


# feature -> list of (component id, settings path, value transform)
Target = Tuple[str, Tuple[str, ...], Callable[[Any], Any]]
FEATURE_MAP: Dict[str, List[Target]] = {
    "topology": [("foundation-network", ("topology",), _choice("single-spoke", "hub-spoke"))],
    "egress": [("foundation-network", ("egress",), _choice("nat-gateway", "firewall"))],
    "firewall": [
        ("foundation-network", ("firewall_subnet",), _bool),
        ("foundation-edge", ("firewall", "enabled"), _bool),
    ],
    # Bastion Developer SKU (foundation-edge default) needs no AzureBastionSubnet.
    "bastion": [("foundation-edge", ("bastion", "enabled"), _bool)],
    "app_gateway": [
        ("foundation-network", ("appgw_subnet",), _bool),
        ("foundation-edge", ("app_gateway", "enabled"), _bool),
    ],
    "front_door": [("foundation-edge", ("front_door", "enabled"), _bool)],
    "apim": [("foundation-edge", ("apim", "enabled"), _bool)],
    "service_bus_sku": [("platform-messaging", ("sku",), _choice("Standard", "Premium"))],
    "rum_session_sample_rate": [
        ("obs-prereqs", ("rum_applications", RUM_APP, "session_sample_rate"), _percent),
    ],
    # Datadog sessionReplaySampleRate is a percentage of the sampled sessions: on = 100, off = 0.
    "session_replay": [
        ("obs-prereqs", ("rum_applications", RUM_APP, "session_replay_sample_rate"), lambda v: 100 if _bool(v) else 0),
    ],
    "trace_sample_rate": [(c, ("trace_sample_ratio",), _ratio) for c in TRACE_SAMPLED_DEPLOYMENTS],
}

# Accepted, rendered nowhere (descriptive only; see environments/profiles/README.md).
DOCUMENTED_ONLY = {
    # Private endpoints are the ADR §8 default in every root; exceptions are per-root settings.
    "private_endpoints",
    # observability-only enables no lab infrastructure roots through its component list.
    "deploy_lab_infrastructure",
}


class FeatureError(ValueError):
    pass


def validate_features(features: dict) -> None:
    for key, value in (features or {}).items():
        if key in DOCUMENTED_ONLY:
            continue
        if key not in FEATURE_MAP:
            raise FeatureError(
                f"unknown profile feature '{key}' (map it in tools/config/features.py FEATURE_MAP "
                f"or list it in DOCUMENTED_ONLY)")
        for _, _, transform in FEATURE_MAP[key]:
            try:
                transform(value)
            except ValueError as exc:
                raise FeatureError(f"profile feature '{key}': {exc}") from None


def feature_settings(features: dict, component_id: str) -> dict:
    """Settings fragment that the profile features contribute to one component."""
    validate_features(features)
    out: dict = {}
    for key in sorted(features or {}):
        for comp, path, transform in FEATURE_MAP.get(key, []):
            if comp != component_id:
                continue
            node = out
            for p in path[:-1]:
                node = node.setdefault(p, {})
            node[path[-1]] = transform(features[key])
    return out


def mapping_rows() -> List[Tuple[str, str, str]]:
    """(feature, component, settings path) rows — used by tests and to keep the README table honest."""
    rows = []
    for key, targets in FEATURE_MAP.items():
        for comp, path, _ in targets:
            rows.append((key, comp, ".".join(path)))
    return rows
