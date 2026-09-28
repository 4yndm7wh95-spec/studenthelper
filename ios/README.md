# 一步 · iPhone 原生客户端

SwiftUI，iOS 17+，主要尺寸 iPhone 16 Pro（402 × 874 pt）。按实际向 `anthropic/claude-opus-5.5` 咨询后返回的方案实现。完整原始设计见 `../prototype/design/opus-iphone-design.md`。

包含：课程和普通聊天、连续多题教学、完整聊天和草稿本地保存、切换会话时继续请求、停止与重发、题 24 演示记录（折叠答案、步骤、知识点、实际疑问、完整聊天）、复习作答与自评、图片资料与附件、手机直接连接模型。

0.4.0：全新安装不预置课程，从普通聊天开始。在会话页点击“＋”新建课程，课程右侧菜单可删除课程及其聊天和资料；删除前需确认，旧版预置课程也可删除。长按会话或向右滑动可重命名，手动名称不会被首次发送覆盖。已保存的课程、历史聊天和原记录保留。

聊天输入框的附件菜单支持“从相册选择”和“从文件选择”。选图后显示可预览、移除的缩略图，支持单独发图；图片保存到应用自己的 image-assets 目录，草稿和已发送图片均可在冷启动后恢复。HEIC、PNG、JPEG 等可解码图片经 ImageIO 按方向缩放并转为 JPEG，最大边2560px，压缩后单图不超过2MiB，输入文件不超过20MiB；每条消息最多4张，本次请求保留最近8张图片。模型请求通过 image_url 内容块携带实际图像数据，直连和自建服务两条路径共用编码。资料页同样支持相册、文件图片，可预览或带入对应课程聊天；移除资料时会保留聊天仍在引用的图片。

当前限制：多题图片的自动分题和通用题目自动总结尚未实现；PDF、Word等非图片资料仍只保存文件名；iOS 与网页各自在本地保存，没有登录或云同步。复习结果是学生自评。早期仅记录文件名的图片无法恢复原图，需要重新添加。IPA 不包含预置密钥，用户填写的密钥仅保存到手机钥匙串。

## 在 iPhone 配模型

打开聊天右上角的设置，在“模型”填写 DeepSeek API Key，点击“保存”，再点击“测试连接”。默认接口为 `https://api.deepseek.com`，模型为 `deepseek-flash`（V4.1 Flash），手机直接请求模型，不需要电脑运行服务。测试连接会发送一次很短的模型请求。

更换 OpenAI 兼容服务时，展开“高级设置”，填写该服务的 HTTPS 接口地址、模型名称和对应密钥。支持基础地址、`/v1` 基础路径或完整的 `/chat/completions` 地址。切换接口会清空密钥输入或读取该接口之前保存的密钥，避免把另一家服务的密钥发送过去。

密钥通过 Security Keychain 保存，采用 `WhenUnlockedThisDeviceOnly`，不进入 UserDefaults、聊天文件、导出数据、截图或构建产物。高级设置可以移除当前接口保存的密钥。接口地址和模型名称单独保存为偏好。

云端模拟器测试使用 Xcode 自动生成的 ad hoc 签名和模拟权限，并通过实际钥匙串读写测试核验。模拟器配置不会进入真机 IPA。真机需由侧载工具按用户自己的签名身份生成默认应用权限。依据 [Apple 钥匙串访问组说明](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)。

## 在 macOS / 后续 GitHub 构建

工程规格为 `project.yml`。安装 XcodeGen 后，在 `ios` 目录生成 Xcode 工程：

```sh
xcodegen generate
xcodebuild -project StudentHelper.xcodeproj -scheme StudentHelper -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

旧的自建服务路径保留在“高级设置 → 连接方式 → 自己的服务”。此模式填写 HTTPS 服务，或同一网络的 `http://192.168.x.x:4174` / `.local` 地址，不能填写手机自身的 127.0.0.1。这个模式的连接检查通过 `/api/health`。

本地后端默认只在电脑本机监听。需要手机连接时，可显式设置 `STUDENT_HOST` 为电脑的局域网 IP，再启动 `../prototype/api-server.cjs`。这只用于受信任的家庭/开发网络；当前接口没有公开部署所需的账号认证。正式使用优先配置 HTTPS 服务；局域网 HTTP 的 ATS 行为需在实际 iOS 构建中验收。

GitHub 构建配置位于 `../.github/workflows/ios-ipa.yml`，会编译模拟器和真机版本，在 iPhone 16 Pro 模拟器运行模型请求、钥匙串、图片持久化、请求编码、课程管理测试，并通过系统相册的界面测试实际选图和发送，保存聊天、模型设置、选图预览截图，输出原生代码产生的合成测试图片请求，然后生成未签名 IPA。构建不含真实密钥。未签名 IPA 需通过侧载工具签名后安装；有开发者证书时可进一步配置签名分发。

## 本次验证范围

Windows 无 Xcode / SwiftUI SDK。本地通过 Swift 语法树解析检查了所有源文件，验证了工程清单、plist 和图标资源。类型检查、模拟器启动与真机编译由 GitHub 构建执行；最终状态以对应 Actions run 为准。尚未在实际 iPhone 上验证。

后续构建验收：iPhone 16 Pro 模拟器；输入键盘不遮挡 composer；中文输入法；动态字体；VoiceOver；Reduce Motion；文件选择；HTTPS 与局域网 ATS；请求中换会话、停止、重发；冷启动恢复草稿和中断状态；独立作答与自评不误报掌握。

实现差异：保留轻量 JSON 本地数据层，未引入 SwiftData；依据当前后端返回整段回复，停止会取消整次请求，不展示不存在的流式片段；“说说你的想法”替换晦涩的输入提示；没有依赖未实现的通用自动记录显示空状态。

局域网配置依据 [Apple 的 ATS 文档](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)，仅为私有 IP 范围配置 HTTP 例外，不全局允许任意 HTTP。
