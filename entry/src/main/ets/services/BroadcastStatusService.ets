/** Broadcast task event adapter. No real device claim in demo mode. */
export interface BroadcastTaskEvent {
  taskId: string;
  stage: string;
  message: string;
  connected: boolean;
}

export class BroadcastStatusService {
  private taskId: string = '';
  private callback: ((event: BroadcastTaskEvent) => void) | undefined = undefined;
  private timers: number[] = [];
  private running: boolean = false;
  private stages: string[] = ['connecting', 'accepted', 'speaking', 'searching', 'found'];

  /** In production, replace this method with websocket.connect(), on message + reconnect/status resync. */
  async startDemo(taskId: string, callback: (event: BroadcastTaskEvent) => void): Promise<void> {
    this.stop();
    this.taskId = taskId;
    this.callback = callback;
    this.running = true;
    this.emit('connecting', '正在连接设备状态通道', false);
    await new Promise<void>((resolve: () => void) => { setTimeout(() => resolve(), 500); });
    if (this.running) { this.emit('accepted', '扫地机已接收任务', true); }
  }

  markSent(): void {
    if (!this.running) { return; }
    // Never report FOUND merely because send() returned; simulator emits separate events.
    this.schedule(800, 'speaking', '扫地机正在播报');
    this.schedule(2700, 'searching', '正在等待人员回应');
    this.schedule(6500, 'found', '检测到找人完成（演示事件）');
  }

  hasReached(current: string, stage: string): boolean {
    const a: number = this.stages.indexOf(current);
    const b: number = this.stages.indexOf(stage);
    return a >= 0 && b >= 0 && a >= b;
  }

  private schedule(delay: number, stage: string, message: string): void {
    const handle: number = setTimeout(() => {
      if (this.running) { this.emit(stage, message, true); }
    }, delay);
    this.timers.push(handle);
  }

  private emit(stage: string, message: string, connected: boolean): void {
    if (this.callback) {
      this.callback({ taskId: this.taskId, stage: stage, message: message, connected: connected });
    }
  }

  stop(): void {
    this.running = false;
    this.timers.forEach((id: number) => clearTimeout(id));
    this.timers = [];
    this.callback = undefined;
  }
}
