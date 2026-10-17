# PowerShell-FSD

**PowerShell-FSD** 是一个全新编写的 FSD (Flight Server Daemon) 飞行模拟多人联机服务器,
使用纯 PowerShell 实现,不依赖任何第三方组件,也不需要编译——克隆即用。

它实现了经典 FSD 协议,可以与 Squawkbox、Pro Controller、vPilot、xPilot、swift
等飞行模拟多人客户端互联,也支持多台服务器组成网络(联邦)。

## 功能特性

- **三种监听端口**
  - 客户端端口(默认 6809):飞行员 / 管制客户端接入
  - 服务器互联端口(默认 3011):多服务器组网、自动路由、状态同步
  - 系统管理端口(默认 3010):telnet 式管理界面,27 个管理命令
- **完整 FSD 客户端协议**:`#AA/#AP` 登录认证、`@`/`%` 位置报告(含通信射程过滤)、
  `#TM` 文字聊天、`$FP` 飞行计划、`$CQ/$CR` 查询、`$PI/$PO` ping、
  `#SB/#PC` 飞行状态、`$!!` 管理踢人、`#DL` 风偏移等
- **多服务器组网**:NOTIFY 通告、最短跳数路由、广播去重、LINKDOWN 断链通知、
  证书与天气剖面全网同步、SILENT(纯喂给)模式
- **证书系统**:`cert.txt` 证书表,0-12 等级,文件修改热重载并全网广播
- **天气系统**:METAR 解析为云 / 风 / 温度剖面,`network` / `file` / `download`
  (FTP)三种数据源,活动天气剖面优先
- **WhazzUp 输出**:每 30 秒生成 `whazzup.txt` 状态文件
- **管理命令**:`servers`、`clients`、`cert`、`route`、`ping`、`say`、`wall`、
  `kill`、`weather`、`metar`、`wp`(天气剖面编辑)、`log`、`stat` 等
- **Windows 服务**:可安装为自启动服务,响应 SCM 启停控制

## 环境要求

- Windows PowerShell 5.1(Windows 自带)或 PowerShell 7
- 仅 Windows(服务模式依赖 Windows SCM)

## 快速开始

```powershell
# 交互运行
powershell -ExecutionPolicy Bypass -File Fsd.ps1

# 指定配置文件
powershell -ExecutionPolicy Bypass -File Fsd.ps1 -ConfigFile my.conf

# 安装为自启动 Windows 服务(需管理员权限)
powershell -ExecutionPolicy Bypass -File Fsd.ps1 -Install

# 卸载服务
powershell -ExecutionPolicy Bypass -File Fsd.ps1 -Uninstall
```

也可以使用包装脚本:`Run-Fsd.ps1`、`Service-Install.ps1`、`Service-Uninstall.ps1`。

## 目录结构

```
Fsd.ps1                 入口与命令行分发
lib/
  00.Const.ps1          常量、协议命令表、全局状态
  10.Support.ps1        日志、分包、时间、地理计算、伪随机
  20.Manage.ps1         管理变量(stat 命令数据源)
  30.Config.ps1         fsd.conf 解析与热重载
  40.Cert.ps1           证书存储与认证
  50.Model.ps1          服务器 / 客户端 / 飞行计划对象
  60.WProfile.ps1       天气剖面与 METAR 解析
  70.Metar.ps1          METAR 管理(三种数据源)
  80.Conn.ps1           TCP 连接核心(缓冲、行解析、超时、重连守卫)
  81.ClientIF.ps1       客户端接口(客户端协议)
  82.ServerIF.ps1       服务器互联接口(网络协议与路由)
  83.SysIF.ps1          系统管理接口(管理命令)
  90.Fsd.ps1            主循环与周期检查
  95.Service.ps1        Windows 服务宿主
tests/
  Fsd.Tests.ps1         端到端协议自动化测试(42 项)
fsd.conf / cert.txt / motd.txt / help.txt   配置与数据文件
```

## 配置文件 fsd.conf

```ini
[system]
clientport=6809      ; 客户端端口
serverport=3011      ; 服务器互联端口
systemport=3010      ; 管理端口
ident=FSD            ; 服务器唯一标识(全网唯一,短小为佳)
email=nobody@nowhere.com
name=My FSD server
hostname=localhost
password=disable     ; 管理端口特权命令密码(空 = 免认证)
location=Nowhere
mode=normal          ; normal | silent(纯喂给)
certificates=cert.txt
maxclients=200
whazzup=whazzup.txt

[connections]
connectto=           ; 互联服务器,如 fsd1.example.com:3011,fsd2.example.com:3011
allowfrom=           ; 允许接入互联端口的来源

[weather]
source=network       ; network | file | download
```

## 管理端口示例

```
telnet localhost 3010
FSD> pwd disable
FSD> info
FSD> clients
FSD> servers
FSD> help <主题>
```

## 测试

```powershell
powershell -ExecutionPolicy Bypass -File tests\Fsd.Tests.ps1
```

自动拉起两个互联实例(A/B),以原始 TCP 客户端执行 42 项协议测试:
登录认证、错误包、位置 / 聊天 / 飞行计划广播、跨服务器路由、
WhazzUp 生成、断线通告等,全部通过。

## 许可

本项目以 [MIT](LICENSE) 协议开源发布 · Author: **QuanQuan**
