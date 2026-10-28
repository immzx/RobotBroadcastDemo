/**
 * 局域网传输适配层（Demo 模拟实现）。
 * 当前没有真实扫地机的 IP、端口、鉴权方式及音频上传协议，因此不会伪造真实设备回执。
 * 确认设备协议后，在 sendAudio() 中替换为 HTTP / WebSocket / 厂商 SDK 上传实现即可。
 */
export class LanTransferService {
  async sendText(phrase: string, isDeviceOnline: boolean): Promise<void> {
    if (!phrase || !isDeviceOnline) { throw new Error('DEVICE_OFFLINE_OR_EMPTY_TEXT'); }
    // Demo only: substitute device-protocol text broadcast request here.
    await new Promise<void>((resolve: () => void) => { setTimeout(() => resolve(), 350); });
  }

  async sendAudio(filePath: string, isDeviceOnline: boolean, onProgress: (progress: number) => void): Promise<void> {
    if (!filePath) {
      throw new Error('AUDIO_FILE_MISSING');
    }
    if (!isDeviceOnline) {
      throw new Error('DEVICE_OFFLINE');
    }

    // 模拟局域网分片传输进度，方便评审发送中、失败与重试状态。
    for (let progress: number = 0; progress <= 100; progress += 10) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => resolve(), 180);
      });
      onProgress(progress);
    }
  }
}
