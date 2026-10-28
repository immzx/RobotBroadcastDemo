# 扫地机「远程广播找人」Demo（HarmonyOS NEXT / API 12）

本仓库是 HarmonyOS NEXT / ArkTS 客户端 Demo，支持连接独立的 Broadcast Server Assistant 调试服务，在同一 Wi-Fi / 手机热点下验证音频上传和持续状态推送。

## 功能

- 扫地机首页与「远程广播」入口。
- 两种广播方式：固定文本话术、录音广播。
- 固定话术：回来吃饭啦、过来帮个忙、找到你了请回应一下、快来客厅一下。
- 语音录制：按住开始、松开结束，最长 30 秒。
- 录音试听、暂停、重录。
- 配置 WebSocket 服务地址，默认示例 `ws://192.168.1.20:8765`；可连接/断开。
- 通过 WebSocket 长连接接收服务端 `broadcast_progress` 状态推送，不再用客户端本地定时器伪造任务结果。
- 音频通过同一 WebSocket 上传：`audio_start` → 等待 `audio_ready` → 二进制 `ArrayBuffer` 分片 → `audio_end` → 等待 `audio_saved` → `start_broadcast`。
- 找到目标后显示成功状态；用户点击完成后发送 `client_done`、`client_close` 并主动关闭连接。
- 支持模拟进度 / 真实进度模式选择和 WebSocket 心跳 `ping/pong`。

## 导入运行

1. 在 DevEco Studio 中打开仓库根目录。
2. 等待 Sync 完成，选择 `entry` 模块和 `default` Target。
3. 先在服务端手机运行 Broadcast Server Assistant，点击「启动服务」，确认端口 `8765` 正在监听。
4. 两台手机连接同一 Wi-Fi / 热点，在服务端查看局域网 IP。
5. 在本客户端广播页面填入 `ws://<服务端IP>:8765` 并点击「连接服务」。
6. 选择「模拟进度」以验证服务端每秒推送的状态；选择「真实进度」时，服务端不会伪造找人进度，需要真实设备/业务进度生产者向服务端发送 `broadcast_progress`。
7. 录音广播首次使用时，允许麦克风权限。

## 关键代码

- `entry/src/main/ets/pages/Index.ets`：首页、双通道入口、录音/试听、连接配置与服务端状态 UI。
- `entry/src/main/ets/services/BroadcastClientService.ets`：WebSocket 客户端、心跳、文本指令、音频二进制分片上传、回执等待、终态主动关闭。
- `entry/src/main/ets/services/AudioRecorderService.ets`：系统录音与本地试听资源管理。
- `entry/src/main/ets/services/LanTransferService.ets`：旧版模拟适配层，客户端实际发送流程已改用 `BroadcastClientService`。
- `entry/src/main/ets/services/BroadcastStatusService.ets`：旧版本地状态模拟器，当前页面不再依赖它驱动进度。

## 服务端协议

服务端返回：

```json
{
  "type": "broadcast_progress",
  "taskId": "task_...",
  "mode": "mock",
  "status": "searching",
  "stage": "discovering_device",
  "progress": 45,
  "message": "正在寻找目标设备",
  "timestamp": 1793156400000
}
```

音频上传元信息：

```json
{"type":"audio_start","uploadId":"upload_...","fileName":"broadcast.m4a","mimeType":"audio/mp4","size":12345}
```

上传结束：

```json
{"type":"audio_end","uploadId":"upload_..."}
```

任务控制消息：

```json
{"type":"start_broadcast","mode":"mock","commandText":"回来吃饭啦","source":"text"}
{"type":"client_done","taskId":"task_..."}
{"type":"client_close","reason":"task_completed"}
```

## 重要边界

- 当前客户端已按服务端的 WebSocket 消息协议实现连接、文件分片传输、回执与状态接收。
- 服务端的 `mock` 模式用于联调链路，不代表真实扫地机已执行广播或真实检测到人员。真实进度需设备侧/业务侧生成 `broadcast_progress`。
- `real` 模式下服务端等待外部真实进度消息；如果没有真实进度生产者，任务不会自行进入 found。
- 系统录音当前输出 AAC 编码的 M4A 文件，不是 MP3。如果设备端只接受 MP3，需要补充转码或确认设备兼容 M4A。
- 文本指令通过 `start_broadcast.commandText` 传输。服务端若要记录/转发该文本，需要采用支持该字段的服务端版本；目前原版服务端只启动任务，未将文本直接发送给真实扫地机。
- 局域网调试服务不要直接暴露到公网；生产环境应增加鉴权、上传大小限制、并发隔离和可靠的状态序号/时间戳校验。

## 当前开发分支

`feat/server-client-connection`
