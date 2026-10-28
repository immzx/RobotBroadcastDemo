import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';

/**
 * 麦克风录音服务。
 * HarmonyOS 内置 AVRecorder 在此示例中输出 AAC 编码的 M4A 文件。
 * 如果扫地机固件协议强制要求 MP3，需要在真实设备联调阶段补充转码能力。
 */
export class AudioRecorderService {
  private recorder: media.AVRecorder | undefined = undefined;
  private fileFd: number | undefined = undefined;
  private outputPath: string = '';

  /** 创建录音文件并启动录音。调用前需已获得麦克风授权。 */
  async start(context: common.Context): Promise<string> {
    await this.release();
    this.outputPath = `${context.filesDir}/broadcast_${Date.now()}.m4a`;
    const file = await fileIo.open(this.outputPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    this.fileFd = file.fd;

    try {
      this.recorder = await media.createAVRecorder();
      const config: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: {
          audioBitrate: 96000,
          audioChannels: 1,
          audioCodec: media.CodecMimeType.AUDIO_AAC,
          audioSampleRate: 44100,
          fileFormat: media.ContainerFormatType.CFT_MPEG_4A
        } as media.AVRecorderProfile,
        url: `fd://${file.fd.toString()}`
      };
      await this.recorder.prepare(config);
      await this.recorder.start();
      return this.outputPath;
    } catch (error) {
      console.error(`录音启动失败：${String(error)}`);
      await this.closeFd();
      await this.release();
      throw new Error(String(error));
    }
  }

  /** 停止录音并释放录音器，返回已保存的音频文件路径。 */
  async stop(): Promise<string> {
    try {
      if (this.recorder && (this.recorder.state === 'started' || this.recorder.state === 'paused')) {
        await this.recorder.stop();
      }
    } catch (error) {
      console.error(`停止录音失败：${String(error)}`);
      throw new Error(String(error));
    } finally {
      await this.closeFd();
      await this.release();
    }
    return this.outputPath;
  }

  /** 录音失败或页面退出时释放系统资源。 */
  async release(): Promise<void> {
    try {
      if (this.recorder) {
        // 页面异常退出时也停止正在进行的录音，避免录音器和文件描述符泄漏。
        if (this.recorder.state === 'started' || this.recorder.state === 'paused') {
          try {
            await this.recorder.stop();
          } catch (stopError) {
            console.error(`释放前停止录音失败：${String(stopError)}`);
          }
        }
        await this.recorder.release();
        this.recorder = undefined;
      }
    } catch (error) {
      console.error(`释放录音器失败：${String(error)}`);
      this.recorder = undefined;
    } finally {
      await this.closeFd();
    }
  }

  private async closeFd(): Promise<void> {
    try {
      if (this.fileFd !== undefined) {
        await fileIo.close(this.fileFd);
        this.fileFd = undefined;
      }
    } catch (error) {
      console.error(`关闭录音文件失败：${String(error)}`);
      this.fileFd = undefined;
    }
  }
}

/** 本地音频播放服务，负责试听与暂停/继续。 */
export class AudioPlaybackService {
  private player: media.AVPlayer | undefined = undefined;
  private fileFd: number | undefined = undefined;
  private prepared: boolean = false;
  private completionCallback: (() => void) | undefined = undefined;

  async play(path: string, onCompleted: () => void): Promise<void> {
    // 已准备的播放器执行继续播放；首次播放才创建资源。
    if (this.player && this.prepared && this.player.state !== 'completed') {
      this.completionCallback = onCompleted;
      await this.player.play();
      return;
    }

    await this.release();
    const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    this.fileFd = file.fd;
    this.player = await media.createAVPlayer();
    this.completionCallback = onCompleted;

    this.player.on('stateChange', async (state: media.AVPlayerState, _reason: media.StateChangeReason) => {
      try {
        if (state === 'initialized') {
          await this.player?.prepare();
        } else if (state === 'prepared') {
          this.prepared = true;
          await this.player?.play();
        } else if (state === 'completed') {
          this.completionCallback?.();
        }
      } catch (error) {
        console.error(`音频播放状态切换失败：${String(error)}`);
      }
    });
    this.player.url = `fd://${file.fd.toString()}`;
  }

  async pause(): Promise<void> {
    try {
      if (this.player && this.prepared && this.player.state === 'playing') {
        await this.player.pause();
      }
    } catch (error) {
      console.error(`暂停试听失败：${String(error)}`);
    }
  }

  async release(): Promise<void> {
    try {
      if (this.player) {
        this.player.off('stateChange');
        await this.player.release();
        this.player = undefined;
      }
    } catch (error) {
      console.error(`释放播放器失败：${String(error)}`);
      this.player = undefined;
    }
    this.prepared = false;
    try {
      if (this.fileFd !== undefined) {
        await fileIo.close(this.fileFd);
        this.fileFd = undefined;
      }
    } catch (error) {
      console.error(`关闭试听文件失败：${String(error)}`);
      this.fileFd = undefined;
    }
  }
}
