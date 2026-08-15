"""Port of the workshop's test_query.py to the SQLite query builder.

Same cases, same intent: the period-scoped read is index-served, optional filters are
appended, and every malformed or non-allow-listed value raises before anything is bound.
"""

import pytest
from query import build_query, InvalidQueryParam


def test_period_only_scopes_to_the_period():
    sql, params = build_query(period="2026-Q1")
    assert sql == "SELECT * FROM orders WHERE period = ?"
    assert params == ["2026-Q1"]


def test_optional_filters_become_bound_and_clauses():
    sql, params = build_query(period="2026-Q1", region="West", status="delivered")
    assert sql == "SELECT * FROM orders WHERE period = ? AND region = ? AND status = ?"
    assert params == ["2026-Q1", "West", "delivered"]


def test_bad_period_is_rejected():
    with pytest.raises(InvalidQueryParam):
        build_query(period="Q1-2026")


def test_unknown_payment_method_is_rejected():
    with pytest.raises(InvalidQueryParam):
        build_query(period="2026-Q1", payment_method="crypto")


def test_unknown_status_is_rejected():
    with pytest.raises(InvalidQueryParam):
        build_query(period="2026-Q1", status="teleported")


def test_injection_attempt_in_a_filter_is_rejected_not_escaped():
    """The allow-list is the first barrier: a SQL payload never reaches the binder."""
    with pytest.raises(InvalidQueryParam):
        build_query(period="2026-Q1", region="West' OR '1'='1")


def test_injection_attempt_in_the_period_is_rejected():
    with pytest.raises(InvalidQueryParam):
        build_query(period="2026-Q1'; DROP TABLE orders; --")


def test_no_llm_supplied_text_ever_reaches_the_sql_string():
    """Second barrier: values are bound as `?`, so the SQL text is code-controlled only."""
    sql, params = build_query(period="2026-Q4", channel="mobile")
    assert "2026-Q4" not in sql
    assert "mobile" not in sql
    assert sql.count("?") == len(params)
