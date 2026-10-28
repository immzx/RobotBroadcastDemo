# 扫地机「远程广播找人」Demo（HarmonyOS NEXT / API 12）

本仓库包含可导入 DevEco Studio 的 HarmonyOS Stage 工程源码，面向 UX 评审和设备协议联调前的交互演示。

## 功能

- 扫地机首页与「远程广播」入口。
- 两种广播方式：固定文本话术、录音广播。
- 固定话术：回来吃饭啦、过来帮个忙、找到你了请回应一下、快来客厅一下。
- 语音录制：按住开始、松开结束，最长 30 秒。
- 录音试听、暂停、重录及发送。
- 广播任务状态连续展示：连接状态、任务接收、设备播报、等待响应、已找到。
- 发送失败提示及结束任务返回首页。
- 保留 API 12 工程配置和 `signingConfig: default`。

## 导入工程

1. 克隆仓库或下载 ZIP。
2. 在 DevEco Studio 中打开仓库根目录。
3. 等待 Sync 完成，选择 `entry` 模块和 `default` Target。
4. 运行到 HarmonyOS NEXT 模拟器或真机。
5. 录音广播首次使用时，允许麦克风权限。

## 关键代码

- `entry/src/main/ets/pages/Index.ets`：首页、双通道入口、录音/试听和状态追踪 UI。
- `entry/src/main/ets/services/AudioRecorderService.ets`：系统录音与本地试听资源管理。
- `entry/src/main/ets/services/LanTransferService.ets`：局域网发送适配层。
- `entry/src/main/ets/services/BroadcastStatusService.ets`：广播任务状态事件与演示状态机。
- `entry/src/main/module.json5`：麦克风与网络权限声明。

## 重要边界

当前 `LanTransferService` 和 `BroadcastStatusService.startDemo()` 使用模拟实现，**尚未连接真实扫地机，也没有通过真实 WebSocket 判断找到人员**。正式接入需要设备 IP/端口、鉴权方式、文本与音频上传协议、WebSocket 消息格式、任务 ID、状态序号/时间戳和 FOUND 事件定义。真实状态应以设备回执为准，不能用本地计时冒充已找到。

系统录音当前输出 AAC 编码的 M4A 文件，而不是 MP3。如果设备端仅支持 MP3，需要额外转码或确认固件支持 AAC/M4A。

## Git 工作流

- 当前实现分支：`feat/dual-broadcast-v2`
- 建议先在该分支验证 ArkTS 编译与真机交互，再合并到 `main`。
