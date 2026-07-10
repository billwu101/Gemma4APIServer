"""Gemma4 閘道器：OpenAI / Anthropic 相容 API -> 本機 Ollama。

路由：
  POST /v1/chat/completions   OpenAI 相容
  POST /v1/messages           Anthropic 相容
  GET  /v1/models             模型清單（別名 + Ollama 已裝模型）
  GET  /v1/usage              用量彙總
  GET  /health                健康檢查（免金鑰）
"""
import json
import logging
import time
import uuid
from contextlib import asynccontextmanager

import httpx
from fastapi import Depends, FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

import config
import converters
import db
import ollama_client
from auth import authenticate


def _add_log_timestamps() -> None:
    """在 uvicorn 的 log 每行前面補上日期時間（含 access log）。"""
    fmt = logging.Formatter(
        fmt="%(asctime)s | %(levelname)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        for handler in logging.getLogger(name).handlers:
            handler.setFormatter(fmt)


@asynccontextmanager
async def lifespan(app: FastAPI):
    _add_log_timestamps()
    db.init_db()
    ollama_client.startup()
    yield
    await ollama_client.shutdown()


app = FastAPI(title="Gemma4 Gateway", lifespan=lifespan)


def _sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


def _data(data: dict) -> str:
    return f"data: {json.dumps(data, ensure_ascii=False)}\n\n"


# ── OpenAI: /v1/chat/completions ──────────────────────────────
@app.post("/v1/chat/completions")
async def openai_chat(request: Request, key_name: str = Depends(authenticate)):
    body = await request.json()
    payload, model = converters.openai_to_ollama(body)
    cid = "chatcmpl-" + uuid.uuid4().hex
    created = int(time.time())
    include_usage = bool((body.get("stream_options") or {}).get("include_usage"))

    if payload["stream"]:
        return StreamingResponse(
            _openai_stream(payload, model, key_name, cid, created, include_usage),
            media_type="text/event-stream",
        )

    try:
        resp = await ollama_client.chat(payload)
    except httpx.HTTPError as e:
        db.log_usage(key_name, "openai", model, 0, 0, False, 502)
        return JSONResponse(status_code=502, content={"error": {"message": str(e), "type": "upstream_error"}})

    out = converters.ollama_to_openai(resp, model, cid, created)
    u = out["usage"]
    db.log_usage(key_name, "openai", model, u["prompt_tokens"], u["completion_tokens"], False, 200)
    return JSONResponse(out)


async def _openai_stream(payload, model, key_name, cid, created, include_usage):
    pt = ct = 0
    base = {"id": cid, "object": "chat.completion.chunk", "created": created, "model": model}
    yield _data({**base, "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]})
    try:
        async for chunk in ollama_client.chat_stream(payload):
            if chunk.get("done"):
                pt = chunk.get("prompt_eval_count", 0) or 0
                ct = chunk.get("eval_count", 0) or 0
                break
            delta = chunk.get("message", {}).get("content", "")
            if delta:
                yield _data({**base, "choices": [{"index": 0, "delta": {"content": delta}, "finish_reason": None}]})
        yield _data({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        if include_usage:
            yield _data({**base, "choices": [],
                         "usage": {"prompt_tokens": pt, "completion_tokens": ct, "total_tokens": pt + ct}})
        yield "data: [DONE]\n\n"
        db.log_usage(key_name, "openai", model, pt, ct, True, 200)
    except Exception as e:  # 上游斷線 / 錯誤
        db.log_usage(key_name, "openai", model, pt, ct, True, 502)
        yield _data({"error": {"message": str(e), "type": "upstream_error"}})


# ── Anthropic: /v1/messages ───────────────────────────────────
@app.post("/v1/messages")
async def anthropic_messages(request: Request, key_name: str = Depends(authenticate)):
    body = await request.json()
    payload, model = converters.anthropic_to_ollama(body)
    mid = "msg_" + uuid.uuid4().hex

    if payload["stream"]:
        return StreamingResponse(
            _anthropic_stream(payload, model, key_name, mid),
            media_type="text/event-stream",
        )

    try:
        resp = await ollama_client.chat(payload)
    except httpx.HTTPError as e:
        db.log_usage(key_name, "anthropic", model, 0, 0, False, 502)
        return JSONResponse(status_code=502, content={"type": "error", "error": {"type": "api_error", "message": str(e)}})

    out = converters.ollama_to_anthropic(resp, model, mid)
    u = out["usage"]
    db.log_usage(key_name, "anthropic", model, u["input_tokens"], u["output_tokens"], False, 200)
    return JSONResponse(out)


async def _anthropic_stream(payload, model, key_name, mid):
    pt = ct = 0
    yield _sse("message_start", {"type": "message_start", "message": {
        "id": mid, "type": "message", "role": "assistant", "model": model,
        "content": [], "stop_reason": None, "stop_sequence": None,
        "usage": {"input_tokens": 0, "output_tokens": 0}}})
    yield _sse("content_block_start", {"type": "content_block_start", "index": 0,
                                       "content_block": {"type": "text", "text": ""}})
    yield _sse("ping", {"type": "ping"})
    try:
        async for chunk in ollama_client.chat_stream(payload):
            if chunk.get("done"):
                pt = chunk.get("prompt_eval_count", 0) or 0
                ct = chunk.get("eval_count", 0) or 0
                break
            delta = chunk.get("message", {}).get("content", "")
            if delta:
                yield _sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                                                   "delta": {"type": "text_delta", "text": delta}})
        yield _sse("content_block_stop", {"type": "content_block_stop", "index": 0})
        yield _sse("message_delta", {"type": "message_delta",
                                     "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                     "usage": {"output_tokens": ct}})
        yield _sse("message_stop", {"type": "message_stop"})
        db.log_usage(key_name, "anthropic", model, pt, ct, True, 200)
    except Exception as e:
        db.log_usage(key_name, "anthropic", model, pt, ct, True, 502)
        yield _sse("error", {"type": "error", "error": {"type": "api_error", "message": str(e)}})


# ── 輔助路由 ──────────────────────────────────────────────────
@app.get("/v1/models")
async def list_models(key_name: str = Depends(authenticate)):
    created = int(time.time())
    ids = set(config.MODEL_ALIASES.keys())
    try:
        for m in (await ollama_client.tags()).get("models", []):
            if m.get("name"):
                ids.add(m["name"])
    except Exception:
        pass
    data = [{"id": i, "object": "model", "created": created, "owned_by": "gemma4-gateway"}
            for i in sorted(ids)]
    return {"object": "list", "data": data}


@app.get("/v1/usage")
async def usage(key_name: str = Depends(authenticate)):
    return db.summary()


# ── Ollama 原生 API 代理：/api/* -> 本機 11434（沿用同一把 key）──
# 只放行推論/查詢類端點；破壞性的 pull/push/create/delete/copy 不開放（要的話再加）
_PROXY_ALLOW = {"chat", "generate", "tags", "show", "ps", "version", "embeddings", "embed"}


@app.api_route("/api/{path:path}", methods=["GET", "POST"])
async def ollama_proxy(path: str, request: Request, key_name: str = Depends(authenticate)):
    top = path.split("/", 1)[0]
    if top not in _PROXY_ALLOW:
        return JSONResponse(status_code=403, content={"error": {
            "message": f"/api/{path} 未開放經由 gateway 代理", "type": "forbidden"}})

    body = await request.body()
    model = ""
    if body:
        try:
            model = json.loads(body).get("model", "") or ""
        except Exception:
            pass
    fwd_headers = {}
    if request.headers.get("content-type"):
        fwd_headers["content-type"] = request.headers["content-type"]

    # 先開上游串流以取得 status/content-type，再原樣穿透 body（支援 NDJSON 串流）
    cm = ollama_client.raw_stream(
        request.method, f"/api/{path}",
        params=dict(request.query_params), content=body, headers=fwd_headers,
    )
    try:
        upstream = await cm.__aenter__()
    except httpx.HTTPError as e:
        db.log_usage(key_name, "ollama", model, 0, 0, False, 502)
        return JSONResponse(status_code=502, content={"error": {"message": str(e), "type": "upstream_error"}})

    async def body_iter():
        try:
            async for chunk in upstream.aiter_raw():
                yield chunk
        finally:
            await cm.__aexit__(None, None, None)
            db.log_usage(key_name, "ollama", model, 0, 0, True, upstream.status_code)

    return StreamingResponse(
        body_iter(),
        status_code=upstream.status_code,
        media_type=upstream.headers.get("content-type", "application/json"),
    )


@app.get("/health")
async def health():
    return {"status": "ok"}
