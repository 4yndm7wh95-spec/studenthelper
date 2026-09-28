# 实施记录

方案实际请求与返回模型：`anthropic/claude-opus-5.5`，经 Ofox API，认证来自环境变量 `OFOX_API_KEY_2`。未把密钥写入文件或客户端。

- `opus-design.md`：基础视觉、tokens、左栏、聊天布局。第一次返回因长度截断。
- `opus-motion-design.md`：补齐各屏和交互动效，正常完成。
- `opus-iphone-design.md`：原生 iPhone UI 与 SwiftUI 参数，正常完成；两次较长请求网关超时后缩短重试。
- 对应 `*-response-meta.json` 保存请求模型、返回模型、完成原因和时间。

网页颜色、圆角、文字层级、尺寸、动效曲线来自这些方案，旧样式与旧动效全部退出加载。原生 iOS 使用方案指定的四个入口、NavigationStack、会话 sheet、safeAreaInset、spring 和 timingCurve。

依据现有功能作的调整：保留 JSON / localStorage 架构；回复是整段返回，不展示不存在的流式输出；没有通用自动记录或真实账号同步，因此不显示虚构的完成状态；Windows 的 Swift 语法检查不冒充 Xcode 编译。

用户追加要求覆盖原方案中“下一题”的默认规则：单题不显示；只对用户已经提供、可辨认的多题文本显示，并逐题取真实题干。增加网页会话删除；原生已有左滑删除。真实回复接入本地 KaTeX，而非只为预设示例画公式卡片。

验证原始依据：[KaTeX 渲染参数](https://katex.org/docs/options.html)、[Apple SwiftUI spring](https://developer.apple.com/documentation/SwiftUI/Animation/spring(response:dampingFraction:blendDuration:))、[Apple ATS](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)。

GitHub 私有仓库：`https://github.com/4yndm7wh95-spec/studenthelper`。第一次云构建已通过模拟器编译、iPhone16Pro 启动与截图、真机编译及 IPA 完整性验证。后续包以最新成功构建为准。IPA 未签名，需要侧载签名；尚未在用户实际 iPhone 上安装验证。
