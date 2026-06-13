# naive-proxy-1key

> 一键交互式部署与管理 **NaiveProxy + Caddy** 的 Bash 脚本，自动申请并续期 Let's Encrypt 证书，开箱即用。

NaiveProxy 借助 Caddy 的 `forward_proxy` 模块，将代理流量伪装成正常的 HTTPS 网站访问，具备较强的抗封锁与抗主动探测能力。本脚本把安装、证书申请、防火墙配置、服务托管、自动续期等步骤全部自动化，全程菜单交互，无需手动编辑任何配置文件。

---

## ✨ 脚本特点

- **全交互式菜单**：无需记忆命令行参数，安装时按提示输入域名等信息即可。
- **零预设配置**：不内置任何默认域名/账号，所有信息由你在安装时指定，适合公开使用。
- **智能端口生成**：可一键随机生成 `20000-30000` 之间、各位数字互不相同的 5 位端口，并自动检测端口占用、被占则重新生成。
- **自动证书管理**：首次通过 Certbot 申请 Let's Encrypt 证书；自动配置每周定时续期（Webroot 模式，**无需停止服务**），并带随机延迟错峰。
- **自动防火墙配置**：自动放行所需端口（兼容 `iptables` 与 `firewalld`），并持久化规则，重启不丢失。
- **BBR 加速开关**：内置一键开启 BBR 拥塞控制（基于系统原生 `sysctl`，**不下载任何第三方脚本**）。
- **凭据安全校验**：用户名/密码限制为安全字符，防止注入配置文件。
- **扫码即用**：自动生成分享链接与终端二维码，方便 Shadowrocket / NekoBox 等客户端导入。
- **注重隐私**：无遥测、无外部上报；含密码的日志与配置文件权限限制为 `600`（仅 root 可读）。
- **依赖纯净**：核心仅依赖官方 Caddy(forwardproxy) 二进制与 Certbot，不执行任何来路不明的远程脚本。

---

## 💻 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Ubuntu 16+ / Debian 8+ / CentOS 7+ |
| CPU 架构 | amd64 (x86_64) / arm64 (aarch64) |
| 权限 | **root** 用户 |
| 初始化系统 | systemd |
| 内核版本 | 4.9+（仅使用 BBR 加速功能时需要，普通安装无此要求） |

---

## 📋 前期准备

1. **一台 VPS**，已分配公网 IPv4 地址。
2. **一个域名**，并将其 **A 记录解析到 VPS 的公网 IP**。
   - 若使用 **Cloudflare** 解析，请将该记录的代理状态设为 **「仅 DNS」（灰色云朵）**，**不要开启橙色云朵代理**——否则域名会解析到 Cloudflare 的 IP，导致解析校验失败、证书申请异常。
3. **放行端口**：在 **云服务商的安全组 / 防火墙** 中放行以下端口（脚本只能配置 VPS 内部防火墙，**云平台层面的安全组需你自行开放**）：
   - **TCP 80**：首次申请证书时 Certbot 需要占用，**务必开放且未被其它程序占用**。
   - **代理端口**（你自定义或脚本随机生成的端口）：**TCP + UDP** 均需放行（UDP 用于 HTTP/3）。
4. 域名解析生效后再运行脚本（可用 `ping 你的域名` 确认指向 VPS IP）。

---

## 🚀 使用说明

### 1. 下载并运行

以 **root** 身份执行（推荐进程替换方式，可保证菜单交互正常）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wcgio/naive-proxy-1key/main/naive.sh)
```

或下载到本地后运行：

```bash
wget https://raw.githubusercontent.com/wcgio/naive-proxy-1key/main/naive.sh
chmod +x naive.sh
./naive.sh
```

> ⚠️ 请勿使用 `curl ... | bash` 形式运行：该方式会占用标准输入，导致交互菜单无法读取键盘输入。

### 2. 安装

在主菜单选择 **`1. 安装/更新`**，按提示依次输入：

| 提示 | 说明 |
| --- | --- |
| 域名 | **必填**，脚本会自动检测解析是否指向本机 |
| 端口 | 直接回车则随机生成（`20000-30000`，无重复数字）；也可手动指定 |
| 用户名 | **必填**，仅支持 `A-Za-z0-9_` |
| 密码 | 直接回车则随机生成 32 位；也可手动指定 |
| 邮箱 | 直接回车默认 `admin@你的域名`（仅用于 Let's Encrypt 注册提醒） |

安装完成后，脚本会显示完整配置信息、分享链接与二维码。

### 3. 菜单功能一览

| 选项 | 功能 | 说明 |
| --- | --- | --- |
| 1 | 安装/更新 | 首次安装，或仅更新 Caddy 二进制 |
| 2 | 显示信息 | 查看服务状态、端口监听与当前配置（含二维码） |
| 3 | 修改配置 | 修改端口 / 用户名 / 密码，自动重启并放行新端口 |
| 4 | 证书详情 | 查看证书有效期、在线证书信息与续期日志 |
| 5 | 证书续签 | 立即检查并续期证书（Webroot，无需停服） |
| 6 | 重启服务 | 重启 NaiveProxy 并确保开机自启 |
| 7 | 卸载 | 完全卸载服务、配置与定时任务 |
| 8 | 测试证书续期 | Certbot dry-run 测试，验证自动续期是否可用 |
| 9 | 强制续期证书 | 立即强制续期（无视剩余有效期） |
| 10 | 开启 BBR 加速 | 启用 BBR 拥塞控制算法 |
| 0 | 退出 | 退出脚本 |

### 4. 客户端配置

脚本生成的分享链接格式如下：

```
naive+https://用户名:密码@域名:端口
```

可直接复制链接，或扫描终端二维码导入到支持 NaiveProxy 的客户端，例如：

- **NekoBox**（Android / Windows）
- **Shadowrocket**（iOS）
- **naïve** 官方命令行客户端

> 关于 BBR：BBR 仅对 **TCP（HTTP/2）** 流量生效，对 **HTTP/3（QUIC/UDP）** 不适用。

---

## 📂 文件位置

| 路径 | 用途 |
| --- | --- |
| `/etc/caddy/caddy_config.json` | Caddy 主配置 |
| `/etc/caddy/.autoconfig` | 配置信息存档（权限 600） |
| `/etc/caddy/.renew.sh` | 证书自动续期脚本 |
| `/etc/systemd/system/naive.service` | systemd 服务单元 |
| `/var/www/html/` | 伪装首页与 ACME 验证目录 |
| `/etc/letsencrypt/live/<域名>/` | 证书文件 |
| `/var/log/cert_renew.log` | 证书续期日志 |
| `/var/log/naive_config_<年份>.log` | 安装运行日志（权限 600） |

---

## ❓ 常见问题

- **证书申请失败？** 检查：域名是否正确解析到本机、Cloudflare 是否已关闭橙云代理、80 端口是否被占用或被云安全组拦截。
- **客户端连不上？** 确认代理端口在云安全组中已放行（TCP + UDP），并核对用户名/密码。
- **改了端口后无法连接？** 新端口需在云安全组中放行；脚本只会自动配置 VPS 内部防火墙。

---

## 🙏 致谢

- [klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy) · [klzgrad/forwardproxy](https://github.com/klzgrad/forwardproxy)
- [Caddy](https://caddyserver.com/) · [Let's Encrypt](https://letsencrypt.org/) / [Certbot](https://certbot.eff.org/)

---

## ⚠️ 免责声明

本脚本仅供学习与技术研究使用。请遵守你所在国家或地区的法律法规，因使用本脚本造成的任何后果由使用者自行承担。

---

## 📄 License

本项目基于 [MIT License](LICENSE) 开源。
