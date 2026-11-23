from __future__ import annotations

import math
import random
from collections.abc import Sequence
from typing import Any


def finite_number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"{label} must be finite")
    return result


def percentile(values: Sequence[float], fraction: float) -> float:
    if not values:
        raise ValueError("percentile input is empty")
    if not 0 <= fraction <= 1:
        raise ValueError("percentile fraction must be between zero and one")
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def median(values: Sequence[float]) -> float:
    if not values:
        raise ValueError("median input is empty")
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def summarize(values: Sequence[float]) -> dict[str, Any]:
    checked = [finite_number(value, "sample") for value in values]
    if not checked:
        raise ValueError("summary input is empty")
    middle = median(checked)
    mean = sum(checked) / len(checked)
    deviations = [abs(value - middle) for value in checked]
    variance = (
        sum((value - mean) ** 2 for value in checked) / (len(checked) - 1)
        if len(checked) > 1
        else 0.0
    )
    return {
        "count": len(checked),
        "minimum": min(checked),
        "maximum": max(checked),
        "mean": mean,
        "median": middle,
        "standardDeviation": math.sqrt(variance),
        "medianAbsoluteDeviation": median(deviations),
        "p95": percentile(checked, 0.95),
    }


def _checked_clusters(
    clusters: Sequence[Sequence[float]],
    label: str,
) -> list[list[float]]:
    checked: list[list[float]] = []
    for index, cluster in enumerate(clusters):
        values = [
            finite_number(value, f"{label} process {index} sample")
            for value in cluster
        ]
        if not values:
            raise ValueError(f"{label} process clusters cannot be empty")
        checked.append(values)
    if not checked:
        raise ValueError(f"{label} process clusters cannot be empty")
    return checked


def _hierarchical_median_sample(
    clusters: list[list[float]],
    rng: random.Random,
) -> float:
    sampled: list[float] = []
    for _ in range(len(clusters)):
        cluster = rng.choice(clusters)
        sampled.extend(rng.choice(cluster) for _ in range(len(cluster)))
    return median(sampled)


def hierarchical_bootstrap_median_ratio(
    baseline: Sequence[Sequence[float]],
    candidate: Sequence[Sequence[float]],
    *,
    confidence: float,
    resamples: int,
    seed: int,
) -> dict[str, float]:
    baseline_clusters = _checked_clusters(baseline, "baseline")
    candidate_clusters = _checked_clusters(candidate, "candidate")
    baseline_samples = [value for cluster in baseline_clusters for value in cluster]
    candidate_samples = [value for cluster in candidate_clusters for value in cluster]
    if min(baseline_samples) <= 0 or min(candidate_samples) < 0:
        raise ValueError("ratio samples require a positive baseline")
    if not 0 < confidence < 1:
        raise ValueError("bootstrap confidence must be between zero and one")
    if resamples < 100:
        raise ValueError("bootstrap resample count is too small")

    rng = random.Random(seed)
    ratios = [
        _hierarchical_median_sample(candidate_clusters, rng)
        / _hierarchical_median_sample(baseline_clusters, rng)
        for _ in range(resamples)
    ]
    tail = (1 - confidence) / 2
    return {
        "estimate": median(candidate_samples) / median(baseline_samples),
        "lower": percentile(ratios, tail),
        "upper": percentile(ratios, 1 - tail),
    }


def hierarchical_bootstrap_median_difference(
    baseline: Sequence[Sequence[float]],
    candidate: Sequence[Sequence[float]],
    *,
    confidence: float,
    resamples: int,
    seed: int,
) -> dict[str, float]:
    baseline_clusters = _checked_clusters(baseline, "baseline")
    candidate_clusters = _checked_clusters(candidate, "candidate")
    baseline_samples = [value for cluster in baseline_clusters for value in cluster]
    candidate_samples = [value for cluster in candidate_clusters for value in cluster]
    if not 0 < confidence < 1:
        raise ValueError("bootstrap confidence must be between zero and one")
    if resamples < 100:
        raise ValueError("bootstrap resample count is too small")

    rng = random.Random(seed)
    differences = [
        _hierarchical_median_sample(candidate_clusters, rng)
        - _hierarchical_median_sample(baseline_clusters, rng)
        for _ in range(resamples)
    ]
    tail = (1 - confidence) / 2
    return {
        "estimate": median(candidate_samples) - median(baseline_samples),
        "lower": percentile(differences, tail),
        "upper": percentile(differences, 1 - tail),
    }
