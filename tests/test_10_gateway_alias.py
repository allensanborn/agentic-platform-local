"""Lab 0: the alias table.

The thesis of lab 0 is that swapping the model an agent uses is an edit to ONE gateway
manifest and nothing else. That property is only real if the alias actually resolves — so
this asserts the indirection works, and that the two aliases resolve to DIFFERENT models.

Deliberately not asserted: response quality, or that `local-smart` is any particular model
name. Those belong to the behavioural evals (llm-wiki-1fi.3/1fi.4). This file only proves
the routing layer does what it claims.
"""

import json
import urllib.error
import urllib.request

import pytest

GATEWAY = "http://127.0.0.1:18080/v1/chat/completions"

ALIASES = ["local-fast", "local-smart"]


def _chat(alias, prompt="Reply with the single word: ok", max_tokens=16, timeout=180):
    body = json.dumps(
        {
            "model": alias,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
        }
    ).encode()
    req = urllib.request.Request(
        GATEWAY,
        data=body,
        headers={"Content-Type": "application/json", "x-ai-eg-model": alias},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


@pytest.mark.parametrize("alias", ALIASES)
def test_alias_routes_to_a_backend(forwards, alias):
    """The client-facing name resolves. A 404 'no matching route' here is the lab-0 failure.

    This is the exact symptom that cost hours at the start of this project: every CRD
    reported Accepted=True while the gateway had no ext_proc filter, so every request came
    back 'No matching route found'. That state must never return silently.
    """
    try:
        resp = _chat(alias)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        if e.code in (503, 504):
            # Envoy's UPSTREAM timeout: the route resolved and the request was forwarded,
            # the backend just did not answer in time. qwen3:8b under CPU contention does
            # this routinely (llm-wiki-661.23). It says nothing about the alias table, and
            # calling it a lab-0 failure would be wrong — the lab-0 regression is a 404
            # "no matching route found", which means the request never reached a backend.
            pytest.skip(
                f"alias {alias!r} routed but the backend timed out (HTTP {e.code}). "
                "Capacity, not routing — see beads llm-wiki-661.23."
            )
        pytest.fail(f"alias {alias!r} did not route: HTTP {e.code} {detail}")

    assert resp.get("choices"), f"no choices in response for {alias}: {resp}"


def test_the_two_aliases_resolve_to_different_models(forwards):
    """modelNameOverride is doing real work.

    Asserts on the model name the BACKEND reports, not on the alias we sent — if the gateway
    stopped rewriting, both aliases would report the same underlying model and the whole
    'swap the model without touching the agent' claim would be hollow while still returning
    200s.
    """
    reported = {}
    for alias in ALIASES:
        try:
            resp = _chat(alias)
        except urllib.error.HTTPError as e:
            if e.code in (503, 504):
                pytest.skip(
                    f"backend timed out for {alias!r} (HTTP {e.code}); cannot compare "
                    "resolved model names. Capacity, not routing — llm-wiki-661.23."
                )
            raise
        reported[alias] = resp.get("model")

    assert all(reported.values()), f"backend did not report a model name: {reported}"
    assert reported["local-fast"] != reported["local-smart"], (
        "both aliases resolved to the same backend model "
        f"({reported}) — modelNameOverride is not being applied"
    )
