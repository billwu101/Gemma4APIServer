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

## 1. 部署（Docker）

閘道器、Ollama、Cloudflare tunnel 三個服務都在容器裡，一鍵帶起（`docker-compose.yml`）。

需求：Docker Desktop（Windows 需 WSL2 後端）；GPU 透傳需 **NVIDIA Container Toolkit**
（沒 GPU 也能跑，只是慢）。

```powershell
copy .env.example .env       # 填 API_KEYS 與 CLOUDFLARE_TUNNEL_TOKEN
python genkey.py alice       # 產一把金鑰，貼進 .env 的 API_KEYS

.\start-all.ps1              # 一律 build 並啟動全部，之後進即時連線監看
```

首次要把模型拉進 ollama 容器的 volume（只需一次，之後持久化）：

```powershell
docker compose exec ollama ollama pull gemma4:26b
```

### 維運腳本

```powershell
.\start-all.ps1            # build + 啟動全部 + 即時連線監看；Ctrl+C 自動關閉全部
.\start-all.ps1 -NoWatch   # 只啟動、不進監看（服務留背景跑）
.\stop-all.ps1             # 關閉全部（保留模型與 usage.db）
.\stop-all.ps1 -Purge      # 連模型 volume 一併刪
.\monitor-api.ps1          # 每 60 秒實打 API + 取樣 GPU，彩色標示通/掉CPU/不通
```

- **三服務**：`ollama`（GPU、`OLLAMA_KEEP_ALIVE=-1` 模型常駐）、`gateway`（FastAPI 閘道器）、
  `cloudflared`（具名 tunnel，token 走 `.env`，見 §2）。
- **閘道器連容器版 Ollama**：compose 用 `OLLAMA_BASE_URL=http://ollama:11434` 蓋掉 `.env` 的 `localhost`。
- **埠綁 `0.0.0.0:8000`**：局域網可連（`.env` 的 `HOST` 在容器內不生效）。金鑰是唯一防線。
- **真實 IP + GMT+8**：uvicorn 帶 `--proxy-headers`，access log 顯示經 tunnel 來的真實使用者 IP；
  gateway 時區 `Asia/Taipei`。
- **持久化**：模型存在 `ollama-models` volume，用量 `usage.db` 存在 `./data`。
- **自動啟動**：靠 Docker Desktop 的「登入時啟動」設定 + compose 的 `restart: unless-stopped`。
- ⚠️ **GPU 記憶體**：容器版 Ollama 會吃 GPU。若本機 tray app 的 Ollama 也載著同顆模型，
  24GB VRAM 會不夠 —— 跑 compose 時建議先關掉本機 Ollama。
- `.env` 不會烤進 image（`.dockerignore` 擋掉），執行時由 compose 的 `env_file` 注入。

Python 版本由 `.python-version`（pyenv）釘在 3.12；容器 image 也是 python:3.12-slim。

## 2. 對外：Cloudflare Tunnel（容器內）

tunnel 由 compose 的 `cloudflared` 服務跑，不需另裝 cloudflared。設定一次：

1. Zero Trust 後台 → **Networks → Tunnels → Create tunnel** → 選 **Cloudflared**，命名。
2. 複製顯示的 **token**（`eyJ...` 開頭），貼進 `.env` 的 `CLOUDFLARE_TUNNEL_TOKEN=`。
3. 同一 tunnel 的 **Public Hostname** 頁籤新增一條：綁你的網域子網域，**Service** 填
   `http://gateway:8000`（走 Docker 內部網路，不是 localhost）。
4. `.\start-all.ps1`（或 `docker compose up -d`）即會帶起 tunnel。
   確認：`docker compose logs cloudflared` 看到 `Registered tunnel connection`。

> 閘道器不對公網直接開放，唯一入口是 tunnel；金鑰是唯一防線，別把 `.env`（含金鑰與 token）外流。
> 若只要臨時測試、不綁網域，也可自行 `cloudflared tunnel --url http://localhost:8000` 跑臨時網址。

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
| `CLOUDFLARE_TUNNEL_TOKEN` | 具名 tunnel 的 token（`eyJ...`），供容器內 cloudflared 連線 |
| `HOST`/`PORT` | 閘道器綁定；**容器內不生效**（一律綁 `0.0.0.0:8000`），僅非容器手動跑時有用 |

## 已知注意事項

- **`.ps1` 一律存成 UTF-8 with BOM。** Windows PowerShell 5.1（右鍵「以系統管理員身分執行」開的那個）
  對無 BOM 的檔案用 ANSI 解碼，中文註解會變亂碼並炸出 `The string is missing the terminator`。
  pwsh 7 沒這問題，所以很容易漏掉。
- 若換回 CUDA 會死鎖的 VM，把 `DEFAULT_MODEL` 改成 `gemma4:12b`（Vulkan）或走 CPU 的 26b。
- 目前只轉文字；圖片/tool-calling 尚未實作。
- token 數取自 Ollama 的 `prompt_eval_count` / `eval_count`，非 OpenAI 分詞器結果，僅供計量參考。
