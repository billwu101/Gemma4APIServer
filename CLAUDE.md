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

```powershell
.\start.ps1                        # 建 venv、裝套件、啟動於 .env 的 HOST:PORT（前景）
python genkey.py alice             # 產一把金鑰，格式 name:sk-...，貼進 .env 的 API_KEYS
copy .env.example .env             # 首次設定；沒有 .env 時 start.ps1 會自動複製並要你回填

.\install-autostart.ps1            # 註冊開機自動啟動的排程工作（需管理員；細節見 README §1b）
.\install-autostart.ps1 -Uninstall
.\tail-log.ps1                     # 彩色即時追 logs\gateway.log（排程工作跑時才有此檔）
```

- Python 版本由 `.python-version` 釘在 3.12（pyenv）。`uvicorn[standard]` 的相依在 3.12 有現成
  wheel，3.13 需自行編譯。
- **沒有測試套件**。驗證靠實打端點（見 README 的 curl 範例，或 `/health` 免金鑰）。
- 手動起服務：`.\.venv\Scripts\python.exe -m uvicorn main:app --host 127.0.0.1 --port 8000`。

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

## Windows 部署陷阱（改動時務必注意）

- **`.ps1` 一律存成 UTF-8 with BOM。** Windows PowerShell 5.1（右鍵「以系統管理員身分執行」的預設）
  對無 BOM 檔用 ANSI 解碼，中文註解會變亂碼並炸 `The string is missing the terminator`。
  pwsh 7 不受影響，很容易漏掉。改任何 `.ps1` 後都在 5.1 下驗一次解析。
- **開機自動啟動用排程工作 + S4U 身分，不能用 SYSTEM。** Ollama 會去 `systemprofile` 找模型，
  看不到 `%USERPROFILE%\.ollama\models`。排程工作跑起來的行程是 S4U token，**標準權限殺不掉**
  （`Access is denied`），要 `Stop-ScheduledTask` 或提權 `taskkill`。
- Ollama 預設由 Startup 資料夾的 tray app 在**登入時**啟動（非開機）。因此開機後到登入前，閘道器
  活著但後端不在：`/health` 回 200，chat 一律 502。
- 排程工作透過 `run-gateway.ps1` 這層 wrapper 啟動，才能把 uvicorn 輸出導到 `logs\gateway.log`
  （排程工作直接 CreateProcess 沒辦法重導向）。shell 用穩定的 WindowsApps `pwsh.exe` alias，
  避免 pwsh 升級後帶版號的路徑失效。
