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

微信的真实聊天窗口不采用自动化界面控制测试：部分界面在控制过程中出现过窗口异常。自动检查使用独立测试程序；真实微信兼容性由用户在“文件传输助手”的未发送草稿中手动验证。不要向联系人发送测试消息，也不要把独立规则测试通过写成微信实机验证通过。

0.4.5 的微信兼容路径针对未暴露焦点和输入区的活动窗口，受通用兼容开关控制。回填前需核对当前行、末尾触发空格及单字符选区；无法确认时保留原文。取词失败也会生成仅含数值和固定原因类别的本地诊断，不记录窗口标题、聊天正文或剪贴板内容。

0.4.5 发布前，156 项规则与组件测试通过，用户另行手动确认了微信输入替换可用。此结果不代表所有微信版本或其他聊天客户端均已验证。

0.4.6 将首次设置记录与当前权限状态分开：已完成或暂缓过引导的安装，仍会按实际辅助功能及监听状态进入权限恢复；暂缓只抑制本次运行中同一次权限异常的重复弹窗。权限恢复检查不依赖钥匙串读取完成，登录启动也会显示需要处理的恢复页。相关测试覆盖连续重装、正常升级、暂停文字功能、运行时撤权、暂缓与恢复完成；全套 164 项规则与组件测试通过。

文字权限与钥匙串读取分别检查；即使升级后钥匙串正在等待系统确认，权限恢复页仍可先显示。钥匙串访问失败时，用户可在“模型与 API”点击“解锁 / 重试”。系统的钥匙串验证由用户完成，不变更原有密钥或访问列表。

0.4.7 增加 Word 文档画布兼容：仅对 Word 的正文画布或文本区检查编辑菜单的 `paste:` 状态，在选区建立后检查 `cut:` 状态，不调用剪切命令。复制、焦点、单字符光标探测、回填前原文与回填后文字样式均需核对。段落快捷键依据 [Microsoft Word 快捷键说明](https://support.microsoft.com/en-us/accessibility/word/keyboard-shortcuts-in-word)，手动换行之后的子范围以有界光标调整并重新复制确认，不使用全选。复制、粘贴期间使用既有输入保护和剪贴板恢复机制，不新增后台轮询或系统权限。

本轮 172 项规则与组件测试通过，新增用例覆盖 Word 画布编辑能力、画布初始化前后的范围一致性、只读及受保护状态、硬回车、手动换行、Unicode 范围和光标调整上限。开发机 Word 显示未激活且仅查看，因此未执行可编辑 Word 的实际回填测试；应由用户在已激活的 Word 中手动验证，不能将组件测试写成 Word 实机通过。

0.4.8 根据用户的状态报告修正 Word 误拦截：0.4.7 在已确认正文类型、非弹窗且可手动编辑的情况下，因画布 `AXEnabled=false` 提前退出。画布的 `AXEnabled`、`AXEditable` 现在只作为诊断信息，正文身份检查、粘贴命令、建立选区后的编辑命令及回填前检查继续保留。错误提示区分焦点、粘贴状态和选区状态，不根据画布属性断言文档未激活或只读。

常规设置可复制最近一次失败的兼容性诊断。导出时只解码并重编码既有数值报告结构，未知字段不会导出；无报告、损坏或超大文件均有单独处理。相关测试覆盖用户报告的画布状态组合与诊断导出，不调用真实 API。

0.4.9 将 Word 的命令核验封装为 `MicrosoftText`，增加 Microsoft PowerPoint（`com.microsoft.Powerpoint`）文字画布路径。PowerPoint 使用 **Option+Shift+Up** 选择光标前当前段落；不能复用 Word 的 Command+Shift+Up，后者在 PowerPoint 中选到文字对象起点。依据 [微软 PowerPoint macOS 快捷键说明](https://support.microsoft.com/en-us/accessibility/powerpoint/use-keyboard-shortcuts-to-create-powerpoint-presentations)。沿用换行后缀缩选、精确复读、单字符光标核验、触发空格、字号和粗细检查及回填前的粘贴命令检查。

PowerPoint 在发送任何选区方向键前，还要求初始 Copy、Cut 命令均明确禁用，拒绝已选中对象或不明命令状态；对象选中时的 Shift+方向键会调整对象尺寸，不能用于文字探测。随后建立的文字选区必须可复制且可编辑，并核对触发空格和字体。普通工具栏文本框保留通用路径，WPS、Excel、Keynote 不扩大范围。诊断增加应用类别和焦点能力数值及具体失败阶段，不记录标题或文字。本机 PowerPoint 未激活，只检查了只读画布与菜单命令接口，未将其记为可编辑 PowerPoint 实机通过。

0.4.10 在已激活的 Office 16.101 中使用独立临时文档实测：Word 普通段落及手动换行后的替换和撤销；PowerPoint 末段及中间段落替换、字号保留与撤销；Excel 单元格内和编辑栏的文字替换及撤销。三款应用均验证了固定选中文字的读取。PPT 对象选中状态、Excel 网格和公式编辑状态被阻止；Excel 保存后逐项比较了六个单元格、公式及 18 号粗体样式。

本轮修正复制格式的 CR/LF/CRLF、手动换行表示差异及附加段落标记。Word 核对并去掉真实选区中多出的段落标记；PowerPoint 在有后段时使用有界键盘重建选区，避免依赖其不可靠的 AX 选区写入。PPT 使用纯文本继承样式，连续空格以等量不换行空格保留，避免 RTF 插入额外段落及纯文本压缩空格。Excel 只在确认 Enter/Cancel 编辑按钮可用且文字焦点与编辑栏内容和光标一致时采用兼容路径；不提交单元格，不翻译公式。

`--microsoft-office-read-test`、`--microsoft-office-selection-test`、`--microsoft-office-smoke-test` 只接受当前活动 Office 中名称以 `TranslateBar-MS-Test-` 开头的临时文档。固定测试句与译文见 `MicrosoftOfficeSmokeTest.swift`；这些模式不读取 API Key、不调用 API。测试前先退出常驻 TranslateBar，使用菜单“打开方式”在对应 Office 中打开临时文件并进入文字编辑状态。自动化发送的按键不能作为实体键盘空格手势已经通过的证据。

测试报告位于 `.build/office-live-reports/`，仅用于本机调试，不提交仓库。固定译文测试验证生产取词、回填、撤销及周围文字；PPT 的空格种类可变化，数量必须一致。复杂富文本、表格结构、受保护内容和不同版本仍需各自验证，不能由本轮结果推断所有 Office 内容都兼容。

## 数据与密钥

正常应用从钥匙串读取用户在设置中保存的 Key，不读取项目 `.env`，不依赖开发机绝对路径。源码仍保留显式的旧项目密钥迁移命令，供已有开发配置手动迁移；普通用户无需使用。

运行数据在 `~/Library/Application Support/TranslateBar/`，源码仓库中不应包含这些文件、录音、截图或调用日志。`.env`、构建输出及签名材料由 `.gitignore` 排除。分享诊断时也应先检查内容。

## 签名

`TRANSLATEBAR_SIGN_ID` 可以指定本机签名身份；设为 `-` 则使用临时签名。签名私钥和公证凭据由各自开发者保管，不进入仓库。构建脚本未自动执行 Apple 公证。当前 GitHub 下载包采用临时签名，不使用发布者的实名 Developer ID 证书，也不提交 Apple 公证。

公开临时签名包使用独立脚本，从编译产物新建应用，移除调试信息及原始签名，再临时签名，避免从本机开发签名应用中复制残留信息。输出目录内已有同名 App 时会停止：

```sh
zsh scripts/build_public.sh /path/to/empty-public-output
```

可用以下命令将已经构建的应用打包为 DMG，包含应用程序文件夹快捷方式、安装说明和 MIT 许可证：

```sh
zsh scripts/build_dmg.sh /path/to/TranslateBar.app /path/to/output-directory
```

打包不会改变输入应用的签名，也不会自动进行签名或公证。如需自行制作 Developer ID 发行包，可以用自己的证书签名、公证并附加公证票据。最终校验值应在所有打包、签名操作结束后生成。DMG 的构建输出不应提交到 Git 源码历史。

这是按需维护的个人项目。修改完成后跑相关测试，欢迎提交可复现的问题或小范围 PR。
