"""金鑰驗證：同時支援 OpenAI (Authorization: Bearer) 與 Anthropic (x-api-key)。"""
from fastapi import HTTPException, Request

from config import API_KEYS


def _extract_key(request: Request) -> str | None:
    auth = request.headers.get("authorization")
    if auth and auth.lower().startswith("bearer "):
        return auth[7:].strip()
    xkey = request.headers.get("x-api-key")
    if xkey:
        return xkey.strip()
    return None


async def authenticate(request: Request) -> str:
    """驗證通過回傳 key 的 name（供用量記錄用）；失敗丟 401。"""
    key = _extract_key(request)
    if not key or key not in API_KEYS:
        raise HTTPException(
            status_code=401,
            detail={"error": {"message": "Invalid API key", "type": "authentication_error"}},
        )
    return API_KEYS[key]
