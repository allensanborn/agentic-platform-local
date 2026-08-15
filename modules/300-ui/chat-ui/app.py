"""Chat UI for the customer agent.

Local port of the workshop's `ui/app.py`.

`StreamRenderer` and `ChainlitUI` below are copied VERBATIM from the workshop:
they implement the SSE wire contract shared with each lab's `server.py`
(`token` / `reasoning` text deltas, `tool_use.input` accumulated-so-far so you
replace rather than concatenate, `tool_result` closing a step by id, and
`image` for the lab-5 chart). That contract is the interesting part and it is
not worth paraphrasing.

What is deliberately NOT here: the workshop's Cognito OAuth gate and persona
extraction. Those exist to feed per-tool authorization in lab 4, and there is
nothing to authorize until tools move behind agentgateway in lab 3. Adding an
identity provider now would be ceremony without a control point behind it, so
it arrives with the lab that needs it.
"""

import asyncio
import base64
import json
import os
import uuid

import chainlit as cl
import httpx

# In-cluster Service by default; override for host runs.
AGENT_URL = os.environ.get(
    "AGENT_URL", "http://customer-agent.default.svc.cluster.local:8080/chat"
)
REQUEST_TIMEOUT = 300  # seconds — a local 8B model is slower than Bedrock

THINKING_KEY = "__thinking__"

# Friendly step labels keyed by tool name. Chainlit's frontend prepends
# "Using …" / "Used …", so these read as "Used code sandbox (run_python)".
# The tool name stays in parentheses because this is a workshop about building
# agents — participants should still see which tool fired. Unknown tools fall
# back to the raw name.
TOOL_LABELS = {
    "run_python": "code sandbox (run_python)",
    "lookup_order": "order lookup (lookup_order)",
    "check_inventory": "inventory check (check_inventory)",
    "initiate_return": "return request (initiate_return)",
    "ask_order_agent": "the order specialist (ask_order_agent)",
    "ask_product_agent": "the product specialist (ask_product_agent)",
}


def _tool_step_body(name: str, raw_input: str) -> str:
    """Render a tool's accumulated input as a fenced code block.

    run_python: show the parsed `code` field as Python once the input is
    complete JSON (else the raw text while it's still streaming). Other tools:
    pretty-print the JSON args (else the raw text if it isn't valid JSON yet).
    """
    if name == "run_python":
        try:
            parsed = json.loads(raw_input)
            if isinstance(parsed, dict) and isinstance(parsed.get("code"), str):
                return f"```python\n{parsed['code']}\n```"
        except (json.JSONDecodeError, TypeError):
            pass
        return f"```python\n{raw_input}\n```"

    try:
        parsed = json.loads(raw_input)
        pretty = json.dumps(parsed, indent=2)
        return f"```json\n{pretty}\n```"
    except (json.JSONDecodeError, TypeError):
        return f"```json\n{raw_input}\n```"

class StreamRenderer:
    """Dispatch agent SSE events to UI actions (steps + answer tokens).

    Chainlit-free by design so it unit-tests with a fake: `ui` provides
    stream_answer_token / open_step / update_step_content / close_step /
    end_answer_segment / render_image.
    Wire contract (shared with each lab's server.py sse_events_for):
      token / reasoning are text deltas; tool_use.input is ACCUMULATED-so-far
      (replace, don't concatenate); tool_result closes the step by id;
      image carries {base64, mime} — a chart the agent fetched out-of-band from
      the code-exec broker (module 900), rendered inline below its tool step.

    Answer text is SEGMENTED: when a new step opens after tokens have
    streamed, the current answer message is ended first, so text and steps
    interleave in true chronological order (step -> commentary -> step ->
    final answer) instead of all text pooling in one bubble above the steps.
    """

    def __init__(self, ui):
        self.ui = ui
        self.open_steps: dict[str, bool] = {}  # key -> opened (True until closed)
        self.reasoning_text = ""
        self.answer_pending = False  # tokens streamed since the last segment end

    async def handle(self, event: dict) -> None:
        if "reasoning" not in event:
            await self._close_thinking(errored=False)

        if "token" in event:
            self.answer_pending = True
            await self.ui.stream_answer_token(event["token"])

        elif "reasoning" in event:
            if THINKING_KEY not in self.open_steps:
                await self._end_answer_segment()
                self.open_steps[THINKING_KEY] = True
                self.reasoning_text = ""
                await self.ui.open_step(THINKING_KEY, "Thinking", "reasoning")
            self.reasoning_text += str(event["reasoning"] or "")
            await self.ui.update_step_content(THINKING_KEY, self.reasoning_text)

        elif "tool_use" in event:
            tool = event["tool_use"]
            if not isinstance(tool, dict):
                return
            name = tool.get("name", "tool")
            key = tool.get("id") or name  # id-less tools fall back to name so keys never collide on ""
            if key not in self.open_steps:
                await self._end_answer_segment()
                self.open_steps[key] = True
                await self.ui.open_step(key, TOOL_LABELS.get(name, name), "tool")
            await self.ui.update_step_content(key, _tool_step_body(name, tool.get("input", "")))

        elif "tool_result" in event:
            result = event["tool_result"]
            if not isinstance(result, dict):
                return
            key = result.get("id", "")
            if key in self.open_steps:
                del self.open_steps[key]
                await self.ui.close_step(key, result.get("status") == "error")

        elif "image" in event:
            image = event["image"]
            if not isinstance(image, dict):
                return
            b64 = image.get("base64")
            if not isinstance(b64, str) or not b64:
                return
            # End any in-flight text segment so the chart lands in chronological
            # order (below the tool step that produced it), not pinned above.
            await self._end_answer_segment()
            await self.ui.render_image(b64, image.get("mime", "image/png"))

    async def finish(self, errored: bool) -> None:
        """Close anything still open — called on stream end AND on error paths
        so the UI never shows a spinner forever."""
        await self._close_thinking(errored)
        for key in list(self.open_steps):
            del self.open_steps[key]
            await self.ui.close_step(key, errored)
        await self._end_answer_segment()

    async def _end_answer_segment(self) -> None:
        if self.answer_pending:
            self.answer_pending = False
            await self.ui.end_answer_segment()

    async def _close_thinking(self, errored: bool) -> None:
        if THINKING_KEY in self.open_steps:
            del self.open_steps[THINKING_KEY]
            await self.ui.close_step(THINKING_KEY, errored)

class ChainlitUI:
    """Real UI actions for StreamRenderer, backed by cl.Message + cl.Step.

    Steps are entered manually (not `async with`) because their lifetime spans
    many SSE events; StreamRenderer.finish() guarantees closure on all paths.

    Answer messages are created LAZILY, one per segment: Chainlit anchors an
    element's position in the transcript at creation, so a message sent before
    the stream starts would pin ALL answer text above every step. Creating the
    message on the first token of each segment (and send()ing it when the
    segment ends) keeps text and steps in chronological order.
    """

    def __init__(self):
        self.msg: cl.Message | None = None
        self.steps: dict[str, cl.Step] = {}

    async def stream_answer_token(self, text: str) -> None:
        if self.msg is None:
            self.msg = cl.Message(content="")
        await self.msg.stream_token(text)

    async def end_answer_segment(self) -> None:
        if self.msg is not None:
            await self.msg.send()  # ends streaming + persists this segment
            self.msg = None

    async def open_step(self, key: str, name: str, kind: str) -> None:
        # default_open so the code/args are visible without a click; users can
        # collapse. Chainlit auto-collapses a step once it ends, so this only
        # affects the in-flight view — which is exactly when the detail matters.
        step = cl.Step(
            name=name,
            type="llm" if kind == "reasoning" else "tool",
            default_open=True,
        )
        await step.__aenter__()
        self.steps[key] = step

    async def update_step_content(self, key: str, content: str) -> None:
        step = self.steps.get(key)
        if step is not None:
            step.output = content
            await step.update()

    async def close_step(self, key: str, is_error: bool) -> None:
        step = self.steps.pop(key, None)
        if step is not None:
            if is_error:
                step.is_error = True
            await step.__aexit__(None, None, None)

    async def render_image(self, b64: str, mime: str) -> None:
        # Decode to raw bytes and hand Chainlit a native inline Image element.
        # `display="inline"` shows it in the message flow (not a side drawer).
        # Bad base64 is swallowed: a broken chart must never kill the answer.
        try:
            data = base64.b64decode(b64)
        except (ValueError, TypeError):
            return
        image = cl.Image(content=data, name="chart", display="inline", size="large")
        await cl.Message(content="", elements=[image]).send()


@cl.on_chat_start
async def on_chat_start():
    cl.user_session.set("session_id", str(uuid.uuid4()))
    await cl.Message(
        content=(
            "Hi — I'm the **AnyCompany Shop** customer service agent.\n\n"
            "Ask me about an order, e.g. *\"Where is ORD-1001?\"*. "
            "Tool calls appear as collapsible steps so you can see what I actually did."
        )
    ).send()


@cl.on_message
async def on_message(message: cl.Message):
    session_id = cl.user_session.get("session_id")
    print(f"[chat] session={session_id} query={message.content!r}", flush=True)

    payload = {
        "query": message.content,
        "session_id": session_id,
        "actor_id": "local-user",
    }

    # No message is sent up front: ChainlitUI lazily creates one answer message
    # per text segment so steps and text interleave chronologically.
    renderer = StreamRenderer(ChainlitUI())

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        try:
            async with client.stream("POST", AGENT_URL, json=payload) as resp:
                resp.raise_for_status()
                # Drain to the natural end rather than breaking on [DONE]:
                # breaking mid-iteration abandons httpx's async-generator chain
                # at a yield and produces noisy (harmless) GeneratorExit noise.
                done = False
                async for line in resp.aiter_lines():
                    if done or not line.startswith("data: "):
                        continue
                    data = line[6:]
                    if data == "[DONE]":
                        done = True
                        continue
                    try:
                        await renderer.handle(json.loads(data))
                        await asyncio.sleep(0.03)
                    except json.JSONDecodeError:
                        pass
            await renderer.finish(errored=False)
        except httpx.ConnectError:
            await renderer.finish(errored=True)
            await cl.Message(
                content=(
                    "⚠️ Can't reach the **customer agent** at "
                    f"`{AGENT_URL}`. Is the deployment up?"
                )
            ).send()
        except httpx.HTTPStatusError as e:
            await renderer.finish(errored=True)
            await cl.Message(
                content=f"❌ The agent returned {e.response.status_code}: `{e.response.text[:400]}`"
            ).send()
        except Exception as e:
            await renderer.finish(errored=True)
            await cl.Message(content=f"❌ {type(e).__name__}: {e}").send()
