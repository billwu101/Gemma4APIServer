"""設定：從 .env 載入後端位址、預設模型、金鑰、模型別名。"""
import os
from dotenv import load_dotenv

load_dotenv()

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434").rstrip("/")
DEFAULT_MODEL = os.getenv("DEFAULT_MODEL", "gemma4:26b")
ENABLE_THINKING = os.getenv("ENABLE_THINKING", "false").lower() in ("1", "true", "yes")
DB_PATH = os.getenv("DB_PATH", "usage.db")
HOST = os.getenv("HOST", "127.0.0.1")
PORT = int(os.getenv("PORT", "8000"))


def _load_keys() -> dict:
    """API_KEYS="name:key,name2:key2" -> {key: name}。沒寫 name 的歸為 default。"""
    keys = {}
    for item in os.getenv("API_KEYS", "").split(","):
        item = item.strip()
        if not item:
            continue
        if ":" in item:
            name, key = item.split(":", 1)
        else:
            name, key = "default", item
        keys[key.strip()] = name.strip()
    return keys


API_KEYS = _load_keys()

# 常見 OpenAI / Anthropic 模型名 -> 本機模型，讓現成 SDK 不用改 model 名就能打
MODEL_ALIASES = {
    "gpt-4o": DEFAULT_MODEL,
    "gpt-4o-mini": DEFAULT_MODEL,
    "gpt-4": DEFAULT_MODEL,
    "gpt-4-turbo": DEFAULT_MODEL,
    "gpt-3.5-turbo": DEFAULT_MODEL,
    "claude-3-5-sonnet-latest": DEFAULT_MODEL,
    "claude-3-5-sonnet-20241022": DEFAULT_MODEL,
    "claude-3-5-haiku-latest": DEFAULT_MODEL,
    "claude-3-opus-latest": DEFAULT_MODEL,
    "claude-sonnet-4": DEFAULT_MODEL,
    "gemma4": DEFAULT_MODEL,
}


def resolve_model(name: str | None) -> str:
    """別名 -> 實際模型；未列在別名表的名稱原樣傳給 Ollama（例如直接指定 gemma4:12b）。"""
    if not name:
        return DEFAULT_MODEL
    return MODEL_ALIASES.get(name, name)
