# 找鸭 · FindDuck

原生 macOS 文件名搜索工具，支持本地磁盘和已挂载的 SMB 共享盘。名称暂定为找鸭。

[下载最新版](https://github.com/evay-spece/FindDuck/releases/latest) · [更新说明](CHANGELOG.md) · [第三方许可](THIRD_PARTY_NOTICES.md)

## 下载安装

1. 在 Releases 下载 `FindDuck-1.1.6-macOS-arm64.zip`。
2. 解压后把“找鸭 1.1.6.app”拖入“应用程序”文件夹，可自行改名为“找鸭.app”。
3. 打开后在设置中选择搜索位置并完成所需的磁盘授权。共享盘先用 Finder 连接，再添加已挂载目录。

此版本支持 **Apple Silicon（M 系列芯片）、macOS 14 或更新版本**。Intel 版本尚未提供。

发布包使用 Apple Development 开发签名，**尚未经过 Apple 公证**；其他 Mac 可能被 Gatekeeper 阻止打开，不是已公证的正式分发包。不要关闭系统整体安全保护。

## 主要功能

- 本地索引采用 Oil Find 开源核心，首次建立文件名索引，之后用 FSEvents 增量更新并补齐历史事件。索引保存在本机。
- SMB 共享盘在客户端保存索引、分批核对目录，支持主动深度搜索。服务器无需安装组件。
- 关键词、目录范围、文件类型和标签可组合筛选；类型胶囊可拖动排序。
- 今天微信文件、今天下载、最近打开（最多50个文件，排除App）、最近5条搜索和自定义目录入口。
- 多颜色标签、自定义文字标签、独立文件备注；标签参与匹配，带标签或备注的匹配项优先。
- 黑名单目录与单文件屏蔽；本地和开发者黑名单同时生效。
- 主页常用软件、网站和个人功能，支持组内拖动；快捷文本、计算器、人民币参考汇率和世界时间换算。
- 文件名匹配高亮、简化路径与来源图标、修改时间，默认打开软件图标。复制路径仍保留真实路径。
- 火箭鸭应用图标与单色菜单栏图标；悬停浅高亮，点击使用更深的选中蓝色。

## 快捷操作

| 操作 | 快捷键 |
| --- | --- |
| 全局呼出 | Control + Space，可在设置修改 |
| 打开文件 | 回车或双击 |
| 显示所在文件夹 | Command + 回车或 Command + 双击 |
| 快速预览 | 点击/上下键选中后按空格 |
| 设置 | Command + 逗号，或菜单栏设置 |
| 逐层返回 | Esc先清关键词，再取消范围/标签筛选，最后隐藏窗口 |
| 退出进程 | Command + Q，或菜单栏退出 |

隐藏窗口后继续常驻菜单栏。输入法组字期间由输入法先处理按键。

## 使用边界

- 搜索的是文件名、路径及找鸭标签/备注，不是文件正文全文检索。
- 本地系统文件、隐藏目录及无权限内容不保证覆盖；可以在设置调整搜索位置和排除项。
- 微信/下载入口点击会补查目录；最近打开结合本机已记录的使用信息。
- SMB 的其他客户端变化可能延迟收录，不能保证每个瞬间与服务器完全一致；真实网络大目录与共享盘废纸篓仍需进一步验证。
- 标签和备注属于找鸭，不修改 Finder 标签。废纸篓不受支持时提示失败，不回退为永久删除。
- 汇率功能按点击连接 Frankfurter，显示来源及日期，为每日参考值，不是实时银行成交价。
- 深色外观尚未完成实机验收。

## 从源码构建

需要完整 Xcode 和 Swift 6 工具链、Python 3，不能只安装 Command Line Tools。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test -c release --filter 'MigrationTests|ExpandedNotesTests|RocketIconTests'
python3 build.py 'build/找鸭.app'
```

目标路径必须不存在。默认使用 ad-hoc 签名；要使用自己的证书，请先设置 `FINDDUCK_SIGN_IDENTITY` 环境变量。此脚本不会读取或提供任何私钥。

1.1.6 构建号为44。此前24项集成/图标测试通过，随后仅调整选中背景颜色；加深后的视觉效果仍待进一步试用确认。

## Oil Find 归属

本地核心来自 [Oil Find](https://github.com/oil-oil/oil-find)，保留其 MIT 许可及来源记录，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。找鸭有独立的数据目录，不依赖安装原 Oil Find 应用。
