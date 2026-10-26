<div align="center">

<img src="assets/app_icon.png" width="96" alt="Plana App for Windows">

# Plana App for Windows

**面向 Windows 的 AI 绘图工作台**

提示词、画布、图库与 AI 助手，在一个桌面窗口中完成。

[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Windows](https://img.shields.io/badge/Windows-x64-3572A5)](#界面预览)
[![Status](https://img.shields.io/badge/状态-桌面版测试中-6A5ACD)](#项目状态)
[![Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B?logo=flutter&logoColor=white)](https://flutter.dev)

[本次更新](#本次更新windows47--windows55) · [界面预览](#界面预览) · [桌面版亮点](#桌面版亮点) · [贡献者](#贡献者) · [问题反馈](https://github.com/LingXia979/Plana-App-for-windows/issues) · [上游项目](https://github.com/mc5024/Plana-App)

</div>

## 项目状态

本项目基于 [Plana App](https://github.com/mc5024/Plana-App) 开发 Windows 桌面适配，并选择性同步 [shenghuo2/Plana-App-Desktop](https://github.com/shenghuo2/Plana-App-Desktop) 的桌面功能与修复。
当前版本为 **1.1.1-windows.55（构建 74）**。本分支提供对应的 Windows 桌面源码，安装包与便携版见 [Releases](https://github.com/LingXia979/Plana-App-for-windows/releases/tag/v1.1.1-windows.55)。

- `main` 与 `Plana-app-for-windows`：本次发布同步更新的 Windows 桌面源码；版本对应源码以 Release 标签为准。
- [`plana-app-gallery-optimization`](https://github.com/LingXia979/Plana-App-for-windows/tree/plana-app-gallery-optimization)：图库优化分支。
- Android 原版介绍与下载请前往[上游仓库](https://github.com/mc5024/Plana-App)。

## 本次更新：windows.47 → windows.55

本次将此前分批完成的改动合并发布。更详细的版本记录见 [Windows 使用说明](WINDOWS-README.md#版本改动) 与 [发布说明](https://github.com/LingXia979/Plana-App-for-windows/releases/tag/v1.1.1-windows.55)。

| 范围 | 更新内容 |
| --- | --- |
| 多画布与草稿 | 新建、复制、排序和删除后撤销；各画布分别保存提示词、角色、预设与生成参数，旧工作台自动迁移，后台生成与助手导入保持来源画布 |
| 画布标签 | 按住直接拖动、右键菜单、F2 原位全选改名；加号直接新建，Ctrl+Shift+N 新建、Ctrl+D 删除，× 关闭前确认；默认画布禁止改名和删除 |
| 提示词分区与编辑 | 分区排序、多选合并、启停和保存到灵感库；正负草稿、折叠关联、标签收藏与大屏编辑；分区及角色单击名称原位改名 |
| 卡片鼠标操作 | 移除独立手柄和折叠箭头，顶部空白单击折叠、按住移动立即排序；拖到侧栏边缘连续滚动，主提示词和角色分别限在本组首尾 |
| 角色头像与布局 | 删除重复选库按钮，头像顶部裁剪，左键选角色库、右键查看原图；按当前最长显示名称安排卡头，超过 10 个可见字符省略，编辑保留完整原名 |
| 助手与账号 | 免费模型标记、最多 200 轮上下文、规则全文编辑和 OC 占位符；账号可分别参与免费／点数生成，改进排队取消、调度及费用记录 |
| 桌面与稳定性 | 80%–140% 字号、导航布局、图片复制与导入窗口超分、重绘滚轮缩放；改进图片资源释放、导出与存档恢复，正常退出等待草稿写完 |

继续保留 Windows 的 Medium／High 档位、加密凭据、原生剪贴板、安装身份及作品目录。此轮同步以 Desktop 提交 [`64559c7`](https://github.com/shenghuo2/Plana-App-Desktop/commit/64559c7b14419b4f13d37fab0579cb22965132c5) 为基线；其后的桌面版改动另行评估。

验证：2,314 项完整回归通过，1 项因缺少可选评测数据跳过；静态分析、Windows 构建、安装／覆盖升级／卸载、正常保存退出和重启验证通过。

## 下载与安装

- [中文安装包（Windows x64）](https://github.com/LingXia979/Plana-App-for-windows/releases/download/v1.1.1-windows.55/Plana-Windows-1.1.1-windows.55-x64-setup.exe)：按中文向导选择安装目录，支持开始菜单、可选桌面快捷方式及卸载。
- [便携版 ZIP](https://github.com/LingXia979/Plana-App-for-windows/releases/download/v1.1.1-windows.55/Plana-Windows-1.1.1-windows.55-x64.zip)：完整解压后运行 `plana_app_for_windows.exe`。
- [SHA-256 校验清单](https://github.com/LingXia979/Plana-App-for-windows/releases/download/v1.1.1-windows.55/Plana-Windows-1.1.1-windows.55-x64-SHA256.txt)。

升级前请关闭旧版。作品自动保存到程序旁的 `output` 文件夹，卸载保留个人数据。发布包不附带个人账号、API/Bot/Web 授权、提示词草稿或私人 tag 库，首次使用请自行配置。当前安装包未进行代码签名。

开发与打包说明见 [Windows 使用说明](WINDOWS-README.md)。

## 界面预览

以下截图展示 Windows 工作台的主要布局，使用隔离的示例图库与演示对话。截图来自较早测试版，最新多画布与卡片鼠标操作以上方更新说明为准。

### 创作工作台

左侧编辑提示词与生成参数，中间查看画布与历史，右侧随时使用 AI 助手或灵感库。

![Windows 创作工作台：提示词、画布与助手同屏](screenshots/windows/workspace.png)

### 图库与作品详情

按图库整理作品，结合日期、模型与收藏筛选；打开大图即可查看尺寸、种子和完整提示词。

![Windows 图库：大图预览与作品信息](screenshots/windows/gallery.png)

### AI 助手

在独立页面中整理绘图想法、管理会话，将生成的提示词导入创作页；支持多图附件、历史选图和粘贴图片。侧栏与独立页面的生成图均可单击放大查看，支持缩放、拖动和 Esc 关闭。

![Windows AI 助手：会话列表、演示对话与提示词提案](screenshots/windows/assistant.png)

## 桌面版亮点

以下功能包含 windows.55 的桌面改进。

- **桌面工作台**：可调整侧栏宽度，提示词、画布与助手同屏；支持鼠标、键盘、文件拖入和快捷粘贴图片，图片按鼠标所在区域导入。
- **V5 Full 生成档位**：Medium／High 快捷切换；Medium 固定 14 步，切回 High 恢复原采样参数和负面草稿。档位保存、费用计算、图片导入与重新生成同步支持。
- **循环生成**：在创作页连续生成并查看进度与结果；中途手动切页不会被后续任务打断。
- **多画布与提示词**：独立保存画布草稿与参数，分区排序、多选合并、启停与大屏编辑；文本／标签视图切换，正负折叠联动，快捷小窗管理预设。
- **图库管理**：自建图库、日期筛选、收藏、多选与批量导出；一次复制到多个图库，每份副本独立保存。
- **AI 助手**：一次附加多张图片，从历史选择图片，拖入或粘贴到助手区域即可加入附件；支持会话管理、消息编辑及生成图原图预览。
- **参考与画布**：Vibe／角色参考单击立即切换、双击放大；图生图放大与超分辨率提供独立入口。
- **本地作品**：自动保存到程序根目录的 `output` 文件夹；创作历史、图库与生成参数可继续使用。

## 账号与使用

绘图需使用者自行配置 NovelAI 等相应服务；AI 助手需自行配置可用接口或相应服务授权。
测试包不附带开发者的 API 密钥、Web／Bot 授权、会话 Cookie 或个人图库。

## 反馈与上游

Windows 版的问题与建议请提交到[本仓库 Issues](https://github.com/LingXia979/Plana-App-for-windows/issues)，并注明版本、复现步骤及相关截图。

本项目保留上游的开源许可与第三方声明。原版功能、Android 构建说明及原作者维护的版本见 [mc5024/Plana-App](https://github.com/mc5024/Plana-App)。

## 来源与致谢

- [mc5024/Plana-App](https://github.com/mc5024/Plana-App)：原版应用与 Android 上游，提供核心绘图、提示词、图库及助手基础。
- [shenghuo2/Plana-App-Desktop](https://github.com/shenghuo2/Plana-App-Desktop)：在本项目 Windows 重构版上继续开发的桌面项目；本次选择性同步其多画布、提示词分区、编辑器、助手、账号调度和稳定性改进，并适配本分支的 Windows 操作习惯。
- [LingXia979/Plana-App-for-windows](https://github.com/LingXia979/Plana-App-for-windows)：Windows 桌面重构、图库改进、本地交互整合与 Windows 安装包维护。

下方保留数据、模型及开源库的来源；随包分发内容的许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。

## 贡献者

感谢原项目、桌面衍生项目及本分支的贡献。这里同时列出上游历史中记录的 AI 编程辅助署名。

| 贡献者 | 贡献与来源 |
| --- | --- |
| <a href="https://github.com/mc5024"><img src="https://avatars.githubusercontent.com/u/79186657?v=4" width="48" alt="mc5024 的头像"></a> [mc5024 · Sora Light](https://github.com/mc5024) | 原版 Plana App 作者与核心功能维护 |
| <a href="https://github.com/claude"><img src="https://avatars.githubusercontent.com/u/81847?v=4" width="48" alt="Claude 的头像"></a> [claude · Claude](https://github.com/claude) | AI 编程辅助；沿用上游历史提交中的 Claude 协作署名 |
| <a href="https://github.com/shenghuo2"><img src="https://avatars.githubusercontent.com/u/69127301?v=4" width="48" alt="shenghuo2 的头像"></a> [shenghuo2](https://github.com/shenghuo2) | Desktop 衍生项目的桌面功能、交互与稳定性改进 |
| <a href="https://github.com/LingXia979"><img src="https://avatars.githubusercontent.com/u/218984904?v=4" width="48" alt="LingXia979 的头像"></a> [LingXia979](https://github.com/LingXia979) | Windows 重构、图库优化、功能整合与发布维护 |

提交历史保留原作者及已有共同作者署名；GitHub 侧栏的 Contributors 由平台按提交记录统计，可能与这里列出的项目贡献范围不同。

## 数据与开源组件致谢

### 数据与上游

| 来源 | 用途 |
|---|---|
| [Danbooru](https://danbooru.donmai.us/) | 标签体系与别名数据 |
| [Auto-NovelAI-Refactor](https://github.com/zhulinyv/Auto-NovelAI-Refactor) · zhulinyv | 离线补全词库(`assets/danbooru.tsv`,随包分发)的标签表、热度、类目与中文译名,取自其 `danbooru_tags_full_zh.csv`(GPL-3.0) |
| [DanbooruSearchOnline](https://github.com/SuzumiyaAkizuki/DanbooruSearchOnline) · SuzumiyaAkizuki | 增强补全的在线中文搜词、译名与一句话简介 |
| [quicktagcloud](https://novelai.quicktagcloud.com/) | 法典图鉴的全部数据(词条 / 画师串 / 合集 / 例图)。只读接入,数据不随包分发,本应用不修改也不发布法典内容,所有内容归原作者所有 |
| [@huggingface/tokenizers](https://github.com/huggingface/tokenizers) | T5 分词器移植的参照实现 |
| [anime_censor_detection](https://huggingface.co/deepghs/anime_censor_detection) · deepghs | 自动打码的检测模型(`assets/models/censor_n.ort`,随包分发),即其 `censor_detect_v1.0_n`,本项目只做了格式转换与量化(MIT) |
| [NovelAI](https://novelai.net/) · Anlatan | 图像生成服务本身 |

第三方内容的版权归其各自作者所有;其中随包分发的部分(标签库、T5 词表、打码模型)见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),其余仅作运行时索引与调用。

### 开源库

由 [Flutter](https://flutter.dev)(BSD-3-Clause,© The Flutter Authors)构建,并使用:

- **状态与界面** — [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) ·
  [animations](https://pub.dev/packages/animations) ·
  [material_color_utilities](https://pub.dev/packages/material_color_utilities)
- **网络与编解码** — [http](https://pub.dev/packages/http) ·
  [archive](https://pub.dev/packages/archive) ·
  [msgpack_dart](https://pub.dev/packages/msgpack_dart) ·
  [image](https://pub.dev/packages/image) ·
  [crypto](https://pub.dev/packages/crypto) ·
  [cryptography](https://pub.dev/packages/cryptography)(Blake2b + Argon2id,账号密码登录靠它) ·
  [unorm_dart](https://pub.dev/packages/unorm_dart)
- **平台能力** — [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) ·
  [photo_manager](https://pub.dev/packages/photo_manager) ·
  [photo_manager_image_provider](https://pub.dev/packages/photo_manager_image_provider) ·
  [path_provider](https://pub.dev/packages/path_provider) ·
  [gal](https://pub.dev/packages/gal) ·
  [file_picker](https://pub.dev/packages/file_picker) ·
  [url_launcher](https://pub.dev/packages/url_launcher) ·
  [share_plus](https://pub.dev/packages/share_plus)
- **构建期** — [flutter_lints](https://pub.dev/packages/flutter_lints) ·
  [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons)

以上均为宽松许可(BSD / MIT / Apache-2.0),逐包清单见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md);应用内「关于 → 开源许可」亦有完整入口。

## 许可

Copyright (C) 2026 Sora_Light

本项目以 GPL-3.0 发布,全文见 [LICENSE](LICENSE)。分发修改版(含打包为安装包或便携包分发)
须同样以 GPL-3.0 开源;本程序不作任何担保。

第三方内容不在本许可范围内,版权归各自作者所有,详见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 免责声明

本项目为非官方的第三方客户端,与 NovelAI (Anlatan) 无关联。用户需自行遵守
NovelAI 的服务条款。因使用本应用导致的账号问题、内容问题及任何其他后果,
均由用户自行承担。
