# V2bX Anti-Abuse

面向 V2bX/Xray 宿主机的轻量出站防滥用基线。

工具只在 `OUTPUT` 中保留一个到 `V2BX_ABUSE_OUT` 的 jump；loopback、白名单和
封禁规则全部位于受管链内。不修改 `INPUT`、`FORWARD`、Xboard 套餐或
V2bX/Xray 路由。

> 适用于 Debian/Ubuntu 上直接运行的 V2bX/Xray。Docker 转发流量通常经过
> `FORWARD`/`DOCKER-USER`，本工具不能作为容器节点的唯一防线。

## 项目结构

```text
v2bx-anti-abuse/
├── README.md
├── setup.sh       # 下载并安装命令文件
├── install.sh     # 只负责应用防火墙规则
├── remove.sh      # 只负责撤销受管规则
└── v2bx-abuse     # on/off/status/check/counters
```

## 安装

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Jasper4860/v2bx-anti-abuse/main/setup.sh \
  -o /tmp/v2bx-anti-abuse-setup.sh
sudo bash /tmp/v2bx-anti-abuse-setup.sh
rm -f /tmp/v2bx-anti-abuse-setup.sh
```

`setup.sh` 会把规则脚本安装到 `/usr/local/lib/v2bx-anti-abuse/`，把管理命令安装
为 `/usr/local/sbin/v2bx-abuse`，然后调用 `install.sh`。安装脚本自身不再复制文件。

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `sudo v2bx-abuse status` | 查看保护、BT 选项与服务状态 |
| `sudo v2bx-abuse check` | 检查依赖、冲突和运行环境 |
| `sudo v2bx-abuse counters` | 查看规则命中计数 |
| `sudo v2bx-abuse on` | 应用或刷新规则 |
| `sudo v2bx-abuse off` | 撤销本工具管理的规则 |

需要输出完整规则表时：

```bash
sudo env V2BX_VERBOSE=1 v2bx-abuse on
```

## 可选设置

精确放行确实需要访问的私网地址或网段：

```bash
sudo env \
  V2BX_ALLOW_V4_CIDRS="192.168.10.20/32 10.20.0.0/24" \
  V2BX_ALLOW_V6_CIDRS="fd00:1234::10/128" \
  v2bx-abuse on
```

BitTorrent 端口和握手检测默认关闭。需要时显式启用：

```bash
sudo env V2BX_BLOCK_BT=1 v2bx-abuse on
```

再次执行不带 `V2BX_BLOCK_BT=1` 的 `on` 会移除这些可选规则。

## 默认保护范围

- SMTP TCP：`25,465,587`
- 远程管理 TCP：`22,23,135,139,445,3389,5900,5985,5986`
- 反射/放大 UDP：`19,111,123,137,138,161,389,1900,3389,3702,5353,11211`
- IPv4：私网、CGNAT、loopback、link-local/metadata、文档/测试、组播和保留地址
- IPv6：ULA、link-local/metadata、文档/测试、组播和保留地址

受管链首先放行 `lo`，随后处理管理员白名单和系统 DNS；常见的非 root 时间同步
服务可访问 UDP 123，ICMPv6 控制报文也会保留。

## 备份与回滚

每次 `on` 或 `off` 前都会把当前规则保存到 `/var/backups/v2bx-anti-abuse/`。
应用失败时恢复本次操作前的规则；成功后通过 `netfilter-persistent` 保存。IPv4
和 IPv6 各保留最近 20 个备份文件，旧文件自动清理。

撤销只删除带 `v2bx-abuse` 标签的 jump、旧版 loopback 规则和受管链，不会恢复
历史基线，也不会覆盖之后由 Docker、管理员或其他程序新增的规则。

## 当前边界

- 不提供 TCP 新连接限制、域名黑名单、用户限速、并发限制或审计日志。
- 检测到 UFW 或 firewalld 正在管理防火墙时会停止，避免规则叠加。
- 当前仍使用 `netfilter-persistent`；改为独立 systemd oneshot 服务可作为后续阶段。
