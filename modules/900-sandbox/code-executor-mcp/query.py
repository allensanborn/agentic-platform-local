"""Build a scoped, parameterized SQL query from LLM-supplied, validated parameters.

Local port of the workshop's `query.py`. The workshop builds a DynamoDB Query on the orders
`period-index` GSI; this builds a SQLite `SELECT ... WHERE period = ? AND ...` against the
`idx_period_region` index. Structurally identical: same public function name, same keyword
arguments, same allow-lists, same InvalidQueryParam.

The lesson survives the substitution unchanged, and is the reason this module exists at all:
the LLM chooses WHAT to fetch (period + optional filters); this module turns those VALUES
into a parameterized query. The LLM never supplies a raw expression, a column name, or a
fragment of SQL. Every value is checked against an allow-list (or a regex, for period) before
it is bound, and it is bound as a `?` placeholder rather than interpolated. Two independent
barriers, so a bypass of either one alone is not enough.
"""

import re

TABLE = "orders"

_PERIOD_RE = re.compile(r"^\d{4}-Q[1-4]$")

# Allow-lists mirror the workshop's terraform/data/generate_orders.py.
_VALID_STATUS = {"shipped", "delivered", "processing", "cancelled", "returned"}
_VALID_PAYMENT = {"credit_card", "debit_card", "gift_card"}
_VALID_REGION = {"West", "South", "Central", "East"}
_VALID_CHANNEL = {"web", "mobile"}


class InvalidQueryParam(ValueError):
    """Raised when an LLM-supplied query parameter fails validation."""


def build_query(
    *,
    period: str,
    region: str | None = None,
    status: str | None = None,
    payment_method: str | None = None,
    channel: str | None = None,
) -> tuple[str, list[str]]:
    """Return (sql, params) for a period slice plus optional equality filters.

    Raises InvalidQueryParam if any value is malformed / not in an allow-list.
    """
    if not _PERIOD_RE.match(period or ""):
        raise InvalidQueryParam(f"period must look like '2026-Q1', got {period!r}")

    # `period` is the partition key in the workshop's GSI; here it is the leading column of
    # idx_period_region, so the same access pattern is index-served.
    clauses = ["period = ?"]
    params: list[str] = [period]

    # (field, value, allow_list) — each optional filter is validated then bound.
    optional = [
        ("region", region, _VALID_REGION),
        ("status", status, _VALID_STATUS),
        ("payment_method", payment_method, _VALID_PAYMENT),
        ("channel", channel, _VALID_CHANNEL),
    ]
    for field, value, allowed in optional:
        if value is None:
            continue
        if value not in allowed:
            raise InvalidQueryParam(f"{field} must be one of {sorted(allowed)}, got {value!r}")
        # `field` is a literal from the list above, never anything the LLM supplied, so the
        # only interpolated text is code-controlled. The VALUE is always a bound parameter.
        clauses.append(f"{field} = ?")
        params.append(value)

    sql = f"SELECT * FROM {TABLE} WHERE " + " AND ".join(clauses)
    return sql, params
