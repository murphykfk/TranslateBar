# 开发说明

## 结构

- `Sources/TranslateCore/`：设置迁移、语言方向、文字范围、空格触发、预算与缓存等规则。
- `Sources/TranslateBar/`：SwiftUI / AppKit 界面、辅助功能取词与回填、OpenAI 客户端、系统音频捕获与播放。
- `Tests/`：规则与组件测试。
- `Tools/`、`scripts/build_*fixture.sh`：独立文本、网页和音频测试工具。
- `scripts/build.sh`：打包本地 `.app`，`make_plist.py` 保存版本与系统声明，`make_icon.swift` 生成应用图标。

项目使用 Swift Package Manager，无第三方 Swift 包依赖。最低系统版本为 macOS 14.4，Swift tools 版本为 6.0，语言模式为 Swift 5。

## 本地验证

```sh
swift test
zsh scripts/build.sh
```

`swift test` 不调用真实翻译接口，测试使用内存或临时目录中的数据；个别测试使用隔离的钥匙串测试项。全局键盘事件测试构造事件后直接交给处理器，不向操作系统发送按键。

需要检查跨应用交互时，先创建独立测试文档，避免在私人笔记、聊天输入框或正式文档中运行自动回填测试。

```sh
zsh scripts/build_fixture.sh
zsh scripts/build_compatibility_fixture.sh
open .build/CompatibilityFixture.app
```

网页示例位于 `Tools/compatibility-fixture.html` 与 `Tools/selection-fixture/`。WPS 测试文档不随仓库分发；如需调试，可自行创建名为 `TranslateBar-WPS-Test` 的临时文档，并参照 `OfficeSmokeTest.swift` 中的固定测试内容。

部分可执行文件的 `--*smoke-test` 模式会读写当前聚焦的专用测试窗口，并尝试恢复内容。与主应用共用进程锁的模式需先退出正在运行的 TranslateBar。带 `live`、`cache` 或 `keychain` 的接口验证可能连接 OpenAI，真实文字和语音调用会计入本地费用；不要把这些模式放入不经意执行的测试流程。

## 数据与密钥

正常应用从钥匙串读取用户在设置中保存的 Key，不读取项目 `.env`，不依赖开发机绝对路径。源码仍保留显式的旧项目密钥迁移命令，供已有开发配置手动迁移；普通用户无需使用。

运行数据在 `~/Library/Application Support/TranslateBar/`，源码仓库中不应包含这些文件、录音、截图或调用日志。`.env`、构建输出及签名材料由 `.gitignore` 排除。分享诊断时也应先检查内容。

## 签名

`TRANSLATEBAR_SIGN_ID` 可以指定本机签名身份；设为 `-` 则使用临时签名。签名私钥和公证凭据由各自开发者保管，不进入仓库。构建脚本未自动执行 Apple 公证；当前仓库不发布正式安装包。

这是按需维护的个人项目。修改完成后跑相关测试，欢迎提交可复现的问题或小范围 PR。
