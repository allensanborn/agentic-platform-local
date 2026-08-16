"""HTTP wrapper so the chat UI can POST queries to the A2A orchestrator.

Local port of the workshop's `600-multi-agent-a2a/a2a-agents/server.py`. The SSE wire contract
is byte-identical to `modules/200-agent/customer-agent/server.py` — same events, same shapes —
so the existing Chainlit UI can point at this orchestrator instead of the customer agent with
no UI change.

Two local differences:
  - the token may arrive EITHER as an `Authorization: Bearer` header (the workshop's shape)
    OR as an `access_token` field in the body (this repo's chat-ui shape, see
    modules/300-ui/chat-ui). Accepting both is what lets the same UI drive both agents.
  - the persona claim is `groups`, not `cognito:groups` (Keycloak, not Cognito). This is the
    same one-string substitution lab 4 made.
"""

import base64
import json
import os

from fastapi import FastAPI, Header
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn

from orchestrator import build_session_agent, _access_token


def _persona_from_token(access_token: str | None) -> str | None:
    """Extract the persona (first `groups` entry) for trace attribution.

    Best-effort and deliberately UNVERIFIED: this decodes the JWT payload without checking the
    signature because it is only a trace label. Every decision that matters is made by
    agentgateway against the real signature.
    """
    if not access_token:
        return None
    try:
        payload = access_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)  # pad to a multiple of 4
        claims = json.loads(base64.urlsafe_b64decode(payload))
        groups = claims.get("groups") or []
        return groups[0] if groups else claims.get("preferred_username")
    except Exception:
        return None


def sse_events_for(event: dict) -> list[str]:
    """Map one Strands stream_async event to zero-or-more SSE lines.

    Wire contract (shared with modules/300-ui/chat-ui — keep in sync):
      {"token": str}        answer text delta
      {"reasoning": str}    model thinking delta (only when the model emits it)
      {"tool_use": {"id", "name", "input"}}   input is ACCUMULATED-so-far
      {"tool_result": {"id", "status"}}       status only

    Defensive by design: a malformed event returns [] rather than raising, so one odd event
    never kills the stream mid-answer.
    """
    try:
        if "data" in event:
            return [f"data: {json.dumps({'token': event['data']})}\n\n"]

        if event.get("reasoning") and event.get("reasoningText"):
            return [f"data: {json.dumps({'reasoning': event['reasoningText']})}\n\n"]

        if "current_tool_use" in event:
            tool = event["current_tool_use"]
            if not isinstance(tool, dict) or not tool.get("name"):
                return []
            tool_input = tool.get("input", "")
            if not isinstance(tool_input, str):
                tool_input = json.dumps(tool_input)
            payload = {"tool_use": {"id": tool.get("toolUseId", ""), "name": tool["name"], "input": tool_input}}
            return [f"data: {json.dumps(payload)}\n\n"]

        if "message" in event:
            msg = event["message"]
            if not isinstance(msg, dict) or msg.get("role") != "user":
                return []
            lines = []
            content = msg.get("content")
            if not isinstance(content, list):
                return []
            for block in content:
                result = block.get("toolResult") if isinstance(block, dict) else None
                if result:
                    payload = {"tool_result": {"id": result.get("toolUseId", ""), "status": result.get("status", "success")}}
                    lines.append(f"data: {json.dumps(payload)}\n\n")
            return lines

        return []
    except Exception:
        return []


class ChatRequest(BaseModel):
    query: str
    session_id: str | None = None
    actor_id: str | None = None
    # This repo's chat-ui posts the bearer in the body; the workshop's UI sends a header.
    access_token: str | None = None


app = FastAPI()

# Session-scoped orchestrators keyed by session_id. Value: (agent, token). The agent carries
# session_id + persona as trace attributes, which are fixed at construction, so we cache one
# per session and rebuild if the same session id shows up with a different persona.
#
# Note this cache exists ONLY for trace labelling. The 200 agent's identical-looking cache is
# load-bearing for authorization, because its MCP transport binds the token at connect. A2A
# binds per call, so nothing here would break if the cache were removed.
_sessions: dict[str, tuple] = {}


def _get_session_agent(session_id: str | None, access_token: str | None):
    key = session_id or "default"
    existing = _sessions.get(key)
    if existing and existing[1] == access_token:
        return existing[0]
    agent = build_session_agent(
        session_id=session_id,
        user_id=_persona_from_token(access_token),
    )
    _sessions[key] = (agent, access_token)
    return agent


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/chat")
async def chat(req: ChatRequest, authorization: str | None = Header(default=None)):
    # Forward the caller's bearer to the A2A tool calls via the ContextVar
    # (orchestrator._access_token). Strands propagates context into tool execution, so the
    # token reaches ask_order_agent/_ask on each request without being a tool argument the
    # model could see, omit, or invent.
    access_token = req.access_token
    if not access_token and authorization and authorization.lower().startswith("bearer "):
        access_token = authorization[7:]
    _access_token.set(access_token)

    print(
        f"[chat] actor={req.actor_id} session={req.session_id} "
        f"persona={_persona_from_token(access_token)} "
        f"token={'yes' if access_token else 'no'} query={req.query!r}",
        flush=True,
    )

    agent = _get_session_agent(req.session_id, access_token)

    async def generate():
        async for event in agent.stream_async(req.query):
            for line in sse_events_for(event):
                yield line
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8083")))
