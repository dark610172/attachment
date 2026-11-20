# open-appsec NGINX 模組修正與測試結果

## 一、重點

1. 原版 NGINX 模組把 body 緩衝的長度存成 16 位元。單一緩衝超過 64 KiB 時，agent 只收到被截斷的內容。
2. 這會同時造成漏擋和誤擋。`client_body_buffer_size` 設成 1m 時，600 KB JSON 尾端的 SQLi 會被放行。合法的 70 KB 到 300 MB JSON 上傳反而被擋。
3. 修正後，1m 和 8k 兩種緩衝大小，12 項攻擊與正常請求測試全部正確。1 MB、50 MB、300 MB 上傳的內容雜湊值都一致。
4. 另外修了 17 個原始碼審查找到的問題，包含記憶體錯誤、判定處理錯誤和 async 模式的檢查漏洞。
5. async 模式在預設 CMake 建置裡沒有編入。我們另外打開它建置並實測：上游版本在 async 模式下也會漏擋 body 攻擊，修正後暖機狀態全部擋下。
6. 效能和原版差不多，數字見第五節。

## 二、範圍與測試環境

| 項目 | 內容 |
|---|---|
| 程式碼 | openappsec/attachment，基底 4c88f63，分支 `fix/nginx-module` |
| 修改範圍 | `attachments/nginx/ngx_module/`（sync 路徑與 `async/`） |
| NGINX | 1.30.4（`ghcr.io/openappsec/nginx-attachment:1.1.36` 映像內的版本） |
| agent | `ghcr.io/openappsec/agent:1.1.36`，政策 prevent-learn |
| 建置 | 在同一個 Alpine 映像內編譯，自編原版與官方模組大小相差不到 200 bytes |
| 後端 | nginx 靜態檔與一個回傳 body 長度和 SHA-256 的小服務 |
| 效能測試 | 壓測工具 wrk 放在另一台主機，不和被測系統同機 |

## 三、修正清單

| Commit | 修正內容 | 對應問題 |
|---|---|---|
| 6ee536b | body 緩衝分成每段最多 32 KiB 送出，保留送出位置，不重送、不跳過 | 64 KiB 截斷 |
| 6ee536b | header、URI 等字串長度超過 65535 時截到上限並記警告，不再回繞 | 64 KiB 截斷 |
| 6ee536b | 等待後不再把已送出的緩衝當成下一個再送一次 | N14 |
| 6ee536b | 回應要求放在記憶體裡（`filter_need_in_memory`）；只存在檔案裡的緩衝視為檢查失敗，不當成空內容 | N09 |
| 6ee536b | `headers_out.content_type` 一起送給 agent；超出 header 清單的修改索引會被拒絕 | N10 |
| 57bdba9 | fail-open 路徑先還原原始壓縮緩衝，再釋放解壓縮用的記憶體 | N01 |
| 57bdba9 | 重新壓縮的輸出改放在請求自己的記憶體，不會被下一次呼叫重設 | N06 |
| 57bdba9 | `get_list_element()` 在清單分段邊界不再越界，找不到就回 NULL | N02 |
| 57bdba9 | 阻擋頁標題、內容、UUID 與轉址網址依目的緩衝大小限制長度 | N05 |
| 57bdba9 | 自訂回應存在獨立的記憶體區，送出時複製到該請求自己的記憶體 | N12 |
| 57bdba9 | 跨段的 body 注入排序後保留原本的接續位置 | N17 |
| a15d41e | body 只送出一部分時收到最終判定，立即結束檢查，後續錯誤不會把它改成放行 | 審查後補修 |
| a15d41e | gzip/brotli 片段解出 0 bytes 視為成功；檢查逾時後繼續解壓與重新壓縮到結束 | 審查後補修 |
| a15d41e | 重新壓縮的輸出緩衝用 `ngx_chain_update_chains` 重複使用 | 審查後補修 |
| fbecc65 | async：session 維持開始時的模式；sync 開始的請求，body 不會被 async filter 直接放行 | 新發現（A1） |
| fbecc65 | async：送出失敗時依設定的失敗策略處理，fail-closed 會擋下 | N11 |
| fbecc65 | async：body 分成每段最多 32 KiB 送出 | 64 KiB 截斷、N18 |
| fbecc65 | async：延遲的 header 判定出來後，有 body 就進入 body 階段 | N08 |
| fbecc65 | async：沒有 body 的請求在「繼續檢查」判定後，仍檢查回應 | N07 |
| fbecc65 | async：header INJECT 正確套用；CUSTOM_RESPONSE 用正確的回應函式；第二次 INJECT 不再存取空指標 | N15、N16、N03 |
| fbecc65 | async：沒有 header 的請求送出正確的空 header 訊息；HTTP/2 多加的參照計數只釋放一次 | N04、N13 |
| fbecc65 | async：最後一段 body 存好後，不再把空的呼叫往下傳（原本會讓暫存檔的 body 回 500） | 修正過程中發現 |
| 7b7a2bf | gzip/zlib 解壓縮輸出上限 256 MB（和 Brotli 相同）。從 Kong 版分支移植，NGINX 模組也連結這個共用函式庫 | Kong 版問題 |

## 四、實測結果

### 4.1 sync 模式（官方預設建置）

JSON POST，SQLi 放在 JSON 的開頭或結尾。「正常」是不含攻擊的同大小 JSON。

| 大小 | 內容 | 原版 1m | 修正版 1m | 原版 8k | 修正版 8k |
|---|---|---|---|---|---|
| 約 4 KB | 正常／開頭／結尾 | 200／403／403 | 200／403／403 | 200／403／403 | 200／403／403 |
| 約 70 KB | 正常／開頭／結尾 | **403**／403／403 | 200／403／403 | 200／403／403 | 200／403／403 |
| 約 140 KB | 正常／開頭／結尾 | 200／403／403 | 200／403／403 | 200／403／403 | 200／403／403 |
| 約 600 KB | 正常／開頭／結尾 | **403**／403／**200** | 200／403／403 | 200／403／403 | 200／403／403 |

粗體是錯誤結果。「1m」與「8k」是 `client_body_buffer_size`。

上傳完整性（後端收到的長度和 SHA-256 與送出的檔案比對）：

| 上傳 | 原版 1m | 修正版 1m | 原版 8k | 修正版 8k |
|---|---|---|---|---|
| 1／50／300 MB，Content-Length | 全部被擋 | 一致 | 一致 | 一致 |
| 1／50／300 MB，chunked | 一致 | 一致 | 一致 | 一致 |

gzip 回應、快取命中回應、Content-Type 回應都正常。整個測試過程 nginx 沒有當掉。

### 4.2 async 模式（另外打開 `NGINX_ASYNC_SUPPORTED` 建置）

打開方式：agent 的 `settings.json` 加 `agent.asyncMode.nginxModule=true`，nginx 加環境變數 `CP_ASYNC_MODE=true`。

| 情況 | 上游 async | 修正版 async |
|---|---|---|
| 8k，nginx 剛啟動，連續 16 個 body 攻擊 | 放行 8 個 | 放行 2 個（worker 註冊期間 fail-open，見 4.3） |
| 8k，暖機後，body 攻擊 | 4 KB 攻擊重複 10 次，放行 0 個 | 8 種大小與位置，放行 0 個 |
| 1m，暖機後，8 個 body 攻擊 | — | 放行 0 個 |
| 1／50／300 MB Content-Length 上傳（1m） | 全部被擋 | 一致 |
| 300 MB chunked 上傳（1m） | 失敗 | 一致 |
| 140 KB 以上正常 body（8k） | 正常 | 正常（修正過程中曾出現 500，已修） |

上游 async 漏擋的原因：worker 的第一個請求，header 走 sync 路徑，body 卻交給 async filter；async filter 判斷「模式不符」，就直接放行。

### 4.3 兩個和模組無關、但部署時要注意的行為

1. **worker 註冊期間 fail-open**：nginx 啟動或 reload 後，每個 worker 在和 agent 註冊完成前的請求，會依 fail-open 放行。官方映像也一樣（8 個 worker，16 個請求放行 8 個）。設成 fail-closed 會擋下。
2. **agent 重啟後約 1 分鐘**：agent 剛重啟時，body 攻擊會被放行，約 60 秒後恢復。官方映像也一樣。

### 4.4 Kong 版找到的問題，在 NGINX 版的檢查結果

Kong 版分支（`fix/kong-plugin-header-leak-and-chunked-bypass`）修了 9 個問題。下表是同樣的問題在 NGINX 模組的實測或程式碼檢查結果。原版與修正版結果相同的，表示 NGINX 版本來就沒有這個問題。

| Kong 版問題 | NGINX 版結果 | 檢查方式 |
|---|---|---|
| chunked body 不檢查 | 沒有這個問題。原版與修正版的 chunked SQLi 都回 403，正常 chunked 回 200 | 實測 |
| 每個 header 漏記憶體 | 沒有這個問題。每個請求多 8 個 header，跑約 116 萬個請求，worker 記憶體維持在 55 MB 上下（變動小於 0.2 MB） | 實測 3 分鐘 |
| header 數量超過 1000 時越界讀取 | 沒有這個問題。nginx 1.30 本身會拒絕超過約 1000 個 header 的請求（回 400），模組收不到。990 個 header 加攻擊仍回 403，之後的請求也正常。模組依 nginx 的清單逐一處理 header，沒有固定 1000 格的陣列 | 實測與程式碼檢查 |
| 沒有 session 的回應讓 header 階段出錯 | 沒有這個問題。nginx 自己回的 400、414、505（亂碼請求、20 KB 網址、錯誤 Host、錯誤 HTTP 版本）都正常，之後的請求與攻擊判定都正常，沒有當掉 | 實測 |
| async 沒有 body 的請求多送一次結束訊息 | 沒有這個問題。結束訊息只在一個地方送出，並用旗標防止重送。暖機後，原版與修正版 async 的 GET 都約 3 ms | 實測與程式碼檢查 |
| gzip 解壓縮沒有上限 | **有這個問題**。NGINX 模組連結同一個共用解壓縮函式庫。已移植修正（7b7a2bf） | 程式碼檢查。這個 agent 不檢查回應 body，所以實機觸發不到 |
| debug log 格式字串多一個逗號 | 不適用。這是 Kong 用的 `nano_attachment` 程式碼，NGINX 模組有自己的設定讀取 | 程式碼檢查 |
| 每個請求做完整 GC、外掛優先順序 | 不適用。只存在於 Kong 的 Lua 外掛 | — |

## 五、效能

（見下表，壓測工具與被測系統在不同主機。每個情境先暖機並丟掉結果，原版與修正版輪替跑 3 次。）

設定：sync 模式，`client_body_buffer_size 8k`，wrk 4 執行緒、16 連線，每項 30 秒。nginx 到後端用 keepalive 連線池。所有回應都是 2xx。

| 情境 | 原版（3 次） | 修正版（3 次） | 中位數差異 |
|---|---|---|---|
| GET 小回應，req/s | 7,508／7,595／7,537 | 7,524／6,522／7,501 | -0.5% |
| GET 小回應，第 99 百分位延遲 | 4.70／4.34／4.34 ms | 4.49／295.68／4.69 ms | — |
| POST 50 KB JSON，req/s | 339.5／338.7／337.6 | 335.0／337.7／336.9 | -0.5% |
| POST 50 KB JSON，第 99 百分位延遲 | 95.8／143.6／93.7 ms | 91.9／87.4／93.3 ms | — |

修正版第 2 次的 GET 有一次延遲尖峰（295 ms），另外兩次都正常，原版也有一次 POST 尖峰（143 ms）。兩者的差異在測量誤差範圍內。

第一次量測沒有設後端 keepalive，約一半請求因後端連線用盡回 502。那次的數字作廢。

## 六、沒有修或沒辦法實測的項目

| 項目 | 狀態 |
|---|---|
| N01、N06、N09、N10（回應 body 相關） | 已修，但這個 agent 和政策會在回應標頭階段就放行，不會檢查回應 body，所以實機觸發不到 |
| 重新壓縮輸出沒有上限 | 審查指出：`proxy_buffering off` 加上慢速客戶端時，記憶體會隨回應大小成長。沒有修，原因同上，實機觸發不到 |
| N18（索引 8 位元回繞）、N19（subrequest 與 trailer）、N20（session ID 重複） | 屬於疑點，需要 agent 端的行為才能判斷，沒有修 |
| async 的 N07、N13、N15、N16 | 已修，但需要 agent 回傳特定判定才能觸發，只做了程式碼檢查與編譯 |
| agent 的誤判 | agent 會把 1 MB 以上的隨機二進位、重複單字的大 body、路徑 `/echo` 判成攻擊。這是 agent 的判斷，和模組無關 |

## 七、建置方式

```bash
nginx -V > /tmp/nginx.ver 2>&1
./attachments/nginx/ngx_module/nginx_version_configuration.sh --conf /tmp/nginx.ver build_out
cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_INSTALL_PREFIX=build_out .
make install
```

新版 CMake 需要 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`。要測 async 模式，需要把 `async/*.c` 加進 `ngx_module/CMakeLists.txt`，並定義 `NGINX_ASYNC_SUPPORTED`。
