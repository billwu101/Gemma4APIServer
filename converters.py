"""OpenAI / Anthropic 請求 <-> Ollama /api/chat 的格式轉換。"""
from config import ENABLE_THINKING, resolve_model


def _content_to_text(content) -> str:
    """把 str 或 [{type:text,text:...}, ...] 一律攤平成純文字（暫不處理圖片）。"""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
            elif isinstance(block, str):
                parts.append(block)
        return "".join(parts)
    return str(content)


def _options(body: dict) -> dict:
    """把取樣參數映射成 Ollama options。"""
    opts = {}
    if body.get("temperature") is not None:
        opts["temperature"] = body["temperature"]
    if body.get("top_p") is not None:
        opts["top_p"] = body["top_p"]
    if body.get("max_tokens") is not None:
        opts["num_predict"] = body["max_tokens"]
    stop = body.get("stop") or body.get("stop_sequences")
    if stop:
        opts["stop"] = [stop] if isinstance(stop, str) else stop
    return opts


# ── OpenAI ────────────────────────────────────────────────────
def openai_to_ollama(body: dict):
    model = resolve_model(body.get("model"))
    messages = [
        {"role": m.get("role", "user"), "content": _content_to_text(m.get("content"))}
        for m in body.get("messages", [])
    ]
    payload = {
        "model": model,
        "messages": messages,
        "stream": bool(body.get("stream")),
        "think": ENABLE_THINKING,
        "options": _options(body),
    }
    return payload, model


def ollama_to_openai(resp: dict, model: str, cid: str, created: int) -> dict:
    content = resp.get("message", {}).get("content", "")
    pt = resp.get("prompt_eval_count", 0) or 0
    ct = resp.get("eval_count", 0) or 0
    return {
        "id": cid,
        "object": "chat.completion",
        "created": created,
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": pt, "completion_tokens": ct, "total_tokens": pt + ct},
    }


# ── Anthropic ─────────────────────────────────────────────────
def anthropic_to_ollama(body: dict):
    model = resolve_model(body.get("model"))
    messages = []
    system = body.get("system")
    if system:
        messages.append({"role": "system", "content": _content_to_text(system)})
    for m in body.get("messages", []):
        messages.append({"role": m.get("role", "user"), "content": _content_to_text(m.get("content"))})
    payload = {
        "model": model,
        "messages": messages,
        "stream": bool(body.get("stream")),
        "think": ENABLE_THINKING,
        "options": _options(body),
    }
    return payload, model


def ollama_to_anthropic(resp: dict, model: str, mid: str) -> dict:
    content = resp.get("message", {}).get("content", "")
    pt = resp.get("prompt_eval_count", 0) or 0
    ct = resp.get("eval_count", 0) or 0
    return {
        "id": mid,
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": [{"type": "text", "text": content}],
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": pt, "output_tokens": ct},
    }
