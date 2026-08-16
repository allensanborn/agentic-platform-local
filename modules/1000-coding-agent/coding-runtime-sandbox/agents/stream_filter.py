# Compact, line-buffered renderer for Claude Code's stream-json output. Copied
# from the workshop's sandbox_runner.STREAM_FILTER_PY, which injects it as a file
# at run time; here it is baked into the image beside the agent that uses it,
# because it is a property of the Claude Code agent and not of the dispatcher.
#
# stdin is one JSON object per line; stdout is human-readable lines, flushed per
# line so `kubectl logs -f` on the sandbox renders them live.
import json
import sys


def hint(tool_input):
    for key in ("file_path", "command", "pattern", "path", "url"):
        val = tool_input.get(key)
        if val:
            return str(val).replace("\n", " ")[:120]
    return ""


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    kind = event.get("type")
    if kind == "system" and event.get("subtype") == "init":
        print("[claude] session start (model %s)" % event.get("model", "?"), flush=True)
    elif kind == "assistant":
        for block in event.get("message", {}).get("content", []) or []:
            if block.get("type") == "text" and block.get("text", "").strip():
                for text_line in block["text"].strip().splitlines():
                    print("[claude] %s" % text_line, flush=True)
            elif block.get("type") == "tool_use":
                print("[claude] tool %s: %s" % (block.get("name", "?"), hint(block.get("input") or {})), flush=True)
    elif kind == "result":
        print("[claude] done: %s (%s turns)" % (event.get("subtype", "?"), event.get("num_turns", "?")), flush=True)
