V2bX 服务器出站防滥用基线

这套脚本只管理服务器 `OUTPUT` 中名为 `V2BX_ABUSE_OUT` 的独立链，不修改
`INPUT`、`FORWARD`、Xboard 套餐或 V2bX/Xray 路由文件。

适用于 Debian/Ubuntu 上直接运行的 V2bX/Xray。若 V2bX 在 Docker 容器内运行，
容器转发流量通常经过 `FORWARD`/`DOCKER-USER`，不要直接使用本脚本作为唯一防线。

## 部署

## 一键安装

普通 sudo 用户：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Jasper4860/v2bx-anti-abuse/main/setup.sh)
```

脚本可重复执行。每次执行前会在 `/var/backups/v2bx-anti-abuse/` 保存 IPv4/IPv6
规则；应用中途失败会自动恢复本次操作前的规则。规则通过
`netfilter-persistent` 保存，重启后继续生效。

三个文件放在同一目录时，安装脚本会同时注册快捷命令：

```bash
sudo v2bx-abuse on
sudo v2bx-abuse off
sudo v2bx-abuse status
sudo v2bx-abuse counters
```

如服务器确实需要访问某个私网地址，可在执行时添加精确白名单：

```bash
sudo V2BX_ALLOW_V4_CIDRS="192.168.10.20/32 10.20.0.0/24" \
  V2BX_ALLOW_V6_CIDRS="fd00:1234::10/128" \
  bash ./install-v2bx-anti-abuse.sh
```

## 撤销

```bash
sudo bash ./remove-v2bx-anti-abuse.sh
```

撤销脚本只移除本安装脚本带标签的跳转、回环规则和受管链，不会把整套防火墙
恢复成旧快照，因此不会覆盖部署后由 Docker、运维人员或其他程序新增的规则。

## 默认封禁范围

- SMTP TCP：`25,465,587`
- Telnet/SMB/RDP/远程管理 TCP：
  `22,23,135,139,445,3389,5900,5985,5986`
- 常见反射/放大 UDP：
  `19,111,123,137,138,161,389,1900,3389,3702,5353,11211`
- IPv4：私网、CGNAT、loopback（非 `lo`）、link-local/metadata、文档/测试、
  组播和保留地址
- IPv6：ULA、link-local/metadata、文档/测试、组播和保留地址

为避免损坏服务器自身功能：

- 始终先允许 `lo`；
- 自动允许 `/etc/resolv.conf` 中的 DNS 服务器访问 TCP/UDP 53；
- 自动允许常见的非 root 时间同步账号访问 UDP 123；
- 允许 ICMPv6 控制报文，以保留 IPv6 邻居发现、路由发现和 PMTU。

脚本不会加入 BT、域名黑名单、用户限速、并发限制或日志规则。
