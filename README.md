# open-appsec attachment 修正版

這個儲存庫是 open-appsec attachment 的 fork。兩個修正分支的內容如下：

- 修正 Kong 外掛和 NGINX 模組的漏擋、誤擋、記憶體錯誤和效能問題。
- 記錄修正前後的防護測試與效能測試結果。

## 出處

| 項目 | 內容 |
|---|---|
| 上游專案 | [openappsec/attachment](https://github.com/openappsec/attachment) |
| 修正的基底版本 | 上游 `main` 的 commit [`4c88f63`](https://github.com/openappsec/attachment/commit/4c88f6389e301fd1958b0448f0e0ce01888a20c5)（Aug 18 2026 dev） |
| 原本的 README | [上游 README](https://github.com/openappsec/attachment/blob/4c88f6389e301fd1958b0448f0e0ce01888a20c5/README.md)，內容包括專案介紹和 NGINX attachment 的編譯步驟 |
| open-appsec 文件 | [docs.openappsec.io](https://docs.openappsec.io/) |
| 授權 | Apache License 2.0，與上游相同，見 [LICENSE](LICENSE) |

本 fork 的 `main` 分支已依序合併下面兩個修正分支：先合併 Kong 外掛分支，再合併 NGINX 模組分支。

## 分支

| 分支 | 修改範圍 | 詳細文件 |
|---|---|---|
| [`fix/kong-plugin-header-leak-and-chunked-bypass`](https://github.com/dark610172/attachment/tree/fix/kong-plugin-header-leak-and-chunked-bypass) | Kong Lua 外掛與共用的 `nano_attachment` 程式庫 | [docs/waf-test-results.md](https://github.com/dark610172/attachment/blob/fix/kong-plugin-header-leak-and-chunked-bypass/docs/waf-test-results.md) |
| [`fix/nginx-module`](https://github.com/dark610172/attachment/tree/fix/nginx-module) | NGINX 動態模組（`attachments/nginx/ngx_module/`，sync 與 async 兩條路徑） | [docs/nginx-module-fixes.md](https://github.com/dark610172/attachment/blob/fix/nginx-module/docs/nginx-module-fixes.md)、[端對端測試說明](https://github.com/dark610172/attachment/blob/fix/nginx-module/attachments/nginx/ngx_module/tests/e2e/README.md) |

兩個分支各自從 `4c88f63` 開始。gzip 解壓縮上限的修正兩邊都有，因為兩者連結同一個共用函式庫。

## 改善內容

### Kong 外掛分支

| 問題 | 修正前 | 修正後 |
|---|---|---|
| chunked body 繞過 | chunked 傳送的 body 不會被檢查，攻擊直接通過 | chunked body 也會送去檢查 |
| header 字串記憶體洩漏 | 每個 header 都漏一份記憶體 | 用完即釋放 |
| 每個請求強制完整 GC | 每個請求結束都跑 `collectgarbage("collect")`，每秒只有 12–50 個請求 | 改成 `collectgarbage("restart")`，速度快約 100 倍，Lua 堆積穩定在 144–171 MB |
| header 數量超過上限 | 越界讀取 | 數量限制在 `MAX_HEADERS` |
| 沒有 session 的回應 | Kong 自己回應（404、426）時，header filter 出錯，請求卡住 | 沒有 session 就跳過 |
| session 初始化失敗 | 清理旗標沒有設定，資源沒有釋放 | 失敗時也會清理 |
| async 模式沒有 body 的請求 | 結束訊息送兩次 | 只送一次 |
| gzip/zlib 解壓縮 | 輸出大小沒有上限 | 上限 256 MB，與 Brotli 相同 |
| debug log 格式字串 | 多一個逗號，初始化時會當掉 | 已修 |
| 外掛執行順序 | open-appsec 排在 CrowdSec 和 request-size-limiting 前面 | 改成 CrowdSec 先、request-size-limiting 次之、open-appsec 最後 |

### NGINX 模組分支

| 問題 | 修正前 | 修正後 |
|---|---|---|
| body 緩衝長度存成 16 位元 | 單一緩衝超過 64 KiB 就被截斷。600 KB JSON 尾端的 SQLi 被放行，70 KB 到 300 MB 的合法上傳反而被擋 | body 分成每段最多 32 KiB 送出，不重送也不跳過 |
| HTTP/2 被擋的請求 | 同一個請求被結束兩次，使用已釋放的記憶體，worker 偶爾當掉 | 只結束一次 |
| async 模式漏擋 | worker 的第一個請求在 header 走 sync、body 走 async，async 判斷「模式不符」就放行 | session 保持開始時的模式 |
| async 模式等待 agent | 每個 body 片段都重設逾時計時器。agent 回得慢時，一個請求可以卡 20–60 秒 | 只計算等待 agent 回覆的時間，上限是 3 秒與 5 秒中較大的值。客戶端上傳的時間不算 |
| IPC 大小與佇列錯誤 | 一個請求的錯誤會影響之後的請求 | 錯誤只影響發生的那個請求 |
| 記憶體錯誤 | 回應緩衝提早釋放、清單邊界越界、自訂回應共用記憶體、阻擋頁長度沒有限制 | 都已修 |
| 判定處理 | 部分送出後收到的最終判定，可能被之後的錯誤改成放行；async 的 INJECT、CUSTOM_RESPONSE 處理錯誤 | 最終判定不會再被改掉；判定依類型正確處理 |
| 只存在檔案裡的 body | 被當成空內容放行 | 視為檢查失敗，依失敗策略處理 |
| gzip/zlib 解壓縮 | 輸出大小沒有上限 | 上限 256 MB |

這個分支也加了測試：

- `attachments/nginx/ngx_module/tests/e2e/`：用 Docker 跑的端對端測試，共 5 組。
- `attachments/nginx/ngx_module/tests/formal/`：用 Lean 4 寫的 body 片段迴圈模型。

## 測試架構與資源配置

### 實體主機

所有測試 VM 都在同一台 Proxmox VE 主機上，網路走同一個虛擬橋接器（`vmbr0`），流量不經過外部網路、Cloudflare 或 VPN。

| 項目 | 規格 |
|---|---|
| CPU | AMD Ryzen 5 5600X，6 核 12 執行緒 |
| 記憶體 | 62 GB |
| 虛擬化 | Proxmox VE 9.2，VM 使用 `cpu host`，不啟用記憶體氣球 |

### Kong 外掛的測試

三台 VM 分開：測試機、被測系統、後端。

```
VM117 測試機  ──HTTP──▶  VM112 被測系統                         ──▶  VM113 後端
wrk、WCP 資料集          Kong 3.14 LTS + CrowdSec + open-appsec        WCP 回應服務、Juice Shop
```

| VM | 角色 | vCPU | 記憶體 | 磁碟 | 軟體 |
|---|---|---|---|---|---|
| VM112 | 被測系統 | 6（2026-11-11 以前是 8） | 32 GB | 50 GB | Ubuntu 26.04.1、Docker、Kong Gateway 3.14 LTS、CrowdSec（bouncer 與 AppSec）、open-appsec agent |
| VM113 | 後端 | 2 | 4 GB | 30 GB | 測試用後端應用 |
| VM117 | 測試機 | 4 | 12 GB | 30 GB 系統碟加 118 GB 資料碟 | Ubuntu 26.04.1、wrk 4.1.0、WCP 測試工具 |

### NGINX 模組的測試

| VM | 角色 | vCPU | 記憶體 | 內容 |
|---|---|---|---|---|
| VM123 | 被測系統與建置機 | 8 | 16 GB | Ubuntu 26.04.1、Docker 29.1。容器：open-appsec agent、NGINX 加本模組、後端（nginx:alpine 靜態檔，和一個回傳 body 長度與 SHA-256 的小服務） |
| VM117 | 測試機 | 4 | 12 GB | wrk 4.1.0，壓力測試時從這台送流量 |

- 端對端測試在 VM123 本機執行，只看結果對不對，不量效能。
- 效能測試的流量一律從 VM117 送出，測試機和被測系統不在同一台。
- 軟體版本：NGINX 1.30.4（取自 `ghcr.io/openappsec/nginx-attachment:1.1.36`），agent `ghcr.io/openappsec/agent:1.1.36` 與 `latest`，政策 prevent-learn。
- 模組在同一個 Alpine 映像內編譯。自己編的原版模組和官方模組大小相差不到 200 bytes。

### 量測方法

- 每個情境正式量測前先暖機，暖機結果不計入。
- 每組至少跑 3 次，不同版本輪流跑。
- 測試機 CPU 必須低於 70%。超過就標記，表示瓶頸可能在測試機。
- 防護測試的資料集是 WCP 2025-2026 公開 WAF 比較資料集，約 111 萬筆請求，其中惡意請求 73,924 筆。
- 判斷指標：
  - 真陽性率（TPR）：惡意請求被擋下的比例。
  - 真陰性率（TNR）：正常請求被放行的比例。
  - 平衡準確率（BA）：上面兩者的平均。

## 防護測試結果

### Kong 外掛分支（WCP 資料集）

| 設定 | 真陽性率 | 真陰性率 | 平衡準確率 |
|---|---|---|---|
| 修正前：官方外掛，基本模型 | 96.8% | 96.1% | 96.5% |
| 只有 open-appsec（本分支，進階模型） | 98.6% | 98.4% | 98.5% |
| 只有 CrowdSec（調整後的 OWASP CRS） | 89.0% | 97.6% | 93.3% |
| 完整組合：CrowdSec 加 open-appsec | 99.9% | 96.1% | 98.0% |

- 這些數字同時改了外掛和模型，沒有拆開比較各自的貢獻。
- 實際攻擊測試共 8 項。只有完整組合全部擋下；兩個單獨模式各漏一項，漏的項目不同。
- 各類攻擊的擋下比例和 CRS 調整方式，見 [docs/waf-test-results.md](https://github.com/dark610172/attachment/blob/fix/kong-plugin-header-leak-and-chunked-bypass/docs/waf-test-results.md)。

### NGINX 模組分支（端對端測試）

端對端測試有 5 組：功能、上傳、Kong 版問題、HTTP/2、慢速 agent。

| 版本 | 結果 |
|---|---|
| 官方映像 `nginx-attachment:1.1.36`（較早的 58 項版本） | 52 項通過，6 項失敗 |
| 本分支，sync 模式 | 66 項全部通過 |
| 本分支，async 模式 | 69 項全部通過 |

官方映像失敗的 6 項：

- 緩衝 1m 時，70 KB 和 600 KB 的正常 body 被誤擋。
- 緩衝 1m 時，用 Content-Length 的上傳被擋。
- HTTP/2 測試出現 39 次「http request count is zero」警告。

`client_body_buffer_size` 設為 1m 和 8k 時的 JSON 攻擊結果：

| body 大小 | 原版 1m（正常／開頭攻擊／結尾攻擊） | 修正版 1m |
|---|---|---|
| 約 70 KB | **403**／403／403 | 200／403／403 |
| 約 600 KB | **403**／403／**200** | 200／403／403 |

粗體是錯誤結果。8k 時原版和修正版都正確。修正版上傳 1 MB、50 MB、300 MB 時，後端收到的內容 SHA-256 都和送出的一致。

## 效能測試結果

### Kong 外掛分支

只開 open-appsec，每秒請求數：

| 並發 | 官方外掛 | 本分支 | NGINX 原生模組 |
|---|---|---|---|
| 4 | 13–26 | 3,536–3,660 | 3,545–3,812 |
| 8 | 12–42 | 4,348–4,765 | 5,156–5,302 |
| 16 | 41–50 | 5,651–6,193 | 6,259–6,361 |
| 50 KB POST | 13–29 | 134–281 | 121–208 |

各模式的承載能力（並發 64，每秒請求數／第 99 百分位延遲）：

| 情境 | 只有 Kong | 只有 CrowdSec | 只有 open-appsec | 完整組合 |
|---|---|---|---|---|
| GET | 11,445／13 ms | 2,591／36 ms | 4,852／47 ms | 1,805／92 ms |
| XSS 攻擊 | 11,460／12 ms | 1,088／100 ms | 2,652／85 ms | 994／109 ms |
| 50 KB POST | 7,173／28 ms | 21／3,020 ms | 385／861 ms | 20／3,170 ms |

50 KB POST 的瓶頸是 CrowdSec 的 CRS 檢查。最終設定讓超過 64 KB 的 body 不送 CRS 檢查。

### NGINX 模組分支

**修正前後比較**（sync 模式，`client_body_buffer_size 8k`，並發 16，各跑 3 次）：

| 情境 | 原版 | 修正版 | 中位數差異 |
|---|---|---|---|
| GET 小回應，每秒請求數 | 7,508／7,595／7,537 | 7,524／6,522／7,501 | -0.5% |
| POST 50 KB JSON，每秒請求數 | 339.5／338.7／337.6 | 335.0／337.7／336.9 | -0.5% |

差異在測量誤差範圍內。

**最終版本的負載測試**（commit `750e6dc`，用 Kong 外掛的同一套量法，每格是 3 次的中位數）：

| 情境 | 並發 | sync 每秒請求數 | sync 第 99 百分位 | async 每秒請求數 | async 第 99 百分位 |
|---|---|---|---|---|---|
| GET | 16 | 6,842 | 5.3 ms | 7,301 | 4.4 ms |
| GET | 64 | 7,483 | 15.5 ms | 9,897 | 15.1 ms |
| GET | 256 | 7,517 | 49.5 ms | 11,484 | 50.6 ms |
| GET 帶參數 | 256 | 7,206 | 53.0 ms | 10,857 | 53.0 ms |
| POST 50 KB | 16 | 403 | 86.3 ms | 306 | 97.0 ms |
| POST 50 KB | 64 | 410 | 224.0 ms | 519 | 238.9 ms |
| POST 50 KB | 256 | 408 | 738.4 ms | 534 | 674.0 ms |
| XSS 攻擊 | 64 | 2,924 | 34.8 ms | 2,946 | 31.6 ms |
| XSS 攻擊 | 256 | 1,215 | 418.9 ms | 1,190 | 424.2 ms |

- 所有回合都沒有連線錯誤或逾時，NGINX worker 沒有當掉。
- 測試機 CPU 最高 59%。
- 這個 50 KB 內容會被 agent 判成攻擊，所以回 403。這個數字是完整檢查一個 50 KB body 的速度。
- 少數回合的第 99 百分位會跳到約 1–4.6 秒。原因是 agent 本身偶爾停頓，修正前的版本也一樣。

**async 模式卡住請求的修正**（366 KB POST，並發 64，150 秒，agent 處理變慢）：

| 版本 | 第 1 次：超過 10 秒的請求 | 第 2 次：超過 10 秒的請求 |
|---|---|---|
| 修正前的建置 A | 35 | 0 |
| 修正前的建置 B | 0 | 7 |
| 最終版本 | 0 | 0 |

最終版本在這個負載下，最長的請求是 11.9 秒，等於各階段時間上限的總和，所以有上限，不會無限等待。

## 已知限制

- **agent 停頓時放行**：負載很高時，agent 偶爾停頓。模組等不到回覆，就依預設的 fail-open 放行。XSS 負載測試中，部分回合有 1–318 個攻擊回 200，所有版本都有，與模組修正無關。要避免這種情況，請設成 fail-closed。
- **worker 註冊期間放行**：NGINX 啟動或 reload 後，worker 和 agent 註冊完成前的請求會依 fail-open 放行，約幾秒到 20 秒。
- **agent 剛重啟**：agent 重啟後約 60 秒內，body 攻擊會被放行。官方映像也一樣。
- **回應 body 相關修正**：已修，但這次用的 agent 和政策不檢查回應 body，所以沒辦法實機觸發。
- **NGINX 模組沒有跑 WCP 資料集**：NGINX 分支的防護測試只用端對端測試，WCP 資料集只在 Kong 組合上跑過。
- **學習期**：被測環境沒有經過 open-appsec 的學習期。結果代表固定門檻下的行為。
- **單一實體主機**：所有 VM 在同一台主機上，彼此會共用 CPU。測試時沒有同時跑其他負載。

## 編譯

編譯步驟和上游相同，見[上游 README](https://github.com/openappsec/attachment/blob/4c88f6389e301fd1958b0448f0e0ce01888a20c5/README.md)。NGINX 模組的補充說明：

- 新版 CMake 要加 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`。
- 要測 async 模式，需要把 `async/*.c` 加進 `ngx_module/CMakeLists.txt`，並定義 `NGINX_ASYNC_SUPPORTED`。上游的預設建置沒有編入 async 模式。
