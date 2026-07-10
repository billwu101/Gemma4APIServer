"""Ollama 後端的 async HTTP 客戶端（共用連線池）。"""
import json

import httpx

from config import OLLAMA_BASE_URL

# read=None：本機推論可能很慢，不設讀取逾時，避免長生成被中斷
_timeout = httpx.Timeout(connect=10.0, read=None, write=30.0, pool=10.0)
_client: httpx.AsyncClient | None = None


def startup() -> None:
    global _client
    _client = httpx.AsyncClient(base_url=OLLAMA_BASE_URL, timeout=_timeout)


async def shutdown() -> None:
    if _client is not None:
        await _client.aclose()


async def chat(payload: dict) -> dict:
    r = await _client.post("/api/chat", json=payload)
    r.raise_for_status()
    return r.json()


async def chat_stream(payload: dict):
    """逐行 yield Ollama 的 NDJSON 串流（每行已 parse 成 dict）。"""
    async with _client.stream("POST", "/api/chat", json=payload) as r:
        r.raise_for_status()
        async for line in r.aiter_lines():
            if line.strip():
                yield json.loads(line)


async def tags() -> dict:
    r = await _client.get("/api/tags")
    r.raise_for_status()
    return r.json()


def raw_stream(method: str, url: str, params=None, content=None, headers=None):
    """回傳 httpx 串流 context manager，供 /api/* 原生代理原樣穿透用。"""
    return _client.stream(method, url, params=params, content=content, headers=headers)
