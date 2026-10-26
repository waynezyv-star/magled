# AI-CONTEXT.md — MagLED 任务记忆（AI 协作指南）

> 本文件是给 AI 助手看的任务记忆，记录本 fork 相对上游的全部改动、踩坑结论和更新流程。
> AI 修改新版本前**必读**本文，改完后请同步更新本文件。

## 项目概述

- **上游**：[shaoya828/magled](https://github.com/shaoya828/magled)（MIT），fork 自 commit `f5b7c34`（v1.1）
- **本 fork**：在 **macOS 27.2（MacBook Air M4，Mac16,12）** 上的全面兼容化修复
- **功能**：MagSafe 3 充电线指示灯控制（菜单栏 App + root 守护 + CLI）
- **原理**：SMC 键 `ACLC`（1 字节）。0x00=系统控制 0x01=关 0x03=绿 0x04=橙 0x06=慢闪 0x07=快闪 0x19=闪后关。写入需 root（守护）；灯纯装饰，不影响充电。

## 🔑 关键技术发现（改代码前必读，都是实测结论）

1. **macOS 27 上 SMC 读必须显式设置 `keyInfo.dataSize`**（`SMC.swift readByte` 已修）。
   不设置会读到 0xff 桩值或直接抛错——这曾导致"写入无效"的误判（写入其实一直有效）。
2. **macOS 27 新语义：ACLC 系统模式（0x00）的回读是"当前生效颜色"而非 0x00**（满电=0x03）。
   写 00 后回读校验不能要求等于 00，应接受任意合法值（`apply()` 与 App 的 `writeCurrent` 已修）。
3. **用户态写 SMC 被拒（错误 0x89）是设计行为**（需 root 守护），与老版本 macOS 一致，**不是**系统封锁。
   ⚠️ 网上"macOS 27 封锁第三方 SMC"的说法对 ACLC 写入不成立（BattGUI 说的封锁是充电控制，不是 LED）。
4. **install.sh 会重新 ad-hoc 签名**，导致安装后的二进制与 App 包内的字节不同——
   判断守护版本**不能整文件对比**，要用 `machCodeBody()`（跳过头部页 4KB + __LINKEDIT，只比代码/数据段）。
5. **状态图标可能不显示**：菜单栏被状态项塞满时，macOS 直接丢弃放不下的新状态项
   （用 10 行纯 AppKit 测试 App 验证过，与本项目代码无关）。退出几个状态栏 App 或重启即恢复。

## 修复清单（相对上游 f5b7c34）

| # | 文件 | 修复 | 级别 |
|---|---|---|---|
| 1 | SMC.swift:readByte | 补 `keyInfo.dataSize=1`，修复 macOS 27 读桩值 | 🔴 |
| 2 | helper:apply | v=0 回读校验改为"合法值即通过"（系统模式语义） | 🔴 |
| 3 | app:tick | 夜间防漂移：每 30 秒核对灯态，被系统重置立即重写 | 🔴 |
| 4 | app:refresh | 定时器改调 refresh（原裸 tick），防 helperUp 卡死致计划静默失效 | 🔴 |
| 5 | app:daemonOutdated | 守护版本检测改 Mach-O 机器码对比（签名无关） | 🔴 |
| 6 | install.sh | 先杀旧守护再拷贝（原顺序有覆盖运行中二进制的竞态）+ 幂等 | 🔴 |
| 7 | uninstall.sh | 卸载前经 socket 发 set 00 交还灯控（兑现 README 承诺） | 🔴 |
| 8 | helper:主循环 | usleep(1s)→50ms（原每请求排队 1 秒） | 🟡 |
| 9 | helper:handleOne | 加 5s SO_RCVTIMEO（防挂死） | 🟡 |
| 10 | helper/app:SMC 客户端 | 读失败丢弃重连（防陈旧连接永久失效） | 🟡 |
| 11 | app:applyMode | 守护不在时不再自动弹安装密码（只提示） | 🟡 |
| 12 | install.sh | 幂等：守护在跑且二进制没变就跳过 | 🟡 |
| 13 | helper:dispatch(set) | 先写成功再存 persisted（防状态文件与实况不符） | 🟡 |
| 14 | app:main 线程模型 | socket/SMC I/O 移后台线程，UI 回主线程；SMC 加串行队列 | 🟡 |
| 15 | app:重启恢复白名单 | 补全 [0,1,3,4,6,7,0x19]（闪烁模式原来不恢复） | 🟢 |
| 16 | Sock.swift | connect addrlen 与 bind 统一（2+pathlen） | 🟢 |
| 17 | Fw.swift | 修 cast 失败时 CFDictionary 泄漏 + 格式化 | 🟢 |
| 18 | main.swift(probe) | 删写死的"Mac Studio"误导注释，改动态机器信息+值图例 | 🟢 |
| 19 | socktest.swift | 删死代码 | 🟢 |
| 20 | README | 修正协议表（set 00=跟随系统非关灯；set 19=闪后关）+ macOS 27 注记 | 🟢 |

## 构建

```bash
./build.sh
# 产物：build/MagLED.app + build/bin/{ledctl,magled-helper,probe}
# 需要：Apple Silicon + macOS 13+ + Xcode Command Line Tools
```

## 安装 / 更新（本机部署状态）

- `/Applications/MagLED.app`：菜单栏 App
- `/usr/local/lib/magled/magled-helper`：root 守护（LaunchDaemon `com.atstudio.magled`）
- socket：`/var/run/magled.sock`（协议：每连接单请求 `ping`/`get`/`set <hex>`）
- 守护状态文件：`/var/root/.magled_mode`；日志：`/var/log/magled.log`
- **守护更新流程**：App 菜单 →「更新后台守护（需要密码）」——install.sh 会比对代码段，
  二进制没变就跳过（不弹密码）；变了才重装。
- 注意：菜单栏状态项可能因"菜单栏满"不渲染（见关键发现 5），App 本身照常工作。

## 已知遗留事项

- [ ] 守护二进制需再更新一次（App 端加了断线重连修复后，安装的守护还是上一版；菜单入口会提示）
- [ ] macOS 27 上 App 首次启动若菜单栏满，图标不渲染——环境问题，退出几个状态栏 App 即可
- [ ] 上游若发新版本，rebase 时注意保留本清单全部修复

## AI 更新版本的标准流程

1. 改 `src/` 下代码 → `./build.sh` 编译
2. 功能验证：`build/bin/probe`（只读）、`build/bin/ledctl status`、实测 set 漂移回抓
3. `cp -R build/MagLED.app /Applications/MagLED.app` 并重启 App
4. 守护更新：App 菜单「更新后台守护」（需一次管理员密码）
5. 递增 `Info.plist` 的 `CFBundleShortVersionString`/`CFBundleVersion`
6. 更新本文件的修复清单与日期
7. git commit + push

## 许可与致谢

- MIT（继承上游），上游：shaoya828/magled
- 本 fork 的 macOS 27 兼容化与全部修复：zjhenrynsyh，2026-10-24/25

## 展示内容同步——铁律（AI 改版必守）

**触发条件：任何事实变化（构建/版本/修复/路径/待办/文档）→ 当轮必须同步更新：README、CHANGELOG、AI-CONTEXT.md、脚本头注释、工作区记忆、用户长期记忆——一处都不能漏。**

**交付前自检（每次交付前用 Grep 工具跑，禁止裸 shell grep——工作目录会漂移返回假阴性）**：
- 陈旧关键词：`未生效|待构建|无法编译|暂不可用|待对齐|不会触发`
- 占位符/过时引用：`你的用户名|<版本>|旧仓库地址|旧机器名`
- 命中必改。2026-10-26 教训：裸 shell grep 目录跑偏返回过假「干净」。

**README CI 徽章**：配了 CI 才放徽章（自动更新）；没配 CI 不放假徽章。

**失败案例**：2026-10-26 首次开源时漏建 CHANGELOG、README 留有 `<你的用户名>` 占位符、自检假阴性——次日返工补齐。

## 打包/发产物注意（2026-10-26 教训）

- **打 .app 的 zip 必须 `--keepParent`**：`cd <App所在目录> && ditto -c -k --keepParent App.app X.zip`
  ——漏了会丢外层目录（解压只有 Contents/，用户没法拖进应用程序）。
- **不要加 `--sequesterRsrc`**（App 无资源分叉时会引入 __MACOSX 垃圾目录）。
- **上传 Release 前必须实际解压验证产物结构**；替换资产：先 DELETE 旧 asset 再传同名文件。
