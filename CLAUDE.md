# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 這是什麼

把本機 Ollama（`gemma4:26b`）包成 **OpenAI 相容**與 **Anthropic 相容**的 HTTP API，
加上多把金鑰驗證與 SQLite 用量記錄。閘道器只綁 `127.0.0.1`，對外靠 Cloudflare Tunnel。
純文字轉發，**圖片與 tool-calling 尚未實作**。

## 工作流程（重要）

**任何對 repo 的改動,完成後一律 git commit 並 push 到 `origin main`** —— 這是使用者的長期指示,
不必每次再問。流程:

```powershell
git add <改動的檔案>
git commit -m "..."      # 訊息用繁中,結尾加 Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
git push origin main
```

- 相關但性質不同的改動**分開 commit**(例如編碼修正 vs 新功能)。
- push 用非互動模式避免卡在認證:先設 `$env:GIT_TERMINAL_PROMPT="0"`；憑證由 Git Credential
  Manager 記住。
- git 身分設在 repo local:`billwu101` / `bill.tpe101@gmail.com`。
- 不進版控:`.env`、`.venv/`、`logs/`、`usage.db`、`__pycache__/`(見 `.gitignore`)。

## 常用指令

部署一律走 **Docker**（本機原生 venv/排程工作那套已移除）。三支維運腳本：

```powershell
copy .env.example .env             # 首次設定；填入 API_KEYS 與 CLOUDFLARE_TUNNEL_TOKEN
python genkey.py alice             # 產一把金鑰，格式 name:sk-...，貼進 .env 的 API_KEYS

.\start-all.ps1                    # 一律 build 並啟動全部（ollama+gateway+cloudflared），進即時連線監看
.\start-all.ps1 -NoWatch           # 只啟動、不進監看（服務留背景跑）
.\stop-all.ps1                     # docker compose down（保留模型與 usage.db）
.\stop-all.ps1 -Purge              # 連模型 volume 一併刪
.\monitor-api.ps1                  # 每 60 秒實打 API + 取樣 GPU 峰值，彩色標示通/掉CPU/不通
```

- 首次要把模型拉進 ollama 容器：`docker compose exec ollama ollama pull gemma4:26b`（約 18GB，之後持久化）。
- Python 版本由 `.python-version` 釘在 3.12（pyenv）；容器 image 也是 python:3.12-slim。
- 容器內 uvicorn 一律綁 `0.0.0.0`（`.env` 的 `HOST` 不生效），加 `--proxy-headers` 讓 access log
  顯示真實使用者 IP；閘道器經 `OLLAMA_BASE_URL=http://ollama:11434` 連容器版 Ollama；`.env` 靠
  `env_file` 注入、不進 image。GPU 需 NVIDIA Container Toolkit，且會與本機 Ollama 搶 VRAM。
- ollama 容器設 `OLLAMA_KEEP_ALIVE=-1`（模型常駐 GPU）、gateway 設 `TZ=Asia/Taipei`（log 走 GMT+8）。
- **沒有測試套件**。驗證靠實打端點（見 README 的 curl 範例，或 `/health` 免金鑰）。
- 手動起單一服務（除錯用）：`docker compose up -d --build gateway`。

## 架構

單一 FastAPI app（`main.py`），對同一個本機 Ollama 後端開出**三條並存的請求路徑**：

1. **OpenAI 相容** `POST /v1/chat/completions` — `converters.openai_to_ollama` → Ollama `/api/chat`
   → `converters.ollama_to_openai`。
2. **Anthropic 相容** `POST /v1/messages` — `converters.anthropic_to_ollama`（會把 `system` 併入
   messages）→ `/api/chat` → `converters.ollama_to_anthropic`。
3. **Ollama 原生反向代理** `/api/{path}` — 原樣穿透到本機 11434，沿用同一把金鑰。
   `_PROXY_ALLOW` 白名單只放行推論/查詢類端點，破壞性的 `pull/push/create/delete/copy` 回 403。

關鍵差異：**路徑 1、2 會自動注入 `think` 參數**（值來自 `config.ENABLE_THINKING`，預設 false）；
**路徑 3 原樣轉發、不注入**。gemma4 是 thinking 模型，走原生路徑的客戶端必須自己在 body 帶
`"think": false`，否則會生成大量思考 token。這是刻意的設計，不是 bug。

其餘模組：
- `config.py` — 從 `.env` 載入設定。`API_KEYS` 解析成 `{key: name}`；`MODEL_ALIASES` 把常見
  OpenAI/Anthropic 模型名映射到 `DEFAULT_MODEL`；`resolve_model()` 對**未列在別名表的名稱原樣傳給
  Ollama**（所以客戶端可直接指定 `gemma4:12b` 之類）。
- `auth.py` — 同時吃 `Authorization: Bearer` 與 `x-api-key`，回傳金鑰的 name 供用量記錄。
- `converters.py` — `_content_to_text()` 把多模態 content block 攤平成純文字（圖片會被丟棄）。
  取樣參數（temperature/top_p/max_tokens→num_predict/stop）映射成 Ollama options。
- `ollama_client.py` — 共用的 async httpx client。**startup() 只建連線池、不連線**（lazy），
  所以閘道器可比 Ollama 早啟動；Ollama 不在時請求才會失敗。read timeout 設 None（本機推論可能很慢）。
- `db.py` — SQLite，每次請求 INSERT 一列（時間/金鑰名/格式/模型/token/串流/狀態）；`summary()` 彙總
  供 `GET /v1/usage`。token 數取自 Ollama 的 `prompt_eval_count`/`eval_count`，非分詞器結果，僅供計量。

串流：OpenAI 走 SSE `data:` 行、Anthropic 走具名 SSE event、原生路徑原樣穿透 NDJSON
（`application/x-ndjson`）。三者的串流組裝都在 `main.py` 的 `_openai_stream` / `_anthropic_stream` /
`ollama_proxy` 裡。

## Windows / Docker 陷阱（改動時務必注意）

- **`.ps1` 一律存成 UTF-8 with BOM。** Windows PowerShell 5.1（右鍵「以系統管理員身分執行」的預設）
  對無 BOM 檔用 ANSI 解碼，中文註解會變亂碼並炸 `The string is missing the terminator`。
  pwsh 7 不受影響，很容易漏掉。改任何 `.ps1` 後都在 5.1 下驗一次解析。
- **容器版 Ollama 會與本機 tray app 的 Ollama 搶 24GB VRAM。** 跑 `docker compose` 前建議先關掉
  本機 Ollama；否則同一顆 26b 載兩份會爆顯存。
- **自動啟動靠 Docker Desktop 設定 + `restart: unless-stopped`。** Docker Desktop 通常**登入後**才起，
  所以「開機未登入就要提供服務」的無人值守情境，容器不會自動起（原生排程工作那套已移除）。
- **監看視窗與服務解耦。** `start-all.ps1` 的即時監看按 Ctrl+C 會**自動 `docker compose down`**；
  想讓服務留背景跑就用 `-NoWatch` 啟動。`monitor-api.ps1` 只是打 API，關掉不影響容器。
- **PowerShell 的 `Invoke-WebRequest` 會被系統/conda proxy 影響**，連 localhost 也可能失敗；腳本裡
  改用 `docker inspect` healthcheck 狀態或 `curl.exe` 判斷就緒，別用它探測。
