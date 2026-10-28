import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { AudioPlaybackService, AudioRecorderService } from '../services/AudioRecorderService';
import { BroadcastClientService, ServerMessage, ClientConnectionState } from '../services/BroadcastClientService';

const PURPLE: string = '#7357F5';
const INK: string = '#20232D';
const SUB: string = '#7B8190';
const BG: string = '#F6F7F5';

@Entry
@Component
struct Index {
  private recorder: AudioRecorderService = new AudioRecorderService();
  private player: AudioPlaybackService = new AudioPlaybackService();
  private client: BroadcastClientService = new BroadcastClientService();
  private timer: number = -1;
  private pressActive: boolean = false;
  private startPending: boolean = false;
  private releasePending: boolean = false;

  private phrases: string[] = ['回来吃饭啦', '过来帮个忙', '找到你了请回应一下', '快来客厅一下'];

  @State private page: string = 'home';
  @State private mode: string = 'choose';
  @State private phase: string = 'idle';
  @State private phraseIndex: number = 0;
  @State private audioPath: string = '';
  @State private seconds: number = 0;
  @State private playing: boolean = false;
  @State private online: boolean = true;
  @State private micGranted: boolean = false;
  @State private taskId: string = '';
  @State private stage: string = 'idle';
  @State private detail: string = '等待开始';
  @State private wsConnected: boolean = false;
  @State private progress: number = 0;
  @State private errorText: string = '';
  @State private serverUrl: string = 'ws://192.168.1.20:8765';
  @State private serverConnected: boolean = false;
  @State private serverConnecting: boolean = false;
  @State private connectionMessage: string = '填写服务端手机 IP 后连接';
  @State private serverMode: string = 'mock';

  aboutToDisappear(): void {
    this.clearTimer();
    this.client.disconnect('page_disappear').catch(() => {});
    this.player.release().catch(() => {});
    this.recorder.release().catch(() => {});
  }

  private timeText(value: number): string {
    const s: string = value < 10 ? '0' + value.toString() : value.toString();
    return '00:' + s;
  }

  private async enterBroadcast(): Promise<void> {
    this.page = 'broadcast';
    this.mode = 'choose';
    this.phase = 'idle';
    this.seconds = 0;
    this.audioPath = '';
    this.progress = 0;
    this.stage = 'idle';
    this.wsConnected = false;
  }

  private async requestMic(): Promise<boolean> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const manager = abilityAccessCtrl.createAtManager();
      const result = await manager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      this.micGranted = result.authResults.length > 0 && result.authResults[0] === 0;
      return this.micGranted;
    } catch (error) {
      this.micGranted = false;
      console.error('麦克风权限请求失败：' + String(error));
      return false;
    }
  }

  private async chooseVoice(): Promise<void> {
    this.mode = 'record';
    if (!this.micGranted) {
      await this.requestMic();
    }
  }

  private chooseText(): void {
    this.mode = 'text';
  }

  private async beginRecording(): Promise<void> {
    if (this.phase === 'recording' || this.phase === 'starting' || this.phase === 'stopping') {
      return;
    }
    if (!this.micGranted) {
      const granted: boolean = await this.requestMic();
      if (!granted) {
        return;
      }
    }
    this.pressActive = true;
    this.releasePending = false;
    this.startPending = true;
    this.seconds = 0;
    this.phase = 'starting';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.audioPath = await this.recorder.start(context);
      this.startPending = false;
      this.phase = 'recording';
      this.timer = setInterval(() => {
        if (this.phase !== 'recording') {
          this.clearTimer();
          return;
        }
        if (this.seconds >= 29) {
          this.seconds = 30;
          this.pressActive = false;
          this.stopRecording();
          return;
        }
        this.seconds += 1;
      }, 1000);
      if (this.releasePending || !this.pressActive) {
        await this.stopRecording();
      }
    } catch (error) {
      this.startPending = false;
      this.phase = 'idle';
      this.pressActive = false;
      console.error('录音启动失败：' + String(error));
    }
  }

  private async endRecordingPress(): Promise<void> {
    this.pressActive = false;
    if (this.startPending) {
      this.releasePending = true;
      return;
    }
    if (this.phase === 'recording') {
      await this.stopRecording();
    }
  }

  private clearTimer(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private async stopRecording(): Promise<void> {
    if (this.phase !== 'recording' && this.phase !== 'starting') {
      return;
    }
    this.clearTimer();
    this.phase = 'stopping';
    try {
      this.audioPath = await this.recorder.stop();
      this.phase = this.seconds > 0 ? 'preview' : 'idle';
    } catch (error) {
      this.phase = 'idle';
      console.error('录音保存失败：' + String(error));
    }
  }

  private async togglePlayback(): Promise<void> {
    if (!this.audioPath) {
      return;
    }
    try {
      if (this.playing) {
        await this.player.pause();
        this.playing = false;
      } else {
        await this.player.play(this.audioPath, () => { this.playing = false; });
        this.playing = true;
      }
    } catch (error) {
      this.playing = false;
      console.error('试听失败：' + String(error));
    }
  }

  private async retake(): Promise<void> {
    await this.player.release();
    await this.recorder.release();
    this.audioPath = '';
    this.seconds = 0;
    this.playing = false;
    this.phase = 'idle';
  }

  private onConnectionState(state: ClientConnectionState): void {
    this.serverConnected = state.connected;
    this.wsConnected = state.connected;
    this.serverConnecting = false;
    this.connectionMessage = state.message;
  }

  private onServerMessage(message: ServerMessage): void {
    if (message.type === 'server_hello') {
      this.connectionMessage = '已连接服务端，协议版本 ' + (message.protocolVersion ?? 1).toString();
      return;
    }
    if (message.type !== 'broadcast_progress') {
      if (message.type === 'audio_saved') {
        this.connectionMessage = '音频已保存到服务端';
      } else if (message.type === 'audio_error') {
        this.connectionMessage = '音频接收失败：' + (message.message ?? '未知错误');
      }
      return;
    }
    this.taskId = message.taskId ?? this.taskId;
    this.stage = message.stage ?? message.status ?? this.stage;
    this.progress = message.progress ?? this.progress;
    this.detail = message.message ?? this.detail;
    const status: string = message.status ?? 'searching';
    if (status === 'found' || status === 'completed') {
      this.progress = 100;
      this.phase = 'found';
    } else if (status === 'failed' || status === 'cancelled') {
      this.phase = 'failure';
      this.errorText = message.message ?? '广播任务未完成';
    } else {
      this.phase = 'tracking';
    }
  }

  private async connectServer(): Promise<void> {
    if (this.serverConnected || this.serverConnecting) {
      return;
    }
    this.serverConnecting = true;
    this.connectionMessage = '正在连接服务端…';
    try {
      await this.client.connect(this.serverUrl, (message: ServerMessage) => this.onServerMessage(message),
        (state: ClientConnectionState) => this.onConnectionState(state));
      this.serverConnected = true;
      this.connectionMessage = 'WebSocket 已连接';
    } catch (error) {
      this.serverConnected = false;
      this.serverConnecting = false;
      this.connectionMessage = '连接失败：' + String(error);
    }
  }

  private async disconnectServer(): Promise<void> {
    await this.client.disconnect('manual_disconnect');
    this.serverConnected = false;
    this.wsConnected = false;
    this.connectionMessage = '已主动断开连接';
  }

  private async startBroadcast(kind: string): Promise<void> {
    if (this.phase === 'tracking') {
      return;
    }
    if (!this.serverConnected) {
      this.phase = 'failure';
      this.errorText = '请先连接 Broadcast Server';
      this.detail = this.errorText;
      return;
    }
    if (kind === 'audio' && !this.audioPath) {
      this.phase = 'failure';
      this.errorText = '请先录制并确认语音';
      this.detail = this.errorText;
      return;
    }
    this.mode = 'tracking';
    this.phase = 'tracking';
    this.progress = 0;
    this.taskId = '';
    this.stage = 'discovering_device';
    this.detail = kind === 'text' ? '正在发送固定文本指令…' : '正在上传语音文件…';
    this.errorText = '';
    try {
      await this.player.release();
      if (kind === 'text') {
        await this.client.sendTextBroadcast(this.phrases[this.phraseIndex], this.serverMode);
      } else {
        await this.client.sendAudioBroadcast(this.audioPath, (value: number) => {
          this.progress = value;
          this.detail = '正在上传语音文件 ' + value.toString() + '%';
        }, this.serverMode);
      }
      // 状态文字以服务端后续推送为准，避免覆盖可能已到达的首条进度消息。
    } catch (error) {
      this.phase = 'failure';
      this.errorText = '发送失败：' + String(error);
      this.detail = this.errorText;
    }
  }

  private async finish(): Promise<void> {
    this.clearTimer();
    await this.client.closeSession(this.taskId, this.phase === 'found' ? 'task_completed' : 'user_finished', this.phase === 'found');
    this.serverConnected = false;
    this.wsConnected = false;
    await this.player.release();
    await this.recorder.release();
    this.page = 'home';
    this.mode = 'choose';
    this.phase = 'idle';
    this.audioPath = '';
    this.seconds = 0;
    this.playing = false;
    this.stage = 'idle';
  }

  @Builder
  private TopBar(title: string, back: boolean) {
    Row({ space: 12 }) {
      if (back) {
        Button('‹').width(42).height(42).fontSize(28).fontColor(INK)
          .backgroundColor('#FFFFFF').borderRadius(21)
          .onClick(() => {
            if (this.phase === 'tracking') {
              return;
            }
            this.mode = 'choose';
            this.phase = 'idle';
          });
      }
      Column({ space: 3 }) {
        Text(title).fontSize(22).fontWeight(FontWeight.Bold).fontColor(INK);
        if (!back) {
          Text('ROBOT HOME').fontSize(10).fontColor(SUB).letterSpacing(1.5);
        }
      }.alignItems(HorizontalAlign.Start);
      Blank();
      Text(this.online ? '在线' : '离线').fontSize(12).fontColor(this.online ? '#238B55' : '#D94850')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor(this.online ? '#E5F7EC' : '#FFF0F0').borderRadius(16)
        .onClick(() => { this.online = !this.online; });
    }.width('100%').alignItems(VerticalAlign.Center);
  }

  @Builder
  private ConnectionPanel() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Text('广播服务连接').fontSize(15).fontWeight(FontWeight.Bold).fontColor(INK);
          Text(this.serverConnected ? '● 已连接' : (this.serverConnecting ? '● 连接中' : '● 未连接'))
            .fontSize(11).fontColor(this.serverConnected ? '#238B55' : '#C98A24');
        }.alignItems(HorizontalAlign.Start).layoutWeight(1);
        Button(this.serverConnected ? '断开' : (this.serverConnecting ? '连接中…' : '连接服务'))
          .height(36).fontSize(12).fontColor(this.serverConnected ? '#D94850' : '#FFFFFF')
          .backgroundColor(this.serverConnected ? '#FFF0F0' : PURPLE)
          .enabled(!this.serverConnecting)
          .onClick(() => this.serverConnected ? this.disconnectServer() : this.connectServer());
      }.width('100%');
      TextInput({ text: this.serverUrl, placeholder: 'ws://192.168.1.20:8765' })
        .width('100%').height(42).fontSize(13).backgroundColor('#F7F7FA').borderRadius(10)
        .onChange((value: string) => { this.serverUrl = value; });
      Row({ space: 8 }) {
        Button('模拟进度').layoutWeight(1).height(34).fontSize(12)
          .fontColor(this.serverMode === 'mock' ? '#FFFFFF' : PURPLE)
          .backgroundColor(this.serverMode === 'mock' ? PURPLE : '#F0ECFF')
          .onClick(() => { this.serverMode = 'mock'; });
        Button('真实进度').layoutWeight(1).height(34).fontSize(12)
          .fontColor(this.serverMode === 'real' ? '#FFFFFF' : PURPLE)
          .backgroundColor(this.serverMode === 'real' ? PURPLE : '#F0ECFF')
          .onClick(() => { this.serverMode = 'real'; });
      }.width('100%');
      Text(this.connectionMessage).fontSize(11).fontColor(SUB).maxLines(2);
    }.padding(14).backgroundColor('#FFFFFF').borderRadius(18).width('100%');
  }

  @Builder
  private Home() {
    Scroll() {
      Column({ space: 18 }) {
        this.TopBar('我的扫地机', false);
        Column({ space: 14 }) {
          Row() {
            Column({ space: 6 }) {
              Text('清洁，让家更自在').fontSize(20).fontWeight(FontWeight.Bold).fontColor(INK);
              Text(this.online ? '设备在线 · 空闲中' : '设备离线').fontSize(12).fontColor(SUB);
            }.alignItems(HorizontalAlign.Start);
            Blank();
            Text('82%').fontSize(16).fontWeight(FontWeight.Medium).fontColor(INK);
          }
          Stack({ alignContent: Alignment.Center }) {
            Column().width(230).height(154).borderRadius(77).backgroundColor('#F0ECFF');
            Column().width(190).height(124).borderRadius(62).backgroundColor('#F8F7FC');
            Column({ space: 8 }) {
              Row({ space: 6 }) {
                Column().width(7).height(7).borderRadius(4).backgroundColor('#222633');
                Column().width(7).height(7).borderRadius(4).backgroundColor('#222633');
              }
              Text('ROBOT').fontSize(11).fontWeight(FontWeight.Bold).fontColor(PURPLE).letterSpacing(2);
            }.width(150).height(70).borderRadius(35).backgroundColor('#FFFFFF')
              .border({ width: 1, color: '#E1E3E9' }).alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center);
          }.width('100%').height(170);
          Button('▶  开始清扫').width('100%').height(50).fontSize(15).fontColor('#FFFFFF')
            .backgroundColor(PURPLE).borderRadius(16);
        }.padding(18).backgroundColor('#FFFFFF').borderRadius(24);
        Text('常用功能').fontSize(18).fontWeight(FontWeight.Bold).fontColor(INK);
        Row({ space: 14 }) {
          Column({ space: 8 }) {
            Text('▤').fontSize(27).fontColor(PURPLE);
            Text('远程广播').fontSize(15).fontWeight(FontWeight.Bold).fontColor(INK);
            Text('让家人听见你的声音').fontSize(11).fontColor(SUB);
          }.alignItems(HorizontalAlign.Start).layoutWeight(1);
          Text('›').fontSize(28).fontColor(SUB);
        }.padding(18).backgroundColor('#FFFFFF').borderRadius(20)
          .border({ width: 1.5, color: '#E7E0FF' }).onClick(() => this.enterBroadcast());
        Text('远程广播找人 · UX Demo').fontSize(11).fontColor(SUB);
      }.padding({ left: 20, right: 20, top: 18, bottom: 24 }).width('100%');
    }.width('100%').height('100%').scrollBar(BarState.Off);
  }

  @Builder
  private ModeChoice() {
    Column({ space: 16 }) {
      Text('选择广播方式').fontSize(24).fontWeight(FontWeight.Bold).fontColor(INK);
      Text('选择固定话术，或录制一段语音').fontSize(13).fontColor(SUB);
      Row({ space: 12 }) {
        Text('▤').fontSize(26).fontColor(PURPLE);
        Column({ space: 6 }) {
          Text('固定文本指令').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK);
          Text('一键选择常用语句').fontSize(12).fontColor(SUB);
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        Text('›').fontSize(26).fontColor(PURPLE);
      }.padding(18).backgroundColor('#F0ECFF').borderRadius(18).onClick(() => { this.mode = 'text'; });
      Row({ space: 12 }) {
        Text('♫').fontSize(26).fontColor('#387CDE');
        Column({ space: 6 }) {
          Text('语音录音广播').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK);
          Text('按住录音，最长 30 秒').fontSize(12).fontColor(SUB);
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        Text('›').fontSize(26).fontColor('#387CDE');
      }.padding(18).backgroundColor('#EEF5FF').borderRadius(18).onClick(() => this.chooseVoice());
    }.padding(20).backgroundColor('#FFFFFF').borderRadius(24).width('100%');
  }

  @Builder
  private TextChoices() {
    Column({ space: 14 }) {
      Row() {
        Text('固定文本指令').fontSize(22).fontWeight(FontWeight.Bold).fontColor(INK);
        Blank();
        Button('切换方式').fontSize(12).fontColor(PURPLE).backgroundColor('#F0ECFF')
          .onClick(() => { this.mode = 'choose'; });
      }
      ForEach(this.phrases, (phrase: string, index: number) => {
        Row() {
          Text(phrase).fontSize(15).fontColor(INK).layoutWeight(1);
          Text(this.phraseIndex === index ? '●' : '○').fontSize(20)
            .fontColor(this.phraseIndex === index ? PURPLE : '#B5B8C4');
        }.padding(15).backgroundColor(this.phraseIndex === index ? '#F0ECFF' : '#FAFAFC')
          .border({ width: 1, color: this.phraseIndex === index ? PURPLE : '#E7E8EE' })
          .borderRadius(14).onClick(() => { this.phraseIndex = index; });
      }, (phrase: string, index: number) => index.toString());
      Button('发送广播').width('100%').height(50).fontColor('#FFFFFF').backgroundColor(PURPLE)
        .borderRadius(16).onClick(() => this.startBroadcast('text'));
    }.padding(20).backgroundColor('#FFFFFF').borderRadius(24).width('100%');
  }

  @Builder
  private RecorderPanel() {
    Column({ space: 16 }) {
      Text(this.phase === 'recording' ? '正在录音' : this.phase === 'preview' ? '录音完成' : '录制一段语音')
        .fontSize(22).fontWeight(FontWeight.Bold).fontColor(INK);
      Text('按住麦克风开始录音，松开结束；最长 30 秒')
        .fontSize(12).fontColor(SUB).textAlign(TextAlign.Center);
      Stack({ alignContent: Alignment.Center }) {
        Column().width(210).height(130).borderRadius(24).backgroundColor('#F0ECFF');
        Column().width(170).height(105).borderRadius(20).backgroundColor('#F8F7FC');
        Text('ROBOT').fontSize(13).fontWeight(FontWeight.Bold).fontColor(PURPLE).letterSpacing(2);
      }.width('100%').height(140);
      Row({ space: 5 }) {
        ForEach([8, 16, 24, 13, 28, 18, 10, 23, 14, 27, 12, 19, 8], (h: number, i: number) => {
          Column().width(4).height(this.phase === 'recording' ? h : Math.max(5, h / 2))
            .borderRadius(2).backgroundColor(this.phase === 'recording' ? PURPLE : '#C9C2EB');
        }, (h: number, i: number) => i.toString());
      }.width('100%').height(34).alignItems(VerticalAlign.Center).justifyContent(FlexAlign.Center);
      Row() {
        Text(this.timeText(this.seconds)).fontSize(14).fontWeight(FontWeight.Bold).fontColor(PURPLE);
        Blank();
        Text('/ 00:30').fontSize(12).fontColor(SUB);
      }.width('100%');
      Progress({ value: this.seconds, total: 30, type: ProgressType.Linear }).color(PURPLE).height(5);
      Button() {
        Text(this.phase === 'recording' ? '■' : '🎙').fontSize(28).fontColor('#FFFFFF');
      }.width(104).height(104).borderRadius(52).backgroundColor(PURPLE)
        .enabled(this.phase === 'idle' || this.phase === 'recording' || this.phase === 'starting')
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.beginRecording();
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.endRecordingPress();
          }
        });
      Text(this.phase === 'recording' ? '松开结束录音' : '按住录音').fontSize(13).fontColor(SUB);
      if (this.phase === 'preview') {
        Row({ space: 10 }) {
          Button(this.playing ? '暂停试听' : '试听录音').layoutWeight(1).height(48)
            .fontColor(PURPLE).backgroundColor('#F0ECFF').onClick(() => this.togglePlayback());
          Button('重录').layoutWeight(1).height(48).onClick(() => this.retake());
        }
        Button('发送广播').width('100%').height(50).fontColor('#FFFFFF').backgroundColor(PURPLE)
          .borderRadius(16).onClick(() => this.startBroadcast('audio'));
      }
    }.padding(20).backgroundColor('#FFFFFF').borderRadius(24).width('100%')
      .alignItems(HorizontalAlign.Center);
  }

  @Builder
  private TrackingPanel() {
    Column({ space: 16 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width(190).height(140).borderRadius(70).backgroundColor('#F0ECFF');
        Text('ROBOT').fontSize(13).fontWeight(FontWeight.Bold).fontColor(PURPLE).letterSpacing(2);
      }.width('100%').height(145);
      Text(this.phase === 'found' ? '已经找到目标人员' : this.phase === 'failure' ? '任务出现异常' : '正在寻找中')
        .fontSize(23).fontWeight(FontWeight.Bold).fontColor(INK);
      Text(this.detail).fontSize(13).fontColor(SUB).textAlign(TextAlign.Center);
      Text(this.wsConnected ? '● WebSocket 状态通道已连接' : '● WebSocket 状态通道未连接')
        .fontSize(12).fontColor(this.wsConnected ? '#238B55' : '#C98A24');
      Row() {
        Text('任务进度').fontSize(12).fontColor(SUB);
        Blank();
        Text(this.progress.toString() + '%').fontSize(12).fontWeight(FontWeight.Bold).fontColor(PURPLE);
      }.width('100%');
      Progress({ value: this.progress, total: 100, type: ProgressType.Linear }).color(PURPLE).height(6);
      Column({ space: 14 }) {
        this.StageRow('广播任务已接收', 0);
        this.StageRow('正在寻找目标人员', 1);
        this.StageRow('正在确认人员回应', 2);
        this.StageRow('已找到目标人员', 3);
      }.padding(18).width('100%').backgroundColor('#FBFAFF').borderRadius(18);
      if (this.phase === 'found') {
        Button('完成').width('100%').height(50).fontColor('#FFFFFF').backgroundColor('#22A765')
          .onClick(() => this.finish());
      } else if (this.phase === 'failure') {
        Text(this.errorText).fontSize(12).fontColor('#D94850');
        Button('返回首页').width('100%').height(50).onClick(() => this.finish());
      } else {
        Button('结束找人').width('100%').height(50).onClick(() => this.finish());
      }
      Text('演示状态由本地模拟器产生；真实设备需接入 WebSocket 协议。')
        .fontSize(11).fontColor(SUB).textAlign(TextAlign.Center);
    }.padding(20).backgroundColor('#FFFFFF').borderRadius(24).width('100%')
      .alignItems(HorizontalAlign.Center);
  }

  private stageIndex(): number {
    if (this.phase === 'found') { return 3; }
    if (this.phase === 'failure') { return -1; }
    if (this.stage === 'confirming_device' || this.stage === 'confirming_response' || this.progress >= 70) { return 2; }
    if (this.stage === 'matching_device' || this.stage === 'matching_person' || this.progress >= 30) { return 1; }
    if (this.taskId.length > 0 || this.phase === 'tracking') { return 0; }
    return -1;
  }

  @Builder
  private StageRow(label: string, index: number) {
    Row({ space: 10 }) {
      Text(this.stageIndex() >= index ? '✓' : '○')
        .fontSize(16).fontColor(this.stageIndex() >= index ? '#22A765' : SUB);
      Text(label).fontSize(14).fontColor(INK).layoutWeight(1);
      if (this.stageIndex() === index) {
        Text('当前').fontSize(11).fontColor(PURPLE);
      }
    }.width('100%');
  }

  build() {
    Column({ space: 16 }) {
      if (this.page === 'home') {
        this.Home();
      } else {
        this.TopBar('远程广播', true);
        this.ConnectionPanel();
        Scroll() {
          Column({ space: 14 }) {
            if (this.mode === 'choose') {
              this.ModeChoice();
            } else if (this.mode === 'text') {
              this.TextChoices();
            } else if (this.mode === 'record') {
              this.RecorderPanel();
            } else if (this.mode === 'tracking') {
              this.TrackingPanel();
            }
            Text('状态结果以设备回执为准 · 语音最长 30 秒')
              .fontSize(11).fontColor(SUB).textAlign(TextAlign.Center).padding({ bottom: 18 });
          }.width('100%');
        }.layoutWeight(1).scrollBar(BarState.Off);
      }
    }.padding({ left: 18, right: 18, top: 14, bottom: 10 }).width('100%').height('100%').backgroundColor(BG);
  }
}
