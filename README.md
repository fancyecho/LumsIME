<div align="center">

# Luma 拼音

**一个安静、精致的 macOS 拼音输入法**
**A quiet, refined pinyin input method for macOS**

[中文](#中文) · [English](#english)

<img src="docs/images/lumen-dark.png" width="720" alt="Luma · 光 Lumen">

</div>

---

## 中文

Luma 基于 [librime](https://github.com/rime/librime) 引擎与 [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice) 词库，界面用 SwiftUI 重新设计：候选栏上方显示带声调的拼音，选中项平滑滑动，翻页、出现与消失都有细致的动效，并完整适配深色与浅色模式。

### 三套主题

| | 深色 | 浅色 |
|---|---|---|
| **墨 Ink**：宋体、暖纸色，朱红校对线标记选中词 | <img src="docs/images/ink-dark.png" width="360"> | <img src="docs/images/ink-light.png" width="360"> |
| **光 Lumen**：Liquid Glass 玻璃材质，选中项像一枚透镜 | <img src="docs/images/lumen-dark.png" width="360"> | <img src="docs/images/lumen-light.png" width="360"> |
| **刻 Precision**：等宽字体、键帽序号、位置计数，工具感 | <img src="docs/images/precision-dark.png" width="360"> | <img src="docs/images/precision-light.png" width="360"> |

切换主题：切换到 Luma 后，点击菜单栏的输入法图标 → 「主题」。

### 系统要求

- macOS 14 Sonoma 或更新版本（Liquid Glass 效果需要 macOS 26）
- Apple 芯片或 Intel Mac 均可

### 安装

**方法一：一行命令（推荐）**

打开「终端」，粘贴并回车：

```bash
curl -fsSL https://raw.githubusercontent.com/fancyecho/LumsIME/main/scripts/get.sh | zsh
```

**方法二：手动下载**

1. 在 [Releases](https://github.com/fancyecho/LumsIME/releases/latest) 下载 `LumaIME.zip` 并解压。
2. 把 `LumaIME.app` 移到 `~/Library/Input Methods/`（在访达中按 ⇧⌘G 输入该路径）。
3. 由于应用未经 Apple 公证，需要在终端执行一次：
   ```bash
   xattr -dr com.apple.quarantine ~/Library/Input\ Methods/LumaIME.app
   ```
4. 注销并重新登录（或重启）。

**启用输入法**

系统设置 → 键盘 → 文本输入 → 编辑… → 左下角 ＋ → 简体中文 → **Luma 拼音** → 添加。

> 手动安装后首次使用需要约半分钟编译词库，期间暂时没有候选。如果切换到 Luma 后完全没有反应，请注销再登录一次。

### 使用

| 按键 | 作用 |
|---|---|
| 空格 / 1–7 | 上屏候选 |
| ← → | 移动选中项 |
| `-` `=` 或 ⇞ ⇟ | 翻页 |
| Shift | 中 / 英切换（正在输入的拼音会直接上屏为英文） |
| Esc | 取消输入 |
| 鼠标点击 | 选择候选 |

菜单栏输入法菜单还提供：**重新部署**（修改配置后生效）、**打开配置目录**、**项目主页**。

### 自定义

配置与用户词库在 `~/Library/Luma/`。例如修改 `default.custom.yaml` 调整每页候选数：

```yaml
patch:
  schema_list:
    - schema: rime_ice
  menu/page_size: 7
```

保存后在菜单中选择「重新部署」。更多选项可参考 [雾凇拼音文档](https://dvel.me/posts/rime-ice/) 与 [Rime 定制指南](https://github.com/rime/home/wiki/CustomizationGuide)。

### 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/fancyecho/LumsIME/main/scripts/uninstall.sh | zsh
```

然后在「系统设置 → 键盘 → 文本输入」中移除 Luma 拼音。个人词库会保留在 `~/Library/Luma`；把命令末尾的 `zsh` 换成 `zsh -s -- --purge` 可一并删除。

### 从源码构建

只需要 Xcode Command Line Tools（`xcode-select --install`）：

```bash
git clone https://github.com/fancyecho/LumsIME.git && cd LumsIME
./scripts/build.sh      # 构建 build/LumaIME.app（Universal）
./scripts/install.sh    # 安装到 ~/Library/Input Methods 并编译词库
```

不安装也能预览界面：

```bash
build/LumaIME.app/Contents/MacOS/LumaIME --playground --theme ink   # 可直接打字的窗口
build/LumaIME.app/Contents/MacOS/LumaIME --demo                      # 自动演示
```

---

## English

Luma is built on the [librime](https://github.com/rime/librime) engine with the [rime-ice](https://github.com/iDvel/rime-ice) dictionaries, wrapped in a SwiftUI interface designed from scratch: tone-marked pinyin above the candidates, a selection that glides between words, considered motion for paging and appearing, and careful dark and light variants.

### Three themes

| | Dark | Light |
|---|---|---|
| **墨 Ink**: Songti type on warm paper, a vermilion proofreader's rule under the chosen word | <img src="docs/images/ink-dark.png" width="360"> | <img src="docs/images/ink-light.png" width="360"> |
| **光 Lumen**: Liquid Glass, with the selection as a lens of light | <img src="docs/images/lumen-dark.png" width="360"> | <img src="docs/images/lumen-light.png" width="360"> |
| **刻 Precision**: monospaced, keycap labels and a position counter, tool-like | <img src="docs/images/precision-dark.png" width="360"> | <img src="docs/images/precision-light.png" width="360"> |

To switch themes, select Luma, then open the input menu in the menu bar → 主题 (Theme).

### Requirements

- macOS 14 Sonoma or later (Liquid Glass needs macOS 26)
- Apple silicon or Intel

### Install

**Option 1: one command (recommended)**

Open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/fancyecho/LumsIME/main/scripts/get.sh | zsh
```

**Option 2: manual download**

1. Download `LumaIME.zip` from [Releases](https://github.com/fancyecho/LumsIME/releases/latest) and unzip it.
2. Move `LumaIME.app` into `~/Library/Input Methods/` (in Finder, press ⇧⌘G and paste the path).
3. The app isn't notarized by Apple, so run this once in Terminal:
   ```bash
   xattr -dr com.apple.quarantine ~/Library/Input\ Methods/LumaIME.app
   ```
4. Log out and back in (or restart).

**Turn it on**

System Settings → Keyboard → Text Input → Edit… → ＋ (bottom left) → Chinese, Simplified → **Luma 拼音** → Add.

> After a manual install, the first use spends about half a minute compiling dictionaries, so candidates may not appear right away. If switching to Luma does nothing at all, log out and back in once.

### Usage

| Key | Action |
|---|---|
| Space / 1–7 | Commit a candidate |
| ← → | Move the selection |
| `-` `=` or Page Up / Down | Change page |
| Shift | Toggle Chinese / English (pending pinyin is committed as typed) |
| Esc | Cancel |
| Click | Pick a candidate |

The input menu also has **重新部署 Redeploy** (apply config changes), **打开配置目录 Open Config Folder** and **项目主页 Homepage**.

### Customize

Config and your learned words live in `~/Library/Luma/`. For example, edit `default.custom.yaml` to change the page size:

```yaml
patch:
  schema_list:
    - schema: rime_ice
  menu/page_size: 7
```

Then choose Redeploy from the menu. See the [rime-ice docs](https://dvel.me/posts/rime-ice/) and the [Rime customization guide](https://github.com/rime/home/wiki/CustomizationGuide) for more.

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/fancyecho/LumsIME/main/scripts/uninstall.sh | zsh
```

Then remove Luma 拼音 under System Settings → Keyboard → Text Input. Your words in `~/Library/Luma` are kept; replace the trailing `zsh` with `zsh -s -- --purge` to remove them too.

### Build from source

Only the Xcode Command Line Tools are needed (`xcode-select --install`):

```bash
git clone https://github.com/fancyecho/LumsIME.git && cd LumsIME
./scripts/build.sh      # → build/LumaIME.app (universal)
./scripts/install.sh    # installs to ~/Library/Input Methods and compiles dictionaries
```

Preview the UI without installing:

```bash
build/LumaIME.app/Contents/MacOS/LumaIME --playground --theme ink   # a window you can type into
build/LumaIME.app/Contents/MacOS/LumaIME --demo                      # an automatic demo
```

| Path | Purpose |
|---|---|
| `Sources/Rime.swift` | librime C API wrapper, data directories |
| `Sources/InputEngine.swift` | Per-session logic: keys → commit / marked text / candidates |
| `Sources/InputController.swift` | `IMKInputController` bridge and input menu |
| `Sources/CandidatePanel.swift` | Floating panel, the three themes and their motion |
| `Sources/Settings.swift` | Theme setting, tone-marked pinyin header |
| `Sources/Playground.swift` | Standalone preview window |
| `design/` | HTML design comps |

---

## License · 许可

Luma is released under the [GNU GPL v3](LICENSE), matching the bundled rime-ice dictionaries.
Bundled components: [librime](https://github.com/rime/librime), [librime-lua](https://github.com/hchunhui/librime-lua), [librime-octagram](https://github.com/lotem/librime-octagram), [librime-predict](https://github.com/rime/librime-predict) (BSD-3-Clause, see `vendor/librime/licenses/`), and [rime-ice](https://github.com/iDvel/rime-ice) (GPL-3.0).

本项目以 GPL v3 发布。感谢 Rime 与雾凇拼音的作者们。
