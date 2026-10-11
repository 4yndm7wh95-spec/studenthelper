# 一步 · StudentHelper

从大学作业里边做边学。老师一次只讲一个小步骤，同一个聊天可以连续问多道题。

网页：左侧课程和会话，右侧对话、记录、资料。本轮原生版仅针对 iPad：SwiftUI，iPadOS 17+。默认进入手写笔记本工作区，支持 PencilKit 笔迹、纸张、图片与笔记助手。视觉延续现有“作业本”方案。

iPad 功能与架构见 [笔记本说明](docs/IPAD-NOTEBOOK.md)。

## 使用

网页和教学后端：设置服务端环境变量 `DEEPSEEK_API_KEY`，运行 `node prototype/api-server.cjs`，打开 `http://127.0.0.1:4174`。

iPhone 客户端连接同一后端。在 App 的设置页填写 HTTPS 服务或受信任局域网地址；没有密钥放在客户端。电脑默认只监听本机，需要手机连接时，显式将 `STUDENT_HOST` 设置为电脑局域网 IP。

## iOS 构建

Actions 的 **Build iPad IPA** 工作流仅编译 iPad 版本，在 iPad 模拟器执行测试并截图，生成 `StudentHelper-unsigned.ipa`。结果位于 workflow artifacts。未签名 IPA 需要侧载工具签名后安装。

源码和构建说明见 [ios/README.md](ios/README.md)。

## 当前功能边界

课程、聊天、草稿、实际疑问、文件名各自在设备本地保存；真实教学接入 DeepSeek。第 24 题提供完整演示记录，答案默认折叠。复习结果为用户自评。

通用自动题目整理、文件内容解析、账号与跨设备云同步尚未实现。文件仅保存名称，不上传或读取。后端目前用于本机或受信任开发网络，公开部署前需要认证。
