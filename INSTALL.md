# 安装说明

## 下载

去 [Releases](https://github.com/velosovittoria545-oss/HearMe/releases) 下载 `HearMe-1.0.0-macOS.zip`。

**支持**：macOS 14 (Sonoma) 及以上 · Intel 和 Apple Silicon 都行（Universal 二进制）

---

## 安装

1. 解压 zip，把 `HearMe.app` 拖进「应用程序」文件夹
2. **首次打开会被 macOS 拦截**（下面解释原因）
3. 打开「终端」，执行一次：

```bash
xattr -cr /Applications/HearMe.app
```

4. 现在可以正常双击打开了

---

## 为什么会被拦截

这个 App **没有 Apple 开发者签名**（需要每年 $99 的开发者账号）。macOS 的 Gatekeeper 会阻止任何从网上下载、又没有 Apple 认证的 App。

你可以自己验证它没有做坏事：

```bash
# 看签名信息（会显示 adhoc，说明是自签名）
codesign -dv /Applications/HearMe.app

# 看它要了哪些权限（只有麦克风，没有网络）
codesign -d --entitlements - /Applications/HearMe.app
```

`xattr -cr` 做的事只是**去掉"从网上下载"这个标记**，不是绕过安全检查——它不会改变 App 本身。

### 另一种打开方式（不用终端）

1. 在「应用程序」里**右键**点 HearMe.app → 选「打开」
2. 弹窗里再点一次「打开」

这样 macOS 会记住你的选择，以后双击就行。

> 如果右键打开也失败（提示"已损坏"），说明你的系统策略更严，只能用 `xattr -cr`。

---

## 首次运行要授权

打开后会要两个权限，都是必须的：

| 权限 | 用途 | 能拒绝吗 |
|---|---|---|
| **屏幕与系统录音** | macOS 唯一允许读取"其他 App 播放的声音"的通道。**不看你屏幕**，只读音频流 | 不能，拒绝就抓不到会议声音 |
| **语音识别** | 调用系统离线 ASR 把声音转文字 | 不能 |

授权路径：**系统设置 › 隐私与安全性 › 屏幕与系统录音** → 勾选「合秘」

> 授权后建议**退出重开一次**，让权限生效。

麦克风是**可选**的（默认关闭）。只有你想同时记下自己的发言时才需要。

---

## 验证它真的不联网

三个办法，任选：

```bash
# 1. 看有没有网络权限（沙盒 App 会列出来，这个没有）
codesign -d --entitlements - /Applications/HearMe.app

# 2. 运行时看有没有网络连接
lsof -i -a -p $(pgrep -f HearMe) 2>/dev/null

# 3. 直接断网跑一次，功能完全正常
```

代码是开源的，`Sources/AudioCapture.swift` 里只有 `ScreenCaptureKit` 和 `AVAudioEngine`，没有任何 `URLSession`。

---

## 卸载

```bash
rm -rf /Applications/HearMe.app
rm -rf ~/Library/Application\ Support/HearMe   # 会议记录也一起删
```

---

## 遇到问题

**Q: 提示"无法打开，因为 Apple 无法检查其是否包含恶意软件"**
→ 用 `xattr -cr`，或右键打开

**Q: 授权列表里找不到「合秘」**
→ 先打开一次 App（它会主动请求权限），再去设置里找

**Q: 抓不到会议声音**
→ 检查是否戴了耳机（系统声音从耳机走时，某些配置下抓不到）；确认会议软件在播放声音

**Q: 字幕有错字**
→ 这是 Apple 离线模型的局限。散会后用「Whisper 精修」可以大幅改善（需要自己装 Python 环境，见 README）

---

## 自己编译（不用下载）

如果你不信任预编译的包，完全可以自己构建：

```bash
git clone git@github.com:velosovittoria545-oss/HearMe.git
cd HearMe
./build.sh
open .build/HearMe.app
```

只需要 Xcode Command Line Tools，**不需要完整 Xcode**，也没有任何第三方依赖。
