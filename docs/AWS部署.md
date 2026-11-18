# 櫃台通話部署到 AWS

App 專案：`D:\KioskTalkInteractFlutter`。登入沿用掌櫃帳號，打的是畫面編輯器那組測試 API。只部署測試。沒有執行 `D:\KioskUIManageWeb\scripts\create-pro.mjs`，正式 Lambda、正式 API、正式庫都沒有改。

API 程式在 `D:\KioskUIManageWeb\api-hotels`（`index.mjs`、`talk.mjs`）。重跑測試部署用：

```powershell
cd D:\KioskUIManageWeb
node scripts/deploy-talk-dev.mjs
```

## 進度

- [x] 測試通話資源（2026-11-17）：表、外網函式、七條路由、IoT 規則
- [ ] 響鈴。Android 的 `google-services.json` 與 FCM 服務帳戶已接上測試邊緣函式。iOS 還沒有 VoIP 用的 APNs p8
- [ ] 正式環境。這次沒有做

## 這次建立的資源

區域 `ap-southeast-1`，帳號 `237842938571`。`kiosk_ui_hotels_dev` 仍在 `vpc-47f3ff22`，沒有 NAT。登入和 DynamoDB 留在這支。對外的 IoT 發布、短期 KVS 憑證、推播改由不進 VPC 的 `kiosk_talk_edge_dev` 做，掌櫃函式透過既有 Lambda 端點呼叫它。

| 資源 | 值 |
|---|---|
| 通話表 | `kiosk_talk_dev`（On-demand，分割區鍵 `pk`、排序鍵 `sk`，TTL 欄位 `expireAt`） |
| 掌櫃函式 | `kiosk_ui_hotels_dev`，逾時 60 秒、記憶體 512。新增環境變數鍵 `TALK_TABLE`、`TALK_EDGE_FUNCTION`。原本的 `ADMIN_ACCOUNT`、`ADMIN_PASSWORD`、`SESSION_SECRET` 保留，沒有改值 |
| 外網函式 | `kiosk_talk_edge_dev`，handler `index.edge`，不進 VPC，逾時 60 秒、記憶體 512。環境變數鍵 `IOT_DATA_ENDPOINT`、`KVS_VIEWER_ROLE_ARN`、`FCM_PROJECT_ID`、`FCM_CLIENT_EMAIL`、`FCM_PRIVATE_KEY` |
| IoT 資料端點 | `https://a2iqu2bwi7cwif-ats.iot.ap-southeast-1.amazonaws.com` |
| 邊緣角色 | `kiosk_talk_edge_dev`（可發布 `sonas/kiosk/*`、描述 KVS channel、擔任下面的 Viewer 角色） |
| Viewer 角色 | `kiosk_talk_viewer_dev`（只允許被邊緣角色擔任，權限是該次通話的 channel） |
| IoT 規則 | `kiosk_talk_kvs_dev`，SQL `SELECT *, topic() as mqttTopic FROM 'sonas/kiosk/+/kvs/recv'`，動作是呼叫 `kiosk_ui_hotels_dev` |
| 測試網址 | https://m3di5g4s9b.execute-api.ap-southeast-1.amazonaws.com |

通話路由都接到既有整合 `integrations/n4bi1mq`：

- `POST /talk-login`：掌櫃仍走 `AG03 = 2`。員工要 `AG03 = 5`，用 `staffaccount.UP01` 對到帳號，`SA003 = 0`，旅店看 `staffaccounthotel`，權限走普通版 `staffaccountauth` 對 `systemmodule`，`SM03` 要等於 `KIOSK|KIOSK_TALK`。畫面編輯的 `POST /login` 仍只收掌櫃。
- `POST /devices`、`DELETE /devices`
- `POST /hotels/{hotelId}/machine-links`：機台有沒有連上，跟畫面編輯器同一套判斷
- `POST /hotels/{hotelId}/machines/{machineCode}/calls`
- `GET /calls`：這支帳號看得到的旅店通話，含網頁接聽、接聽者與通話秒數，保留 7 天。這次改版之前的舊紀錄不會出現
- `POST /calls/{merchantNo}/answer`
- `POST /calls/{merchantNo}/reject`
- `POST /calls/{merchantNo}/hangup`
- `POST /calls/{merchantNo}/session`

Lambda 另外允許 API Gateway 打這四條來源：`*/talk-login`、`*/devices`、`*/calls/*/*`、`*/hotels/*/machines/*/calls`。IoT 規則的呼叫許可是 `iot-kiosk-talk`。

部署後抽查：空的登入回 401「帳號或密碼不對」；邊緣函式收到不認得的工作回 400「工作不對」；上面三條未帶憑證的路由都回 401「請先登入」。

還沒接上、所以還不會響鈴：

- Android 的 `google-services.json` 已放在 `android/app/`，套件名稱 `com.sonas.kiosktalk.kiosk_talk`，Firebase 專案 `kiosk-talk-interact-flutter`。
- FCM 服務帳戶已設進 `kiosk_talk_edge_dev`。私密金鑰留在 Lambda，不寫進這個檔案。本機那份 `*-firebase-adminsdk-*.json` 已列入 `.gitignore`。
- iOS 還沒放 VoIP 用的 APNs p8，iPhone 還不會響。

KVS、IoT、管理者密碼和 session secret 都不寫進這個檔案。
