# WeChatTweak

[![README](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak)
[![README](https://img.shields.io/badge/Telegram-black?logo=telegram&logoColor=white)](https://t.me/wechattweak)
[![README](https://img.shields.io/badge/FAQ-black?logo=googledocs&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak/wiki/FAQ)

A command-line tool for tweaking WeChat.

## 功能

- 阻止消息撤回
- 阻止自动更新
- 客户端多开

## 安装&使用

```bash
# 安装
brew install sunnyyoung/tap/wechattweak

# 更新
brew upgrade wechattweak

# 执行 Patch
wechattweak patch

# 查看所有支持的 WeChat 版本
wechattweak versions
```

## 270353 本地适配

这份源码新增的适配仅面向 **WeChat build 270353、Apple Silicon 原生 arm64**，并校验客户端核心的 Mach-O UUID；其他 build 和 Intel / Rosetta 不在本次适配范围内。

此版本保留别人撤回的原消息，自己的撤回沿用微信行为。运行时通过原生 Qt 消息视图，在文字或图片气泡右侧显示“对方尝试撤回此消息”，提示文字左侧留白 60 个逻辑像素，按账号、会话、消息 ID 保存标记，不另存消息正文。标记文件位于微信容器的 `Documents/WeChatTweak/recalled-messages.json`。文件损坏或不可写时保留原文件，继续防撤回；新增标记只保存在内存，并显示“无法持久化”。

本地配置还单独处理 `pc_forbid_screenshot` 指令：返回原生“已处理”结果，不创建禁止截图任务，避免重启后再次由该指令排除聊天窗口。该处理允许微信聊天被截图、录屏和屏幕共享捕获；相邻的其他安全指令和音频隐私路径保持原有逻辑。录屏权限仍由 macOS 管理，安装后如因重新签名而失效，需要重新授权。

使用源码编译出的 CLI、本地配置及配套运行时；Homebrew 安装的上游版本不包含这次适配。安装了完整 Xcode 时，在源码目录运行：

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build
```

构建后将 `wechattweak` 和 `libWeChatTweakRuntime.dylib` 保持在同一目录。先退出微信，再对客户端副本执行：

```bash
./wechattweak versions --app '/path/to/WeChat.app' --config ./config.json
./wechattweak patch --app '/path/to/WeChat.app' --config ./config.json
```

必须指定 `--config`，CLI 默认仍读取上游配置。微信更新会替换补丁；本次配置会拒绝 UUID 或指令不匹配的核心文件，不能将版本号改成新 build 后直接套用。本次未新增阻止自动更新或多开的补丁。

验证结果：用户在 `270353 / arm64` 验证副本确认，新的文字和图片撤回后保留原消息并即时显示标记；自己的撤回正常生效；切换会话、上下滚动后标记仍对应正确消息；重启后的历史撤回标记可见。包含截图处理的最终补丁已安装至 `/Applications/WeChat.app`，用户完成退出重开后确认 macOS 截图、微信自身截图和撤回标记均正常。`make test` 通过 20 项 XCTest、7 项 arm64 入口 ABI 检查和 2 项截图指令原生返回检查，Release 构建及严格签名校验通过。

验证期间 LLDB 曾在 `WeChatAppEx Framework` 的 `webview_io_thread` 捕获一次 `EXC_BAD_ACCESS`，解除调试后该进程退出；根因未确认。随后正常启动的副本完成了上述功能测试。本次未宣称修复这个 WebView 崩溃。

## 参考

- [微信 macOS 客户端无限多开功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-wu-xian-duo-kai-gong-neng-shi-jian/)
- [微信 macOS 客户端拦截撤回功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-lan-jie-che-hui-gong-neng-shi-jian/)
- [让微信 macOS 客户端支持 Alfred](https://blog.sunnyyoung.net/rang-wei-xin-macos-ke-hu-duan-zhi-chi-alfred/)

## 贡献者

This project exists thanks to all the people who contribute.

[![Contributors](https://contrib.rocks/image?repo=sunnyyoung/WeChatTweak)](https://github.com/sunnyyoung/WeChatTweak/graphs/contributors)

## License

The [AGPL-3.0](LICENSE).
