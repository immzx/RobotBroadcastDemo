import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

// 应用入口：加载远程广播找人主页面。
export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index');
  }
}
