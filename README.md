# 合盖不休眠（LidAwake）

一个 macOS 菜单栏小工具：点一下，合上笔记本盖子后电脑也不会睡眠。

## 下载

不想自己编译的话，直接去 [Releases](https://github.com/Feathers2005/LidAwake/releases/latest) 下载 `LidAwake-v1.1.0.zip`，解压后把 `合盖不休眠.app` 拖进「应用程序」。

首次打开请 **右键 → 打开**（应用未做 Apple 公证，直接双击会被 Gatekeeper 拦下）。

想自己构建的话，看下面「构建」一节。

```
合盖不休眠.app/                     ← 双击就能用
Sources/                           ← Swift 源码
  main.swift                       入口
  AppDelegate.swift                菜单栏界面与交互
  PowerManager.swift               pmset 调用 / 权限处理
  Shell.swift                      子进程封装
  Logger.swift                     日志
Resources/
  Info.plist                       应用描述
  AppIcon.icns                     图标
  LidAwake.iconset/                图标源文件
Tools/make_icon.swift              图标生成脚本
build.sh                           一键构建
```

## 原理（这点很重要）

网上很多教程会让你用 `caffeinate`，但**它挡不住合盖睡眠**。`caffeinate` 只是阻止「闲置睡眠」，盖子一合，系统照样睡。

macOS 上真正控制合盖睡眠的是电源标志 `SleepDisabled`：

```bash
sudo pmset -a disablesleep 1   # 开：合盖也不睡
sudo pmset -a disablesleep 0   # 关：恢复正常
```

本工具就是给这两个命令套了个菜单栏界面。

## 使用

1. 双击 `合盖不休眠.app`。
2. 菜单栏（屏幕右上角）会出现一台小电脑图标。
3. 点图标 → **开启关盖运行**。第一次会弹管理员密码框（系统要求，无法绕过）。
4. 建议顺手在 **自动恢复** 里选个时间，比如 1 小时，到点自动关掉，防止忘记。
5. 不用时点 **关闭关盖运行**，或选 **恢复默认电源设置**。

### 免密切换（可选）

如果每次都要输密码嫌麻烦，点 **安装免密切换规则…**，它会在
`/etc/sudoers.d/lidawake` 里写入两条精确授权：

```
%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

只授权这两条命令，不涉及其他任何权限。想撤销：菜单里点 **免密切换：已启用 ✓** → 移除规则，
或者手动 `sudo rm -f /etc/sudoers.d/lidawake`。

## ⚠️ 散热提醒

合盖运行时热量会积在机身里，散热效率比开盖差很多。

- MacBook Air（无风扇）尤其要注意，别垫在床上、沙发、包里长时间跑。
- 推荐配合「自动恢复」使用，离开前记得关。
- 电量也会消耗得比平时快。

## 验证它真的生效了

```bash
pmset -g | grep SleepDisabled
# 1 = 已开启（合盖不睡）；0 = 正常
```

## 如果状态被外部重置

某些情况下——系统电源事件、其他电源管理软件、macOS 自己的清理——`SleepDisabled` 标志会在开启几分钟后被悄悄改回 0，表现成「开着开着就自己关掉了」。

从 1.1 起，应用会守住这个状态：

1. **每 3 秒核对一次**实际状态和你开启的意愿是否一致；连续两次对不上，才判定为「被外部重置」（防止一次读取卡顿造成误判）。
2. 如果装过免密切换规则，会**静默抢回**（不弹窗），并写一行日志；没装规则则只在菜单里提示，不会反复弹密码框。
3. 如果一小时内被重置超过 10 次，它会停手——那说明有别的程序在和我们拉锯，得先把它找出来。

菜单栏图标旁的 `ON` 和菜单第一行会如实反映当前状态。

## 构建

```bash
cd LidAwake
bash build.sh
```

需要 macOS + Xcode Command Line Tools（`swiftc`）。

## 卸载

1. 菜单里先「恢复默认电源设置」。
2. 退出应用，把 `合盖不休眠.app` 拖进废纸篓。
3. 如果装过免密规则，记得 `sudo rm -f /etc/sudoers.d/lidawake`。
4. 日志在 `~/Library/Logs/LidAwake.log`，可删。

## 日志

`~/Library/Logs/LidAwake.log`，超过 1MB 自动重建。
