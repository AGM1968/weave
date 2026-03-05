"""Weave quality -- code quality as derived cache.

Provides code complexity metrics, git churn analysis, and hotspot detection.
No external dependencies beyond Python stdlib + git CLI.

Modules:
  - models: Data classes (FileMetrics, ProjectMetrics, ScanMeta)
  - git_metrics: Git churn, age, authors, co-change via subprocess
  - db: quality.db schema, lifecycle, staleness detection
"""

from __future__ import annotations
