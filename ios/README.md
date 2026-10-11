# 一步 · iPad 原生客户端

SwiftUI + PencilKit，iPadOS 17+。0.5.0（10）仅构建 iPad 安装包，暂不开发 iPhone 版。笔记本是默认工作区，保留原有教题、课程、记录、文件和复习功能。样式直接沿用当前“作业本”主题。

功能、数据结构、AI 范围和保存策略见 [iPad 笔记本说明](../docs/IPAD-NOTEBOOK.md)。

## 使用笔记本

新建笔记本后用 Apple Pencil 直接书写。工具支持钢笔、荧光笔、整笔/局部擦除、套索、颜色、粗细、撤销和重做。双指移动或缩放纸张，选项中可以打开手指书写。页面支持空白、横线、方格、点阵以及创建、重命名、排序、删除。

从照片或文件插入图片后，使用套索模式的手指操作来移动、调整大小或删除。笔迹与图片分别保存，互不扁平化。所有修改自动保存；保存失败会保留本次未保存笔迹并显示重试入口。

## 配置模型

书架设置或笔记助手的模型设置中，填写 API Key、保存并测试连接。默认 `https://api.deepseek.com`、`deepseek-flash`，直接请求模型。可在高级设置换成兼容服务的 HTTPS 地址和模型名。

密钥按服务地址分别保存到 Security Keychain，不进入偏好、聊天文件、截图或构建产物。构建不含真实密钥。

笔记助手当前支持直接连接模式，模型需支持工具调用。发送页面图片需支持图片输入的模型；默认只发送本机识别文字和页面对象资料。手写公式的识别可能不完整。助手只能访问当前笔记本，编辑建议需点击“应用修改”才保存。

原有教学的自建服务连接仍保留在高级设置中；该教学服务尚未实现笔记工具接口。

## 构建

macOS 安装 Xcode 16.4 与 XcodeGen，在本目录执行：

```sh
xcodegen generate
xcodebuild -project StudentHelper.xcodeproj -scheme StudentHelper -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
bash ci/capture-ipad.sh
```

GitHub 的 `../.github/workflows/ios-ipa.yml`（Build iPad IPA）执行模拟器编译、iPad 单元和界面测试、截图，再编译真机并输出 `StudentHelper-unsigned.ipa`。打包校验要求设备家族为 `{2}`。未签名 IPA 需要原有侧载工具签名后安装。

Windows 的 `verify-source.py` 只做 Swift 语法与工程资源检查，不能代替原生编译。

## 当前边界

笔记、聊天分别本地保存，没有账号和跨设备同步。笔记助手为 App 内工具调用接口，没有对外开放 MCP 服务；关键词检索分批识别页面，尚无完整语义索引。纸张为独立 A4 页面，通过页面条和翻页按钮切换。

Pencil 压感、延迟、防误触、原生套索和双指手势需要实际 iPad 验收。模拟器的手指书写测试只验证输入、保存与恢复流程。
