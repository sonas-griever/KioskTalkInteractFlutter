# 櫃台通話部署到 AWS

App 專案：`D:\KioskTalkInteractFlutter`。登入沿用掌櫃帳號，打的是畫面編輯器那組測試 API。只部署測試。沒有執行 `D:\KioskUIManageWeb\scripts\create-pro.mjs`，正式 Lambda、正式 API、正式庫都沒有改。

App 預設網址在 `lib/config.dart` 的 `API_BASE`，目前是下面的測試網址。套件名稱 `com.sonas.kiosktalk.kiosk_talk`，畫面名稱「櫃台通話」。

通話 API 程式在 `D:\KioskUIManageWeb\api-hotels`（`index.mjs`、`talk.mjs`）。重跑測試部署用：

```powershell
cd D:\KioskUIManageWeb
node scripts/deploy-talk-dev.mjs
```

這支腳本會更新通話表、兩支 Lambda、IAM、IoT 規則，以及還沒有的通話路由。它不會建立 `POST /hotels/{hotelId}/machine-links`，也不會改 `kiosk_ui_api_dev`。機台有沒有通話頻道是畫面編輯器那支函式在回，要另外打包 `D:\KioskUIManageWeb\api`（含 `node_modules`）更新 `kiosk_ui_api_dev`。

## 進度

- [x] 測試通話資源（2026-11-17）：表、外網函式、通話路由、IoT 規則
- [x] 通話紀錄：跟進行中的通話同一張表，見「通話紀錄」
- [x] 機台清單只列已建立通話頻道的機台。判斷在 `kiosk_ui_api_dev`，不是掌櫃函式
- [x] Android 響鈴。`google-services.json` 與 FCM 服務帳戶已接上測試邊緣函式
- [ ] iOS 響鈴。還沒有 VoIP 用的 APNs p8，邊緣函式也還沒有 `APNS_*`
- [ ] 正式環境。這次沒有做
- [ ] 員工權限那列 `systemmodule`。部署腳本不會插入。`SM03` 要已有一列等於 `KIOSK|KIOSK_TALK`，員工才登得進。掌櫃 `AG03 = 2` 不靠這列

## 這次建立的資源

區域 `ap-southeast-1`，帳號 `237842938571`。`kiosk_ui_hotels_dev` 仍在 `vpc-47f3ff22`，沒有 NAT。登入、查機台、DynamoDB 留在這支。對外的 IoT 發布、短期 KVS 憑證、推播改由不進 VPC 的 `kiosk_talk_edge_dev` 做。掌櫃函式透過既有 Lambda 端點呼叫它。兩支函式吃同一包 `api-hotels` 壓縮檔。機台有沒有通話頻道由同樣不進 VPC 的 `kiosk_ui_api_dev` 判斷。

| 資源 | 值 |
|---|---|
| 通話表 | `kiosk_talk_dev`（On-demand，分割區鍵 `pk`、排序鍵 `sk`，TTL 欄位 `expireAt`） |
| 掌櫃函式 | `kiosk_ui_hotels_dev`，逾時 60 秒、記憶體 512。新增環境變數鍵 `TALK_TABLE`、`TALK_EDGE_FUNCTION`。原本的 `ADMIN_ACCOUNT`、`ADMIN_PASSWORD`、`SESSION_SECRET` 保留，沒有改值 |
| 外網函式 | `kiosk_talk_edge_dev`，handler `index.edge`，不進 VPC，逾時 60 秒、記憶體 512。環境變數鍵 `IOT_DATA_ENDPOINT`、`KVS_VIEWER_ROLE_ARN`、`FCM_PROJECT_ID`、`FCM_CLIENT_EMAIL`、`FCM_PRIVATE_KEY`。iOS 用的 `APNS_KEY_ID`、`APNS_TEAM_ID`、`APNS_BUNDLE_ID`、`APNS_PRIVATE_KEY`、`APNS_PRODUCTION` 都還沒設 |
| IoT 資料端點 | `https://a2iqu2bwi7cwif-ats.iot.ap-southeast-1.amazonaws.com` |
| 邊緣角色 | `kiosk_talk_edge_dev`。信任政策 `scripts/lambda-trust.json`。內嵌政策 `scripts/talk-edge-policy.json`：可發布 `sonas/kiosk/*`、看 IoT 連線、描述與列出 KVS channel、擔任下面的 Viewer 角色 |
| Viewer 角色 | `kiosk_talk_viewer_dev`。信任政策 `scripts/talk-viewer-trust.json`，只允許邊緣角色擔任。角色政策 `scripts/talk-viewer-policy.json` 是 Viewer 用的三個 KVS 動作。每次通話再縮成下面「短期憑證」 |
| 掌櫃角色 | 每次通話部署會用 `scripts/hotels-dev-policy.json` 覆寫內嵌政策 `kiosk_ui_hotels_dev`：讀既有掌櫃資料庫參數、讀寫 `kiosk_talk_dev`、呼叫 `kiosk_talk_edge_dev` |
| 畫面編輯函式 | `kiosk_ui_api_dev`，不進 VPC。`POST /hotels/{hotelId}/machine-links` 仍打這支。內嵌政策與 `scripts/api-dev-policy.json` 都有 `kinesisvideo:ListSignalingChannels`（資源 `*`） |
| IoT 規則 | `kiosk_talk_kvs_dev`，SQL `SELECT *, topic() as mqttTopic FROM 'sonas/kiosk/+/kvs/recv'`，動作是呼叫 `kiosk_ui_hotels_dev` |
| 測試網址 | https://m3di5g4s9b.execute-api.ap-southeast-1.amazonaws.com |

`deploy-talk-dev.mjs` 會接到既有整合 `integrations/n4bi1mq`（`kiosk_ui_hotels_dev`）的路由：

- `POST /talk-login`：掌櫃仍走 `AG03 = 2`。員工要 `AG03 = 5`，用 `staffaccount.UP01` 對到帳號，`SA003 = 0`，旅店看 `staffaccounthotel`，權限走普通版 `staffaccountauth` 對 `systemmodule`，`SM03` 要等於 `KIOSK|KIOSK_TALK`。這一列要在資料庫自己建，部署腳本不會插入。畫面編輯的 `POST /login` 另外收員工：同一套 `AG03 = 5`，但 `SM03` 要等於 `KIOSK|KIOSK_UI_EDIT`，登入票仍是畫面編輯那張 12 小時的。通話登入票有效 30 天。
- `POST /talk-refresh`：用還沒過期的通話登入票換一張新的，並重查旅店。App 開啟時、回到前景時，以及每 6 小時會打一次，所以登入後到按登出前都收得到機台來電。登出才刪掉這支手機的推播登記。許可名稱 `apigw-kiosk-talk-refresh`。
- `POST /devices`、`DELETE /devices`：登記與拿掉這支手機的推播 token。見「推播」
- `POST /hotels/{hotelId}/machines/{machineCode}/calls`：App 撥給機台
- `GET /calls`：這支帳號看得到的旅店通話紀錄。見「通話紀錄」
- `POST /calls/{merchantNo}/answer`
- `POST /calls/{merchantNo}/reject`
- `POST /calls/{merchantNo}/hangup`
- `POST /calls/{merchantNo}/session`：通話中再取一次短期 Viewer 憑證

`POST /hotels/{hotelId}/machine-links` 不在上面這份清單。線上這條打的是畫面編輯器的 `kiosk_ui_api_dev`，因為編輯器也用它看機台有沒有連上。見「機台清單」。

`kiosk_ui_hotels_dev` 的呼叫許可：

| 許可名稱 | 來源 |
|---|---|
| `iot-kiosk-talk` | IoT 規則 `kiosk_talk_kvs_dev` |
| `apigw-kiosk-talk-login` | `*/talk-login` |
| `apigw-kiosk-talk-refresh` | `*/talk-refresh` |
| `apigw-kiosk-talk-devices` | `*/devices` |
| `apigw-kiosk-talk-history` | `*/calls` |
| `apigw-kiosk-talk-calls` | `*/calls/*/*` |
| `apigw-kiosk-talk-dial` | `*/hotels/*/machines/*/calls` |
| `apigw-kiosk-talk-links` | `*/hotels/*/machine-links`。許可留在掌櫃函式上，線上路由沒有打過來。不要把這條路由改接到 `kiosk_ui_hotels_dev`：那支會拒絕管理員，而且一次最多 30 台，畫面編輯器要 200 台 |

部署後抽查：空的登入回 401「帳號或密碼不對」；邊緣函式收到不認得的工作回 400「工作不對」；未帶憑證的通話路由回 401「請先登入」。

## 通話怎麼走

機台永遠是自己機碼那條 KVS channel 的 Master。App 永遠是 Viewer。頻道名稱就是機台機碼。區域 `ap-southeast-1`。

- App 撥出：`POST .../calls` 把 `KVS_CALL_REQUEST` 發到 `sonas/kiosk/{機台機碼}/kvs/recv`。機台只處理發給自己機碼的請求。
- 機台撥入：機台把 `KVS_CALL_REQUEST` 發到 `sonas/kiosk/{旅店編號}/kvs/recv`。IoT 規則收到後寫進通話表，並推播給該旅店已登記的手機。`callerId` 以 `staff-` 開頭的請求會略過，避免 App 自己的撥出被再記成一通來電。
- App 接聽：`KVS_CALL_ANSWER`（`accepted` 為 true）發到 `sonas/kiosk/{旅店編號}/kvs/recv`，其他手機會收到關掉響鈴的推播。網頁若還在響，要自己聽這則 MQTT 並停鈴。
- 拒接是 `KVS_CALL_REJECT`，掛斷或取消是 `KVS_CALL_CANCEL`，同樣發到旅店那個 topic。

邊緣函式認得的工作：`publish`（發 MQTT）、`viewer`（短期憑證）、`push`（FCM 或 APNs）、`links`（連線與頻道）。掌櫃函式有設 `TALK_EDGE_FUNCTION` 時，這四件都轉去邊緣函式。

## 短期憑證

`POST .../answer` 與 `POST .../session` 由邊緣函式 `AssumeRole` 擔任 `kiosk_talk_viewer_dev`，900 秒。這次的 session 政策只允許該機台那一條 channel 做 `GetSignalingChannelEndpoint`、`GetIceServerConfig`、`ConnectAsViewer`。憑證只在那次回應裡交給 App，不寫進這個檔案，也不進 App 安裝包。通話中每 10 分鐘再打一次 `POST .../session`，只更新憑證。連線還在時不拆開重接。斷線或換網路才用新憑證重新接上同一通。通話中 Android 會開前景服務，避免系統把這通清掉。

## 推播

裝置放在同一張 `kiosk_talk_dev`，沒有 TTL。

- `pk` 為 `DEV#{token 的雜湊}`、`sk` 為 `META`：這支手機的 token、平台（`android` 或 `ios`）、帳號。
- `pk` 為 `HOTEL#{旅店編號}`、`sk` 為 `DEV#{同一個雜湊}`：用來找出這間旅店要推給哪些手機。

推播內容是資料訊息，不是通知文案。`incoming` 是來電。`dismiss` 的 `reason` 為 `answered` 或 `ended`，用來停鈴。App 自己撥出時，對方接聽是 `answered`，拒接是 `rejected`。接聽的那支手機會被排除，不會把自己的通話關掉。FCM 回報 token 已失效時，刪掉 `DEV#` 與各旅店那一列，卸載或重灌後不會再推給那支手機。

Android 的 `google-services.json` 在 `android/app/`，Firebase 專案 `kiosk-talk-interact-flutter`。FCM 服務帳戶已設進 `kiosk_talk_edge_dev`。私密金鑰留在 Lambda，不寫進這個檔案。本機那份 `*-firebase-adminsdk-*.json` 已列入 `.gitignore`。

iOS 還沒放 VoIP 用的 APNs p8。上面那五個 `APNS_*` 沒設時，邊緣函式不會送 iPhone 推播。

## 通話紀錄

沒有另外建表，跟進行中的通話一起放在 `kiosk_talk_dev`。

進行中的那筆：`pk` 是 `CALL#{merchantNo}`、`sk` 是 `META`，`expireAt` 是寫入後 7 天。只給接聽、掛斷、取短期憑證用。App 的來電紀錄不讀這筆。

紀錄那筆：`pk` 是 `HOTEL#{旅店編號}`、`sk` 是 `LOG#{建立時間補滿 13 碼}#{merchantNo}`。撥出、機台撥入、接聽、拒接、掛斷都會覆寫同一筆。欄位有 `direction`（`out` 是 App 撥出，`in` 是機台撥入）、`status`（`ringing`、`answered`、`rejected`、`cancelled`）、`callerName`、`answeredName`、`endedName`、`duration`（有接通才有秒數）、`createdAt`。每次寫入把 `expireAt` 設成現在起 30 天，到期由這張表的 TTL 刪掉。已經寫入的舊紀錄仍照當初的到期時間。

`GET /calls` 對這支帳號的每間旅店由新到舊取 40 筆再合併。還有更早的紀錄時回應帶 `more`，下一頁用 `before` 帶目前最舊一筆的 `createdAt`。管理員帳號不能查。改版前只有 `CALL#`、沒有 `LOG#` 的舊通話不會出現在清單。

## 機台清單

App 打 `POST /hotels/{hotelId}/machine-links`，一次最多 30 個機碼。線上這條在 `kiosk_ui_api_dev`，回 `{ links, channels }`。

- `links`：`on` 或 `off`，看該機台 `sonas/kiosk/{機碼}/recv` 有沒有在線。編輯器只讀這個欄位。
- `channels`：該機碼是不是一條 KVS signaling channel 的名稱。頻道是機台真正開過通話才會有，不是只把通話按鈕打開。用 `ListSignalingChannels` 整批對，一次最多 500 筆、最多 20 頁。不要改成一台一台 `DescribeSignalingChannel`，權限不夠時會變成 AccessDenied，分不出「沒有頻道」。

App 只列出 `channels` 為 true 的機台。`links` 是 `on` 才能撥，`off` 仍列出但顯示未連線。編輯器的 `GET /hotels/{id}/machines` 不篩頻道，機台清單維持原樣。

`api/package.json` 有 `@aws-sdk/client-kinesis-video`。更新 `kiosk_ui_api_dev` 時壓縮檔要帶上當時的 `node_modules`。

KVS、IoT、FCM、APNs、管理者密碼和 session secret 都不寫進這個檔案。
