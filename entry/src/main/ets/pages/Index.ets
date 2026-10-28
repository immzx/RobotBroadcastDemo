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

  private onTaskEvent(event: BroadcastTaskEvent): void {
    if (event.taskId !== this.taskId) {
      return;
    }
    this.stage = event.stage;
    this.detail = event.message;
    this.wsConnected = event.connected;
    if (event.stage === 'found') {
      this.phase = 'found';
    } else if (event.stage === 'failed') {
      this.phase = 'failure';
      this.errorText = event.message;
    } else {
      this.phase = 'tracking';
    }
  }

  private async startBroadcast(kind: string): Promise<void> {
    if (!this.online || this.phase === 'tracking') {
      return;
    }
    if (kind === 'audio' && !this.audioPath) {
      return;
    }
    this.mode = 'tracking';
    this.phase = 'tracking';
    this.progress = 0;
    this.taskId = 'broadcast_' + Date.now().toString();
    const id: string = this.taskId;
    try {
      await this.player.release();
      await this.status.startDemo(id, (event: BroadcastTaskEvent) => this.onTaskEvent(event));
      if (kind === 'text') {
        await this.transfer.sendText(this.phrases[this.phraseIndex], this.online);
      } else {
        await this.transfer.sendAudio(this.audioPath, this.online, (value: number) => { this.progress = value; });
      }
      this.status.markSent();
    } catch (error) {
      this.status.stop();
      this.phase = 'failure';
      this.errorText = '发送失败：' + String(error);
      this.detail = this.errorText;
    }
  }

  private async finish(): Promise<void> {
    this.clearTimer();
    this.status.stop();
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
      Text(this.wsConnected ? '● 状态通道已连接（模拟）' : '● 状态通道连接中 / 中断')
        .fontSize(12).fontColor(this.wsConnected ? '#238B55' : '#C98A24');
      Column({ space: 14 }) {
        this.StageRow('已发送任务', 'accepted');
        this.StageRow('设备正在播报', 'speaking');
        this.StageRow('等待人员响应', 'searching');
        this.StageRow('已找到', 'found');
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

  @Builder
  private StageRow(label: string, value: string) {
    Row({ space: 10 }) {
      Text(this.status.hasReached(this.stage, value) ? '✓' : '○')
        .fontSize(16).fontColor(this.status.hasReached(this.stage, value) ? '#22A765' : SUB);
      Text(label).fontSize(14).fontColor(INK).layoutWeight(1);
      if (this.stage === value) {
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
