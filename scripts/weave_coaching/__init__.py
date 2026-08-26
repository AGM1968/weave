"""Pure coaching logic: promotion planning and the coaching view.

Nothing in this package may reach outside its arguments. No database, no
filesystem, no subprocess, no graph, no `weave_quality` import -- normalized
evidence, catalog data, and resolved guide values arrive as plain values and
the answer goes back as plain values.

That is not style. The Rust port boundary depends on this package being a pure
function of one document: an offline shadow can only replay frozen cases if
replaying them requires nothing but the bytes. `tests/test-coaching-purity.sh`
walks every module here and fails on a forbidden import, so the boundary is
mechanical rather than a convention.

Provider concerns live on the other side of that line: joining durable
adjudication state to a current scan is `weave_quality.coaching_evidence`, and
reading guide files from disk is `weave_quality.guides`.
"""

from __future__ import annotations

from .planner import plan_promotions

__all__ = ["plan_promotions"]
