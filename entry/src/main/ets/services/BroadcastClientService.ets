import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import fs from '@ohos.file.fs';

export interface ServerMessage {
  type: string;
  protocolVersion?: number;
  taskId?: string;
  mode?: string;
  status?: string;
  stage?: string;
  progress?: number;
  message?: string;
  timestamp?: number;
  uploadId?: string;
  fileName?: string;
  mimeType?: string;
  size?: number;
  expectedSize?: number;
  path?: string;
  reason?: string;
}

export interface ClientConnectionState {
  connected: boolean;
  message: string;
}

/**
 * All client-to-server JSON messages use this explicitly declared interface.
 * This also keeps ArkTS strict object-literal checking enabled.
 */
interface ClientRequestMessage {
  type: string;
  protocolVersion?: number;
  taskId?: string;
  mode?: string;
  commandText?: string;
  source?: string;
  timestamp?: number;
  uploadId?: string;
  fileName?: string;
  mimeType?: string;
  size?: number;
  reason?: string;
}

interface MessageWaiter {
  type: string;
  uploadId: string;
  resolve: (message: ServerMessage) => void;
  reject: (error: Error) => void;
  timer: number;
}

/**
 * Broadcast Server Assistant 的 WebSocket 客户端。
 *
 * 协议：
 * - ws://<server-ip>:8765
 * - 音频：audio_start -> audio_ready -> ArrayBuffer chunks -> audio_end -> audio_saved
 * - 任务：start_broadcast -> broadcast_progress (server push)
 * - 结束：client_done / client_close -> WebSocket close
 *
 * 服务端按既有协议每秒推送状态；客户端不需要额外轮询。
 */
export class BroadcastClientService {
  private socket: webSocket.WebSocket | undefined = undefined;
  private connected: boolean = false;
  private stateCallback: ((state: ClientConnectionState) => void) | undefined = undefined;
  private messageCallback: ((message: ServerMessage) => void) | undefined = undefined;
  private waiters: MessageWaiter[] = [];
  private keepAliveTimer: number = -1;
  private uploadBusy: boolean = false;

  isConnected(): boolean {
    return this.connected;
  }

  async connect(
    url: string,
    onMessage: (message: ServerMessage) => void,
    onState: (state: ClientConnectionState) => void
  ): Promise<void> {
    if (this.connected && this.socket !== undefined) {
      return;
    }
    const normalizedUrl: string = url.trim();
    if (!normalizedUrl.startsWith('ws://') && !normalizedUrl.startsWith('wss://')) {
      throw new Error('连接地址必须以 ws:// 或 wss:// 开头');
    }
    this.stateCallback = onState;
    this.messageCallback = onMessage;
    const client: webSocket.WebSocket = webSocket.createWebSocket();
    this.socket = client;

    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void) => {
      let settled: boolean = false;
      client.on('open', (err: BusinessError, _value: Object) => {
        if (err) {
          if (!settled) {
            settled = true;
            reject(new Error('WebSocket 打开失败：' + err.message));
          }
          return;
        }
        this.connected = true;
        this.notifyState('已连接 Broadcast Server');
        this.startKeepAlive();
        if (!settled) {
          settled = true;
          resolve();
        }
      });

      client.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
        if (err) {
          this.notifyState('接收服务端消息失败：' + err.message);
          return;
        }
        if (typeof value !== 'string') {
          // 服务端当前仅推送 JSON 文本；二进制帧用于服务端接收音频。
          return;
        }
        this.handleTextMessage(value);
      });

      client.on('close', (err: BusinessError, result: webSocket.CloseResult) => {
        this.connected = false;
        this.stopKeepAlive();
        const reason: string = result?.reason ?? (err ? err.message : '连接已关闭');
        this.notifyState('连接已断开：' + reason);
        this.rejectWaiters('WebSocket 已断开');
      });

      client.on('error', (err: BusinessError) => {
        this.notifyState('WebSocket 错误：' + err.message);
        if (!settled) {
          settled = true;
          reject(new Error(err.message));
        }
      });

      client.connect(normalizedUrl, (err: BusinessError, accepted: boolean) => {
        if ((err || !accepted) && !settled) {
          settled = true;
          reject(new Error(err ? err.message : 'WebSocket 连接请求未被接受'));
        }
      });
    });
  }

  private handleTextMessage(raw: string): void {
    let message: ServerMessage;
    try {
      message = JSON.parse(raw) as ServerMessage;
    } catch (_) {
      this.notifyState('收到无法解析的服务端消息');
      return;
    }

    this.resolveWaiters(message);
    if (message.type === 'server_hello') {
      this.notifyState('服务端握手成功，协议版本 ' + (message.protocolVersion ?? 1).toString());
    } else if (message.type === 'pong') {
      // Keep-alive response; no UI update needed.
    } else if (message.type === 'audio_error') {
      this.notifyState('服务端拒绝音频上传：' + (message.message ?? '未知错误'));
    }
    this.messageCallback?.(message);
  }

  private notifyState(message: string): void {
    this.stateCallback?.({ connected: this.connected, message: message });
  }

  private async sendJson(payload: ClientRequestMessage): Promise<void> {
    if (!this.socket || !this.connected) {
      throw new Error('尚未连接 Broadcast Server');
    }
    const accepted: boolean = await this.socket.send(JSON.stringify(payload));
    if (!accepted) {
      throw new Error('WebSocket 未接受发送请求');
    }
  }

  private waitForMessage(type: string, uploadId: string, timeoutMs: number): Promise<ServerMessage> {
    return new Promise<ServerMessage>((resolve: (message: ServerMessage) => void,
      reject: (reason: Error) => void) => {
      const waiter: MessageWaiter = {
        type: type,
        uploadId: uploadId,
        resolve: resolve,
        reject: reject,
        timer: -1
      };
      waiter.timer = setTimeout(() => {
        this.waiters = this.waiters.filter((item: MessageWaiter) => item !== waiter);
        reject(new Error('等待服务端消息超时：' + type));
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  private resolveWaiters(message: ServerMessage): void {
    const pending: MessageWaiter[] = [...this.waiters];
    pending.forEach((waiter: MessageWaiter) => {
      const matchesType: boolean = waiter.type === message.type;
      const matchesUpload: boolean = waiter.uploadId.length === 0 ||
        waiter.uploadId === (message.uploadId ?? '');
      if (matchesType && matchesUpload) {
        clearTimeout(waiter.timer);
        this.waiters = this.waiters.filter((item: MessageWaiter) => item !== waiter);
        if (message.type === 'audio_error') {
          waiter.reject(new Error(message.message ?? '音频上传失败'));
        } else {
          waiter.resolve(message);
        }
      } else if (message.type === 'audio_error' &&
        (waiter.type === 'audio_ready' || waiter.type === 'audio_saved') &&
        (waiter.uploadId.length === 0 || waiter.uploadId === (message.uploadId ?? ''))) {
        clearTimeout(waiter.timer);
        this.waiters = this.waiters.filter((item: MessageWaiter) => item !== waiter);
        waiter.reject(new Error(message.message ?? '音频上传失败'));
      }
    });
  }

  private rejectWaiters(message: string): void {
    const pending: MessageWaiter[] = [...this.waiters];
    this.waiters = [];
    pending.forEach((waiter: MessageWaiter) => {
      clearTimeout(waiter.timer);
      waiter.reject(new Error(message));
    });
  }

  private startKeepAlive(): void {
    this.stopKeepAlive();
    this.keepAliveTimer = setInterval(() => {
      if (this.connected) {
        this.sendJson({ type: 'ping', timestamp: Date.now() }).catch((error: Error) => {
          this.notifyState('心跳发送失败：' + error.message);
        });
      }
    }, 20000);
  }

  private stopKeepAlive(): void {
    if (this.keepAliveTimer !== -1) {
      clearInterval(this.keepAliveTimer);
      this.keepAliveTimer = -1;
    }
  }

  /** 发送固定文本指令，并由服务端启动对应广播任务。 */
  async sendTextBroadcast(text: string, mode: string = 'mock'): Promise<void> {
    if (!text.trim()) {
      throw new Error('广播文本不能为空');
    }
    await this.sendJson({
      type: 'start_broadcast',
      mode: mode,
      commandText: text,
      source: 'text',
      timestamp: Date.now()
    });
  }

  /** 上传本地录音文件；服务端确认保存后，再启动广播任务并等待状态推送。 */
  async sendAudioBroadcast(
    filePath: string,
    onProgress: (progress: number) => void,
    mode: string = 'mock'
  ): Promise<void> {
    if (this.uploadBusy) {
      throw new Error('当前已有音频正在上传');
    }
    if (!this.connected || !this.socket) {
      throw new Error('请先连接 Broadcast Server');
    }
    this.uploadBusy = true;
    let file: fs.File | undefined = undefined;
    const uploadId: string = 'upload_' + Date.now().toString();
    try {
      const info = fs.statSync(filePath);
      const fileSize: number = info.size;
      if (fileSize <= 0) {
        throw new Error('录音文件为空');
      }
      const parts: string[] = filePath.split('/');
      const fileName: string = parts[parts.length - 1] || 'broadcast.m4a';
      const mimeType: string = fileName.toLowerCase().endsWith('.mp3') ? 'audio/mpeg' : 'audio/mp4';

      const readyPromise: Promise<ServerMessage> = this.waitForMessage('audio_ready', uploadId, 10000);
      await this.sendJson({
        type: 'audio_start',
        uploadId: uploadId,
        fileName: fileName,
        mimeType: mimeType,
        size: fileSize
      });
      await readyPromise;

      file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const chunkSize: number = 128 * 1024;
      let sent: number = 0;
      while (sent < fileSize) {
        const wanted: number = Math.min(chunkSize, fileSize - sent);
        const buffer: ArrayBuffer = new ArrayBuffer(wanted);
        const readLength: number = fs.readSync(file.fd, buffer, { offset: 0, length: wanted });
        if (readLength <= 0) {
          throw new Error('读取录音文件失败');
        }
        const chunk: ArrayBuffer = readLength === wanted ? buffer : buffer.slice(0, readLength);
        const accepted: boolean = await this.socket.send(chunk);
        if (!accepted) {
          throw new Error('服务端未接受音频分片');
        }
        sent += readLength;
        onProgress(Math.min(100, Math.floor(sent * 100 / fileSize)));
      }
      fs.closeSync(file.fd);
      file = undefined;

      const savedPromise: Promise<ServerMessage> = this.waitForMessage('audio_saved', uploadId, 15000);
      await this.sendJson({ type: 'audio_end', uploadId: uploadId });
      const saved: ServerMessage = await savedPromise;
      this.notifyState('音频已保存到服务端：' + (saved.fileName ?? fileName));

      await this.sendJson({
        type: 'start_broadcast',
        mode: mode,
        source: 'audio',
        uploadId: uploadId,
        fileName: saved.fileName ?? fileName,
        timestamp: Date.now()
      });
    } catch (error) {
      if (file !== undefined) {
        try {
          fs.closeSync(file.fd);
        } catch (_) {
          // Best-effort resource cleanup.
        }
      }
      throw new Error(String(error));
    } finally {
      this.uploadBusy = false;
    }
  }

  /** 任务终态或用户取消时，通知服务端后主动关闭长连接。 */
  async closeSession(taskId: string, reason: string, found: boolean): Promise<void> {
    if (this.socket && this.connected) {
      try {
        if (found && taskId.length > 0) {
          await this.sendJson({ type: 'client_done', taskId: taskId });
        } else if (taskId.length > 0) {
          await this.sendJson({ type: 'cancel_broadcast', taskId: taskId });
        }
        await this.sendJson({ type: 'client_close', reason: reason });
      } catch (error) {
        this.notifyState('关闭前通知服务端失败：' + String(error));
      }
      try {
        await this.socket.close({ code: 1000, reason: reason });
      } catch (error) {
        this.notifyState('关闭 WebSocket 失败：' + String(error));
      }
    }
    this.connected = false;
    this.stopKeepAlive();
    this.socket = undefined;
    this.rejectWaiters('客户端已关闭连接');
    this.notifyState('连接已关闭');
  }

  async disconnect(reason: string = 'user_disconnect'): Promise<void> {
    await this.closeSession('', reason, false);
  }
}
