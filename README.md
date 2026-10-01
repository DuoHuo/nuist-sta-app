# NUIST++

面向南京信息工程大学学生的校园服务 App。

把常用的校园信息放在一个入口里：查空教室、看成绩与学业进度、查宿舍电费，
以及使用其他由社团持续共建的小程序。绑定一次统一门户后，后续可无感使用。

> **非官方项目**：由社区开发与维护

[![Flutter CI](https://github.com/DuoHuo/nuist-sta-app/actions/workflows/ci.yml/badge.svg)](https://github.com/DuoHuo/nuist-sta-app/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/DuoHuo/nuist-sta-app)](https://github.com/DuoHuo/nuist-sta-app/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/DuoHuo/nuist-sta-app/total)](https://github.com/DuoHuo/nuist-sta-app/releases)

## 你可以用它做什么

### 学习与成绩

- 查看当前学期、周次和学期进度
- 查询 GPA、已修学分、平均绩点，以及班级和专业排名
- 查看双创学分总分、评定结果和已认定项目
- 查看劳动积分总分及各分项明细

### 校园生活

- 按教学楼和日期查找空教室
- 按时段、楼层和教室类型筛选结果
- 查看宿舍电费余额和历史用量
- 支持按校区、楼栋选择宿舍

功能以小程序形式持续增加。可用功能和数据范围会随着学校业务系统及项目进度变化。

## 下载与安装

前往 **[Releases](https://github.com/DuoHuo/nuist-sta-app/releases/latest)** 下载最新 APK。

- 当前仅提供 Android `arm64-v8a` 版本
- 暂未上架应用商店，GitHub Releases 是当前主要分发渠道
- 首次安装时，Android 可能要求允许安装来自未知来源的应用

## 登录与隐私

NUIST++ 使用学校统一门户获取需要登录的数据。登录和绑定在学校自己的页面完成，
应用不会代收或上传你的密码。

- Passkey 私钥保存在设备本地安全存储中（Android Keystore / iOS Keychain）
- 项目不提供云端账号，不上传学号、Cookie、私钥或业务数据
- 除学校业务系统外，项目不新增其他网络出口
- 使用校园 VPN 的功能需要先完成统一门户绑定

## 反馈与共建

遇到问题，请先确认应用版本、设备型号、系统版本和复现步骤，再在仓库的 Issue 区反馈。
涉及学号、Cookie、私钥或成绩等敏感信息时，请务必脱敏打码，不要直接公开。

欢迎学生社团和个人贡献功能。不会 Flutter 也可以从 H5 小程序路线参与：

- [路线图](docs/roadmap.md)：查看计划中的功能和待认领事项
- [新增一个小程序](docs/mini-app-guide.md)：了解原生和 H5 接入方式
- [贡献指南](CONTRIBUTING.md)：配置开发环境、运行检查和提交代码

## 免责声明

- 本项目是学生自发开发的非官方工具，与南京信息工程大学及其任何下属部门无关
- 数据来自学校各业务系统，仅供学习交流，请勿用于商业用途
- 学校系统可能随时调整，项目不保证接口持续可用
- 使用本软件产生的任何后果由使用者自行承担

## License

To be determined.
