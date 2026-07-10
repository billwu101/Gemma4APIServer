# Gemma4 API Gateway

把本機 Ollama（`gemma4:26b`）包成 **OpenAI 相容** 與 **Anthropic 相容** 的公網 API，
用 **多把金鑰 + SQLite 用量記錄** 控管，透過 **Cloudflare Tunnel** 對外。

```
OpenAI SDK  ─┐
             ├─►  Cloudflare Tunnel ─►  FastAPI 閘道器  ─►  Ollama (localhost:11434) ─► gemma4:26b
Claude SDK  ─┘        (公網 HTTPS)      金鑰/轉換/記錄
```

## 架構

| 檔案 | 職責 |
| --- | --- |
| `main.py` | FastAPI 路由、串流組裝 |
| `auth.py` | 金鑰驗證（Bearer + x-api-key 都吃）|
| `converters.py` | OpenAI/Anthropic ↔ Ollama 格式轉換 |
| `ollama_client.py` | 連 Ollama 的 async 客戶端 |
| `db.py` | SQLite 用量記錄 |
| `config.py` | 設定、模型別名 |

## 1. 安裝與啟動（本機）

```powershell
cd C:\Users\RTX4090\Documents\Gemma4API
python genkey.py alice     # 產一把金鑰，貼進 .env 的 API_KEYS
copy .env.example .env     # 編輯 .env 填入金鑰
.\start.ps1                # 建 venv、裝套件、啟動於 127.0.0.1:8000
```

先確認 Ollama 有在跑、模型在：`ollama ps`、`ollama list`。

## 2. 對外：Cloudflare Tunnel

```powershell
# 安裝一次
winget install --id Cloudflare.cloudflared

# 最快：臨時網址（每次重開會變）
cloudflared tunnel --url http://127.0.0.1:8000
#  -> 會印出 https://xxxx-xxxx.trycloudflare.com

# 正式：綁自己網域的具名 tunnel（網址固定）
cloudflared tunnel login
cloudflared tunnel create gemma4
cloudflared tunnel route dns gemma4 api.yourdomain.com
cloudflared tunnel run --url http://127.0.0.1:8000 gemma4
```

> 閘道器只綁 `127.0.0.1`，唯一入口是 Tunnel；金鑰是唯一防線，別把 `.env` 外流。

## 3. 用 OpenAI 方式存取

```python
from openai import OpenAI
client = OpenAI(base_url="https://api.yourdomain.com/v1", api_key="sk-你的金鑰")

r = client.chat.completions.create(
    model="gpt-4o",                       # 別名，實際打 gemma4:26b
    messages=[{"role": "user", "content": "你好"}],
)
print(r.choices[0].message.content)
```

## 4. 用 Claude 方式存取

```python
import anthropic
client = anthropic.Anthropic(base_url="https://api.yourdomain.com", api_key="sk-你的金鑰")

r = client.messages.create(
    model="claude-3-5-sonnet-latest",     # 別名，實際打 gemma4:26b
    max_tokens=1024,
    messages=[{"role": "user", "content": "你好"}],
)
print(r.content[0].text)
```

兩種格式都支援 `stream=True`。

## 5. curl 快測

```bash
curl https://api.yourdomain.com/v1/chat/completions \
  -H "Authorization: Bearer sk-你的金鑰" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}'

curl https://api.yourdomain.com/v1/messages \
  -H "x-api-key: sk-你的金鑰" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
  -d '{"model":"claude-3-5-sonnet-latest","max_tokens":1024,"messages":[{"role":"user","content":"hello"}]}'
```

## 5b. 原生 Ollama API（同一把金鑰）

Gateway 也把 Ollama 原生 API 反向代理到本機 `11434`，沿用同一把金鑰。
讓吃原生 Ollama 的客戶端（帶 Bearer key）直接指過來即可：

```bash
curl http://api.yourdomain.com/api/chat \
  -H "Authorization: Bearer sk-你的金鑰" -H "Content-Type: application/json" \
  -d '{"model":"gemma4:26b","messages":[{"role":"user","content":"hi"}],"stream":true}'

curl http://api.yourdomain.com/api/tags -H "Authorization: Bearer sk-你的金鑰"
```

- **放行端點**：`/api/chat`、`/api/generate`、`/api/tags`、`/api/show`、`/api/ps`、`/api/version`、`/api/embeddings`、`/api/embed`。
- **擋掉的**：`pull`/`push`/`create`/`delete`/`copy`（破壞性，回 403；要開放改 `_PROXY_ALLOW`）。
- **串流**：原生 NDJSON 原樣穿透（`application/x-ndjson`）。
- ⚠️ **原生路徑是原樣轉發，不會自動注入 `think:false`**。gemma4 是 thinking 模型，
  客戶端請自行在 body 帶 `"think": false`，否則會生成大量思考 token（燒 GPU、變慢）。
  （`/v1/*` 那條 OpenAI/Anthropic 路徑則會自動帶 `think:false`。）

## 6. 用量查詢

```bash
curl https://api.yourdomain.com/v1/usage -H "Authorization: Bearer sk-你的金鑰"
```

或直接查 `usage.db`（每次請求一列：時間、金鑰名、格式、模型、token 數、狀態）。

## 設定（.env）

| 變數 | 說明 |
| --- | --- |
| `DEFAULT_MODEL` | 別名指向的模型，預設 `gemma4:26b`（此 VM CUDA 可跑）|
| `ENABLE_THINKING` | gemma4 是 thinking 模型，保持 `false` 才回答案 |
| `API_KEYS` | `name:key` 逗號分隔，多把金鑰 |
| `HOST`/`PORT` | 閘道器綁定，預設 `127.0.0.1:8000` |

## 已知注意事項

- 若換回 CUDA 會死鎖的 VM，把 `DEFAULT_MODEL` 改成 `gemma4:12b`（Vulkan）或走 CPU 的 26b。
- 目前只轉文字；圖片/tool-calling 尚未實作。
- token 數取自 Ollama 的 `prompt_eval_count` / `eval_count`，非 OpenAI 分詞器結果，僅供計量參考。
