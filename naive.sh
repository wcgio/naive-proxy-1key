#!/bin/bash

# NaiveProxy + Caddy 一键安装管理脚本（公开版）
# 交互式菜单驱动，无预设私人配置

# ==================== 颜色定义 ====================
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
_red() { echo -e ${red}$*${none}; }
_green() { echo -e ${green}$*${none}; }
_yellow() { echo -e ${yellow}$*${none}; }
_magenta() { echo -e ${magenta}$*${none}; }
_cyan() { echo -e ${cyan}$*${none}; }

# ==================== 日志配置 ====================
LOG_FILE="/var/log/naive_config_$(date +%Y).log"

# 日志可能含密码等敏感信息，限制为仅 root 可读
touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null

# 启动日志记录（同时输出到屏幕和文件）
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo -e "${cyan}========================================${none}"
echo -e "${cyan}  NaiveProxy 安装脚本${none}"
echo -e "${cyan}  日志文件: $LOG_FILE${none}"
echo -e "${cyan}========================================${none}"
echo ""

# ==================== 工具函数 ====================

# URL 编码（用于生成分享链接的 userinfo 部分）
url_encode_userinfo() {
    local LC_ALL=C
    local value="$1"
    local encoded=""
    local char
    local i

    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        case "$char" in
            [a-zA-Z0-9._~-])
                encoded+="$char"
                ;;
            *)
                printf -v char '%%%02X' "'$char"
                encoded+="$char"
                ;;
        esac
    done

    printf '%s' "$encoded"
}

build_naive_link() {
    local link_user="$1"
    local link_password="$2"
    local link_domain="$3"
    local link_port="$4"
    local encoded_user
    local encoded_password

    encoded_user=$(url_encode_userinfo "$link_user")
    encoded_password=$(url_encode_userinfo "$link_password")
    printf 'naive+https://%s:%s@%s:%s' "$encoded_user" "$encoded_password" "$link_domain" "$link_port"
}

show_naive_qr() {
    local link_user="$1"
    local link_password="$2"
    local link_domain="$3"
    local link_port="$4"
    local naive_link

    naive_link=$(build_naive_link "$link_user" "$link_password" "$link_domain" "$link_port")

    echo
    echo "客户端扫码配置（Shadowrocket 等）："
    echo "$naive_link"
    echo

    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$naive_link"
    else
        echo -e "${yellow}未安装 qrencode，无法生成二维码。${none}"
    fi
}

# 生成随机密码（32位，包含大小写字母和数字）
generate_password() {
    cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32
}

# 校验用户名/密码是否仅含安全字符（A-Za-z0-9_）
# 防止 " \ = 等字符注入 caddy JSON 配置或破坏 .autoconfig 解析
validate_credential() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9_]+$ ]]
}

# 生成 20000-30000 之间、5 位且各位数字互不相同的随机端口
# 首位固定为 2（保证落在区间内），其余 4 位从不含 2 的数字中洗牌取 4 个，确保无重复
# 并检测端口是否已被 TCP/UDP 监听，被占用则重新生成（最多重试 50 次）
generate_port() {
    local digits n i j tmp port attempt
    for ((attempt = 0; attempt < 50; attempt++)); do
        digits=(0 1 3 4 5 6 7 8 9)
        n=${#digits[@]}
        for ((i = n - 1; i > 0; i--)); do
            j=$((RANDOM % (i + 1)))
            tmp=${digits[i]}
            digits[i]=${digits[j]}
            digits[j]=$tmp
        done
        port="2${digits[0]}${digits[1]}${digits[2]}${digits[3]}"
        # 端口未被监听则采用（ss 不可用时管道为空，视为未占用直接返回）
        if ! ss -nltu 2>/dev/null | grep -qE ":${port}\b"; then
            printf '%s' "$port"
            return 0
        fi
    done
    # 重试耗尽（端口空间几乎不可能占满），返回最后一次生成的端口兜底
    printf '%s' "$port"
}

# ==================== 系统检查 ====================
[[ $(id -u) != 0 ]] && echo -e "\n 请使用 ${red}root${none} 用户运行 ${yellow}~(^_^)${none}\n" && exit 1

cmd="apt-get"
sys_bit=$(uname -m)

case $sys_bit in
'amd64' | x86_64)
    caddy_arch="amd64"
    ;;
*aarch64* | *armv8*)
    caddy_arch="arm64"
    ;;
*)
    echo -e "
    ${red}不支持的系统架构: $sys_bit${none}

    备注: 仅支持 Ubuntu 16+ / Debian 8+ / CentOS 7+ 系统 (amd64 / arm64)
    " && exit 1
    ;;
esac

if [[ $(command -v apt-get) || $(command -v yum) ]] && [[ $(command -v systemctl) ]]; then
    [[ $(command -v yum) ]] && cmd="yum"
    [[ $(command -v apt-get) ]] && cmd="apt-get"
else
    echo -e "
    ${red}不支持的系统${none}

    备注: 仅支持 Ubuntu 16+ / Debian 8+ / CentOS 7+ 系统
    " && exit 1
fi

systemd=true

do_service() {
    if [[ $systemd ]]; then
        systemctl $1 $2 $3
    else
        service $2 $1
    fi
}

error() {
    echo -e "\n$red 输入错误！$none\n"
}

pause() {
    echo ""
    # 优先从 /dev/tty 读，兼容 stdin 被管道占用的场景；无 tty 时跳过避免 read I/O error
    if [ -e /dev/tty ]; then
        read -rsp "$(echo -e "按 $green Enter 回车键 $none 返回菜单...")" -d $'\n' < /dev/tty 2>/dev/null
    fi
    echo ""
}

get_ip() {
    ipv4=$(curl -s https://ipinfo.io/ip)
    [[ -z $ipv4 ]] && ipv4=$(curl -s https://api.ipify.org)
    [[ -z $ipv4 ]] && ipv4=$(curl -s https://ip.seeip.org)
    [[ -z $ipv4 ]] && ipv4=$(curl -s https://ifconfig.co/ip)
    [[ -z $ipv4 ]] && ipv4=$(curl -s https://api.myip.com | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}")
    [[ -z $ipv4 ]] && ipv4=$(curl -s icanhazip.com)
    [[ -z $ipv4 ]] && ipv4=$(curl -s myip.ipip.net | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}")
    ipv6=$(ip a 2>/dev/null | grep inet6 | grep global | awk '{print $2}' | awk -F '/' '{print $1}')
    [[ -z $ipv4 ]] && [[ -z $ipv6 ]] && echo -e "\n$red 未检测到 ipv4 与 ipv6 地址！$none\n" && exit 1

    ip_all="$ipv4 $ipv6"
}

_sys_timezone() {
    echo
    timedatectl set-timezone Asia/Shanghai 2>/dev/null
    timedatectl set-ntp true 2>/dev/null
    echo "已将主机时区设置为 Asia/Shanghai 并启用自动时间同步。"
    echo
}

_sys_time() {
    echo -e "\n主机时间：${yellow}"
    timedatectl status | sed -n '1p;4p'
    echo -e "${none}"
    return 0
}

# ==================== 配置交互 ====================
naive_config() {
    echo -e "${cyan}=== 配置 NaiveProxy ===${none}"
    echo

    get_ip

    # 域名（必填，带解析检测）
    while :; do
        read -p "$(echo -e "请输入域名: ")" domain
        if [ -z "$domain" ]; then
            echo -e "${red}✗ 域名不能为空${none}"
            continue
        fi

        echo -e "${yellow}正在检测域名解析...${none}"
        test_domain=$(curl -sH 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$domain&type=A" 2>/dev/null | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)

        if [ -z "$test_domain" ]; then
            echo -e "${red}✗ 域名 $domain 未解析到任何 IP 地址${none}"
            read -p "$(echo -e "是否仍然继续? [${magenta}y/N$none]: ")" force_continue
            [[ "$force_continue" == [Yy] ]] && break || continue
        fi

        if echo "$ip_all" | grep -q "$test_domain"; then
            echo -e "${green}✓ 域名解析正确: $domain -> $test_domain${none}"
            break
        else
            echo -e "${red}✗ 域名解析不匹配${none}"
            echo -e "  服务器 IP: ${cyan}$ip_all${none}"
            echo -e "  域名解析到: ${cyan}$test_domain${none}"
            read -p "$(echo -e "是否仍然继续? [${magenta}y/N$none]: ")" force_continue
            [[ "$force_continue" == [Yy] ]] && break || continue
        fi
    done

    # 端口（回车随机生成）
    while :; do
        read -p "$(echo -e "请输入端口 [${cyan}回车随机生成 20000-30000 无重复$none]: ")" naive_port
        if [ -z "$naive_port" ]; then
            naive_port=$(generate_port)
            echo -e "${green}已随机生成端口: $naive_port${none}"
            break
        fi
        if [[ "$naive_port" =~ ^[0-9]+$ ]] && [ "$naive_port" -ge 1 ] && [ "$naive_port" -le 65535 ] && [ "$naive_port" != 80 ]; then
            break
        fi
        echo -e "${red}✗ 端口需为 1-65535 之间的数字，且不能为 80${none}"
    done

    # 用户名（必填，字符校验）
    while :; do
        read -p "$(echo -e "请输入用户名 [${cyan}A-Za-z0-9_$none]: ")" naive_user
        if validate_credential "$naive_user"; then
            break
        fi
        echo -e "${red}✗ 用户名仅支持字母、数字、下划线，且不能为空${none}"
    done

    # 密码（回车随机生成，字符校验）
    while :; do
        read -p "$(echo -e "请输入密码 [${cyan}回车随机生成 32 位$none]: ")" password
        if [ -z "$password" ]; then
            password=$(generate_password)
            echo -e "${green}已随机生成密码${none}"
            break
        fi
        if validate_credential "$password"; then
            break
        fi
        echo -e "${red}✗ 密码仅支持字母、数字、下划线${none}"
    done

    # 邮箱（回车默认 admin@域名，仅用于 Let's Encrypt 注册）
    read -p "$(echo -e "请输入邮箱 [${cyan}回车默认 admin@$domain$none]: ")" email
    [ -z "$email" ] && email="admin@$domain"

    echo
    echo -e "${green}配置信息:${none}"
    echo -e "  域名: ${cyan}$domain${none}"
    echo -e "  端口: ${cyan}$naive_port${none}"
    echo -e "  用户名: ${cyan}$naive_user${none}"
    echo -e "  邮箱: ${cyan}$email${none}"
    echo
}

# ==================== 安装相关 ====================
install_certbot() {
    if [[ $cmd == "apt-get" ]]; then
        $cmd update -y
        $cmd install -y lrzsz git zip unzip curl wget qrencode libcap2-bin tar
        $cmd install -y certbot
    else
        $cmd install -y lrzsz git zip unzip curl wget qrencode libcap epel-release tar openssl-devel ca-certificates
        $cmd install -y certbot
    fi
}

install_caddy() {
    mkdir -p /root/src
    cd /root/src/ || return 1
    rm -f caddy-forwardproxy-naive.tar.xz
    wget https://github.com/klzgrad/forwardproxy/releases/download/v2.7.5-caddy2-naive2/caddy-forwardproxy-naive.tar.xz
    tar xvf caddy-forwardproxy-naive.tar.xz
    systemctl stop naive 2>/dev/null
    \cp -f caddy-forwardproxy-naive/caddy /usr/bin/
    /usr/bin/caddy version
    setcap cap_net_bind_service=+ep /usr/bin/caddy
}

config() {
    mkdir -p /etc/caddy/ /var/www/html

    # 生成伪装首页（诗词站），避免 file_server 返回目录列表
    # 已存在则跳过，便于用户自定义后不被覆盖
    if [ ! -f /var/www/html/index.html ]; then
        cat > /var/www/html/index.html << 'DECOY_HTML_EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>诗渡 — 古典诗词品读</title>
<style>
  :root{
    --bg:#fdfcfa; --ink:#2b2722; --ink2:#6a635a; --ink3:#9a8f7d;
    --line:#ece6da; --card:#ffffff; --seal:#b0473c; --wave:#aed3f0;
  }
  *{ margin:0; padding:0; box-sizing:border-box; }
  body{
    font-family:"Noto Serif SC","Songti SC","STSong","SimSun",serif;
    background:var(--bg); color:var(--ink); line-height:1.75;
    -webkit-font-smoothing:antialiased;
  }
  a{ color:inherit; text-decoration:none; }
  .container{ max-width:1080px; margin:0 auto; padding:0 28px; }

  /* 顶栏 */
  .site-header{ position:sticky; top:0; z-index:10; background:rgba(253,252,250,.9); backdrop-filter:saturate(1.2) blur(6px); border-bottom:1px solid var(--line); }
  .nav{ display:flex; align-items:center; gap:28px; height:64px; }
  .logo{ font-size:24px; font-weight:600; letter-spacing:.2em; color:var(--seal); }
  .menu{ display:flex; gap:26px; font-size:15px; color:var(--ink2); }
  .menu a:hover{ color:var(--ink); }
  .search{ margin-left:auto; }
  .search input{
    font-family:inherit; font-size:14px; color:var(--ink); background:#fff;
    border:1px solid var(--line); border-radius:20px; padding:7px 16px; width:180px; outline:none;
  }
  .search input:focus{ border-color:var(--ink3); }

  /* 首屏 */
  .hero{ position:relative; text-align:center; padding:74px 24px 130px; overflow:hidden; }
  .hero-kicker{ font-size:13px; letter-spacing:.3em; color:var(--seal); margin-bottom:22px; }
  .hero-verse{ font-size:clamp(30px,5.4vw,50px); font-weight:500; letter-spacing:.16em; line-height:1.6; }
  .hero-source{ margin-top:20px; font-size:15px; color:var(--ink3); letter-spacing:.1em; }
  .hero-btn{
    display:inline-block; margin-top:30px; font-size:14px; letter-spacing:.12em; color:var(--ink);
    border:1px solid var(--ink3); border-radius:22px; padding:9px 26px; transition:.2s;
  }
  .hero-btn:hover{ background:var(--ink); color:#fff; border-color:var(--ink); }
  .hero .waves-wrap{ position:absolute; left:0; right:0; bottom:0; height:90px; overflow:hidden; }
  .waves{ width:100%; height:100%; display:block; }
  .parallax>use{ animation:move-forever 25s cubic-bezier(.55,.5,.45,.5) infinite; }
  .parallax>use:nth-child(1){ animation-delay:-2s; animation-duration:8s; }
  .parallax>use:nth-child(2){ animation-delay:-3s; animation-duration:11s; }
  .parallax>use:nth-child(3){ animation-delay:-4s; animation-duration:15s; }
  .parallax>use:nth-child(4){ animation-delay:-5s; animation-duration:22s; }
  @keyframes move-forever{ 0%{transform:translate3d(-90px,0,0);} 100%{transform:translate3d(85px,0,0);} }

  /* 区块通用 */
  .block{ padding:54px 0; }
  .block-head{ display:flex; align-items:baseline; justify-content:space-between; margin-bottom:26px; }
  .block-head h2, .block>h2{ font-size:22px; font-weight:600; letter-spacing:.08em; }
  .block>h2{ margin-bottom:22px; }
  .more{ font-size:14px; color:var(--ink3); }
  .more:hover{ color:var(--seal); }

  /* 名篇卡片 */
  .cards{ display:grid; grid-template-columns:repeat(auto-fill,minmax(230px,1fr)); gap:18px; }
  .card{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:20px 22px; transition:.2s; }
  .card:hover{ border-color:var(--ink3); transform:translateY(-2px); }
  .card h3{ font-size:18px; font-weight:500; letter-spacing:.06em; }
  .card .meta{ margin:6px 0 12px; font-size:13px; color:var(--ink3); }
  .card .first{ font-size:14px; color:var(--ink2); }

  /* 朝代标签 */
  .tags{ display:flex; flex-wrap:wrap; gap:12px; }
  .tags a{ font-size:15px; color:var(--ink2); border:1px solid var(--line); border-radius:20px; padding:8px 22px; transition:.2s; }
  .tags a:hover{ color:var(--seal); border-color:var(--seal); }

  /* 诗人 */
  .poets{ display:grid; grid-template-columns:repeat(auto-fill,minmax(140px,1fr)); gap:16px; }
  .poet{ display:flex; align-items:center; gap:12px; background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px 16px; transition:.2s; }
  .poet:hover{ border-color:var(--ink3); }
  .avatar{ width:38px; height:38px; border-radius:50%; background:#f3ede1; color:var(--seal); display:flex; align-items:center; justify-content:center; font-size:18px; }
  .poet .pn{ font-size:16px; }
  .poet .dyn{ margin-left:auto; font-size:12px; color:var(--ink3); }

  /* 名句 */
  .quotes{ display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:18px; }
  blockquote{ background:var(--card); border-left:3px solid var(--seal); border-radius:0 8px 8px 0; padding:18px 22px; font-size:17px; letter-spacing:.04em; }
  blockquote cite{ display:block; margin-top:10px; font-size:13px; color:var(--ink3); font-style:normal; }

  /* 页脚 */
  footer{ border-top:1px solid var(--line); margin-top:30px; padding:36px 0; background:#faf8f3; }
  .foot{ display:flex; flex-wrap:wrap; align-items:center; gap:14px 26px; font-size:13px; color:var(--ink3); }
  .foot .fb{ font-size:18px; font-weight:600; color:var(--seal); letter-spacing:.2em; }
  .foot-links{ display:flex; gap:18px; }
  .foot-links a:hover{ color:var(--ink); }
  .foot-copy{ width:100%; color:var(--ink3); }

  /* 点击涟漪 */
  .ripple{ position:fixed; border-radius:50%; border:1.5px solid rgba(86,160,210,.5); transform:translate(-50%,-50%); width:0; height:0; opacity:.8; pointer-events:none; z-index:50; animation:rippleExpand 1.1s ease-out forwards; }
  @keyframes rippleExpand{ 0%{opacity:.8;} to{ width:300px; height:300px; opacity:0; } }

  @media(max-width:640px){ .menu,.search{ display:none; } }
</style>
</head>
<body>
  <header class="site-header">
    <div class="container nav">
      <a class="logo" href="/">诗渡</a>
      <nav class="menu">
        <a href="/shi">诗</a><a href="/ci">词</a><a href="/qu">曲</a>
        <a href="/poets">诗人</a><a href="/mingju">名句</a><a href="/dianji">典籍</a>
      </nav>
      <div class="search"><input type="text" placeholder="搜索诗词、作者…"></div>
    </div>
  </header>

  <section class="hero">
    <p class="hero-kicker">每 日 一 首</p>
    <h1 class="hero-verse">春江潮水连海平<br>海上明月共潮生</h1>
    <p class="hero-source">—— 张若虚《春江花月夜》</p>
    <a class="hero-btn" href="/p/chunjiang">读 全 篇</a>
    <div class="waves-wrap">
      <svg class="waves" viewBox="0 24 150 28" preserveAspectRatio="none">
        <defs><path id="gentle-wave" d="M-160 44c30 0 58-18 88-18s58 18 88 18 58-18 88-18 58 18 88 18 v44h-352z" /></defs>
        <g class="parallax">
          <use href="#gentle-wave" x="48" y="0" fill="rgba(168,213,240,.5)" />
          <use href="#gentle-wave" x="48" y="3" fill="rgba(140,198,235,.45)" />
          <use href="#gentle-wave" x="48" y="5" fill="rgba(110,182,228,.5)" />
          <use href="#gentle-wave" x="48" y="7" fill="rgba(80,160,215,.9)" />
        </g>
      </svg>
    </div>
  </section>

  <main>
    <section class="container block">
      <div class="block-head"><h2>名篇选读</h2><a class="more" href="/famous">查看全部 →</a></div>
      <div class="cards">
        <a class="card" href="/p/jingyesi"><h3>静夜思</h3><p class="meta">李白 · 唐</p><p class="first">床前明月光，疑是地上霜</p></a>
        <a class="card" href="/p/shuidiao"><h3>水调歌头</h3><p class="meta">苏轼 · 宋</p><p class="first">明月几时有，把酒问青天</p></a>
        <a class="card" href="/p/dengguan"><h3>登鹳雀楼</h3><p class="meta">王之涣 · 唐</p><p class="first">白日依山尽，黄河入海流</p></a>
        <a class="card" href="/p/shengsheng"><h3>声声慢</h3><p class="meta">李清照 · 宋</p><p class="first">寻寻觅觅，冷冷清清</p></a>
        <a class="card" href="/p/niannu"><h3>念奴娇·赤壁怀古</h3><p class="meta">苏轼 · 宋</p><p class="first">大江东去，浪淘尽</p></a>
        <a class="card" href="/p/pipaxing"><h3>琵琶行</h3><p class="meta">白居易 · 唐</p><p class="first">浔阳江头夜送客，枫叶荻花秋瑟瑟</p></a>
        <a class="card" href="/p/qingyuan"><h3>青玉案·元夕</h3><p class="meta">辛弃疾 · 宋</p><p class="first">东风夜放花千树</p></a>
        <a class="card" href="/p/shanju"><h3>山居秋暝</h3><p class="meta">王维 · 唐</p><p class="first">空山新雨后，天气晚来秋</p></a>
      </div>
    </section>

    <section class="container block">
      <h2>按时代浏览</h2>
      <div class="tags">
        <a href="/d/shijing">诗经</a><a href="/d/chuci">楚辞</a><a href="/d/yuefu">汉乐府</a>
        <a href="/d/tang">唐诗</a><a href="/d/song">宋词</a><a href="/d/yuan">元曲</a>
        <a href="/d/mingqing">明清</a>
      </div>
    </section>

    <section class="container block">
      <div class="block-head"><h2>名家</h2><a class="more" href="/poets">更多 →</a></div>
      <div class="poets">
        <a class="poet" href="/poet/libai"><span class="avatar">李</span><span class="pn">李白</span><span class="dyn">唐</span></a>
        <a class="poet" href="/poet/dufu"><span class="avatar">杜</span><span class="pn">杜甫</span><span class="dyn">唐</span></a>
        <a class="poet" href="/poet/wangwei"><span class="avatar">王</span><span class="pn">王维</span><span class="dyn">唐</span></a>
        <a class="poet" href="/poet/baijuyi"><span class="avatar">白</span><span class="pn">白居易</span><span class="dyn">唐</span></a>
        <a class="poet" href="/poet/sushi"><span class="avatar">苏</span><span class="pn">苏轼</span><span class="dyn">宋</span></a>
        <a class="poet" href="/poet/liqingzhao"><span class="avatar">李</span><span class="pn">李清照</span><span class="dyn">宋</span></a>
        <a class="poet" href="/poet/xinqiji"><span class="avatar">辛</span><span class="pn">辛弃疾</span><span class="dyn">宋</span></a>
        <a class="poet" href="/poet/liyu"><span class="avatar">李</span><span class="pn">李煜</span><span class="dyn">五代</span></a>
      </div>
    </section>

    <section class="container block">
      <h2>名句</h2>
      <div class="quotes">
        <blockquote>但愿人长久，千里共婵娟。<cite>苏轼《水调歌头》</cite></blockquote>
        <blockquote>海内存知己，天涯若比邻。<cite>王勃《送杜少府之任蜀州》</cite></blockquote>
        <blockquote>会当凌绝顶，一览众山小。<cite>杜甫《望岳》</cite></blockquote>
        <blockquote>问君能有几多愁，恰似一江春水向东流。<cite>李煜《虞美人》</cite></blockquote>
      </div>
    </section>
  </main>

  <footer>
    <div class="container foot">
      <span class="fb">诗渡</span>
      <span>以诗为渡，共此山河岁月</span>
      <span class="foot-links"><a href="/about">关于我们</a><a href="/contact">联系方式</a><a href="/submit">投稿</a><a href="/links">友情链接</a></span>
      <span class="foot-copy">© 2026 诗渡 ShiDu · 沪ICP备2026045517号 · 内容仅供学习交流</span>
    </div>
  </footer>

  <script>
    addEventListener('click', function (e) {
      for (var i = 0; i < 2; i++) {
        var r = document.createElement('span');
        r.className = 'ripple';
        r.style.left = e.clientX + 'px';
        r.style.top = e.clientY + 'px';
        r.style.animationDelay = (i * 0.14) + 's';
        document.body.appendChild(r);
        r.addEventListener('animationend', function () { this.remove(); });
      }
    });
  </script>
</body>
</html>
DECOY_HTML_EOF
    fi

    if [[ $(ls /etc/letsencrypt/live/ 2>/dev/null | grep "$domain") ]]; then
        certbot renew
    else
        certbot certonly --standalone -d "$domain" --agree-tos --email "$email" --non-interactive
    fi

    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    _sys_timezone
    _sys_time

    # 以证书文件实际存在为成功判据
    if [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" && -f "/etc/letsencrypt/live/$domain/privkey.pem" ]]; then
        return 0
    else
        return 1
    fi
}

caddy_config() {
    local config_password=$password
    local config_user=$naive_user

    cat > /etc/caddy/caddy_config.json << EOF
{
  "admin": {
    "disabled": true
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":$naive_port"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_user_deprecated": "$config_user",
                          "auth_pass_deprecated": "$config_password",
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "$domain"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "/var/www/html",
                          "index_names": [
                            "index.html"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": [
                  "$domain"
                ]
              }
            }
          ],
          "automatic_https": {
            "disable": true
          }
        },
        "srv_acme": {
          "listen": [
            ":80"
          ],
          "routes": [
            {
              "match": [
                {
                  "host": [
                    "$domain"
                  ]
                }
              ],
              "handle": [
                {
                  "handler": "vars",
                  "root": "/var/www/html"
                },
                {
                  "handler": "file_server",
                  "root": "/var/www/html"
                }
              ]
            },
            {
              "handle": [
                {
                  "handler": "static_response",
                  "status_code": 200,
                  "headers": {
                    "Content-Type": ["text/plain"]
                  },
                  "body": "OK"
                }
              ]
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [
          {
            "certificate": "/etc/letsencrypt/live/$domain/fullchain.pem",
            "key": "/etc/letsencrypt/live/$domain/privkey.pem"
          }
        ]
      }
    }
  }
}
EOF

    cat > /etc/systemd/system/naive.service << EOF
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy_config.json
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy_config.json
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
    do_service daemon-reload
    do_service restart naive
    echo
    echo "........... NaiveProxy 已启动  .........."
    do_service enable naive
    echo
    echo "........... NaiveProxy 设置自动启动完成 .........."

    echo
    echo "........... NaiveProxy 服务状态  .........."
    do_service status naive --no-pager
    netstat -nltp 2>/dev/null | grep caddy || ss -nltp | grep caddy
}

allow_port() {
    if [[ $(command -v yum) ]]; then
        firewall-cmd --zone=public --add-port=80/tcp --permanent 2>/dev/null
        firewall-cmd --zone=public --add-port=$naive_port/tcp --permanent 2>/dev/null
        firewall-cmd --zone=public --add-port=$naive_port/udp --permanent 2>/dev/null
        firewall-cmd --reload 2>/dev/null
    fi

    if [[ $(command -v apt-get) ]]; then
        # 先查重（-C）再插入（-I），避免重装/改端口时规则重复叠加
        iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null
        iptables -C INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $naive_port -j ACCEPT 2>/dev/null
        iptables -C INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $naive_port -j ACCEPT 2>/dev/null

        # 持久化规则，避免重启丢失（默认 DROP 策略环境下尤为重要）
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null
        else
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        fi
    fi

    echo
    echo "........... 防火墙已开放端口 $naive_port  .........."
}

add_cron() {
    local renew_cron_count
    local renew_entry="0 2 * * 0 /etc/caddy/.renew.sh >> /var/log/cert_renew.log 2>&1"

    echo
    echo "........... 证书自动更新配置  .........."

    mkdir -p /var/www/html/.well-known/acme-challenge

    # 创建证书续期脚本（无外部变量注入，使用带引号 heredoc 避免转义）
    cat > /etc/caddy/.renew.sh << 'RENEW_SCRIPT_EOF'
#!/usr/bin/env bash
LOG_FILE="/var/log/cert_renew.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# 随机延迟错峰，避免大量服务器同一时刻向 Let's Encrypt 发起续期
sleep $((RANDOM % 3600))

log "========== 开始证书续期 =========="
domain=$(grep 'domain' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
certbot renew --webroot -w /var/www/html --quiet --deploy-hook "systemctl reload naive"
if [ $? -eq 0 ]; then
    log "✓ 证书续期检查完成: $domain"
else
    log "✗ 证书续期过程出错: $domain"
    exit 1
fi
log "========== 证书续期检查结束 =========="
RENEW_SCRIPT_EOF

    chmod +x /etc/caddy/.renew.sh

    if command -v crontab >/dev/null 2>&1; then
        renew_cron_count=$(crontab -l 2>/dev/null | grep -c ".renew.sh" || true)
        if [ "${renew_cron_count:-0}" -lt 1 ]; then
            (crontab -l 2>/dev/null; echo "$renew_entry") | crontab -
        fi
    else
        mkdir -p /var/spool/cron/
        touch /var/spool/cron/root
        renew_cron_count=$(grep -c ".renew.sh" /var/spool/cron/root 2>/dev/null || true)
        if [ "${renew_cron_count:-0}" -lt 1 ]; then
            echo "$renew_entry" >> /var/spool/cron/root
        fi
    fi

    if command -v systemctl &> /dev/null; then
        systemctl restart crond 2>/dev/null || systemctl restart cron 2>/dev/null
    else
        service cron restart 2>/dev/null || service crond restart 2>/dev/null
    fi

    echo
    echo "........... 证书自动更新设置完成  .........."
    echo "续期时间: 每周日凌晨2点（+随机延迟）"
    echo "续期方式: Webroot（无需停止服务）"
    echo "日志文件: /var/log/cert_renew.log"
    echo ""
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep renew || true
    else
        grep renew /var/spool/cron/root 2>/dev/null || true
    fi

    return 0
}

update_caddy() {
    install_caddy
}

show_config_info() {
    clear
    echo > /etc/caddy/.autoconfig
    echo -e "域名domain   =$domain" >> /etc/caddy/.autoconfig
    echo -e "端口port     =$naive_port" >> /etc/caddy/.autoconfig
    echo -e "用户名user   =$naive_user" >> /etc/caddy/.autoconfig
    echo -e "密码password =$password" >> /etc/caddy/.autoconfig
    echo -e "邮箱email    =$email" >> /etc/caddy/.autoconfig
    chmod 600 /etc/caddy/.autoconfig

    echo
    echo "........... NaiveProxy 配置信息  .........."
    echo
    cat /etc/caddy/.autoconfig
    show_naive_qr "$naive_user" "$password" "$domain" "$naive_port"

    return 0
}

install() {
    local install_success=true

    if [[ -f /usr/bin/caddy && -f /etc/caddy/caddy_config.json ]]; then
        echo
        echo " 检测到 NaiveProxy 已存在..."
        echo
        echo " 1：继续安装（重新配置并覆盖）"
        echo " 2：仅更新 Caddy 二进制"
        echo " 其它：退出"
        echo
        read -p "$(echo -e "请选择 [${magenta}1-2$none]:")" choose2
        case $choose2 in
        1)
            echo " 继续安装..."
            do_service stop naive
            ;;
        2)
            echo " 更新 Caddy..."
            do_service stop naive
            update_caddy
            do_service start naive
            echo ""
            echo -e "${green}更新完成！${none}"
            echo ""
            cat /etc/caddy/.autoconfig 2>/dev/null
            return 0
            ;;
        *)
            echo "已取消"
            return 1
            ;;
        esac
    fi

    echo -e "${yellow}========== 步骤 1/9: 配置参数 ==========${none}"
    naive_config

    echo -e "${yellow}========== 步骤 2/9: 安装依赖 ==========${none}"
    install_certbot || { install_success=false; echo -e "${red}✗ 安装依赖失败${none}"; }

    echo -e "${yellow}========== 步骤 3/9: 处理端口冲突 ==========${none}"
    if [[ $cmd == "yum" ]]; then
        [[ $(pgrep "nginx") ]] && do_service stop nginx
        [[ $(command -v nginx) ]] && yum remove nginx -y
        [[ $(pgrep "httpd") ]] && do_service stop httpd
        [[ $(command -v httpd) ]] && yum remove httpd -y
    else
        [[ $(pgrep "apache2") ]] && service apache2 stop
        [[ $(command -v apache2) ]] && apt-get remove apache2* -y
        # nginx 同样可能占用 80 端口，停止并禁止自启（不卸载，避免破坏用户环境）
        if [[ $(command -v nginx) ]]; then
            [[ $(pgrep "nginx") ]] && do_service stop nginx
            do_service disable nginx 2>/dev/null
        fi
    fi
    echo -e "${green}✓ 端口冲突处理完成${none}"

    echo -e "${yellow}========== 步骤 4/9: 开放防火墙端口 ==========${none}"
    allow_port

    echo -e "${yellow}========== 步骤 5/9: 安装 Caddy ==========${none}"
    install_caddy || { install_success=false; echo -e "${red}✗ 安装 Caddy 失败${none}"; }

    echo -e "${yellow}========== 步骤 6/9: 申请 SSL 证书 ==========${none}"
    config || { install_success=false; echo -e "${red}✗ 配置证书失败${none}"; }

    echo -e "${yellow}========== 步骤 7/9: 生成 Caddy 配置 ==========${none}"
    caddy_config || { install_success=false; echo -e "${red}✗ 生成配置失败${none}"; }

    echo -e "${yellow}========== 步骤 8/9: 配置定时任务 ==========${none}"
    add_cron || { install_success=false; echo -e "${red}✗ 配置定时任务失败${none}"; }

    if [ "$install_success" = true ]; then
        echo -e "${yellow}========== 步骤 9/9: 显示配置信息 ==========${none}"
        show_config_info
        return 0
    else
        echo -e "${red}安装过程中出现错误，请检查日志: $LOG_FILE${none}"
        return 1
    fi
}

# ==================== 管理功能 ====================
edit_config() {
    domain=$(grep 'domain' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
    user=$(grep 'user' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
    password=$(grep 'password' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
    naive_port=$(grep 'port' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
    email=$(grep 'email' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')

    echo -e "请输入 "$yellow"NaiveProxy"$none" 端口 ["$magenta"1-65535"$none"]，不能选择 "$magenta"80"$none" 端口"
    read -p "$(echo -e "(当前端口: ${cyan}${naive_port}$none):")" naive_port1
    [ -z "$naive_port1" ] || naive_port=$naive_port1

    echo -e "请输入 "$yellow"NaiveProxy"$none" 用户名，支持 A-Za-z0-9_"
    read -p "$(echo -e "(当前用户名: ${cyan}${user}$none):")" user1
    if [ -n "$user1" ]; then
        if validate_credential "$user1"; then
            user=$user1
        else
            echo -e "${red}✗ 用户名含非法字符，保留原值${none}"
        fi
    fi

    echo -e "请输入 "$yellow"NaiveProxy"$none" 密码，支持 A-Za-z0-9_"
    read -p "$(echo -e "(当前密码: ${cyan}${password}$none):")" password1
    if [ -n "$password1" ]; then
        if validate_credential "$password1"; then
            password=$password1
        else
            echo -e "${red}✗ 密码含非法字符，保留原值${none}"
        fi
    fi

    naive_user=$user

    caddy_config

    echo > /etc/caddy/.autoconfig
    echo -e "域名domain   =$domain" >> /etc/caddy/.autoconfig
    echo -e "端口port     =$naive_port" >> /etc/caddy/.autoconfig
    echo -e "用户名user   =$user" >> /etc/caddy/.autoconfig
    echo -e "密码password =$password" >> /etc/caddy/.autoconfig
    echo -e "邮箱email    =$email" >> /etc/caddy/.autoconfig
    chmod 600 /etc/caddy/.autoconfig

    # 端口可能已变更，重新放行防火墙端口
    allow_port

    echo
    echo "........... NaiveProxy 配置已更新  .........."
    cat /etc/caddy/.autoconfig
    show_naive_qr "$user" "$password" "$domain" "$naive_port"
}

show_config() {
    local config_domain config_port config_user config_password

    clear
    echo
    echo "========================================="
    echo "  NaiveProxy 配置信息"
    echo "========================================="
    echo
    echo "--- 服务状态 ---"
    do_service status naive --no-pager
    echo
    echo "--- 端口状态 ---"
    netstat -nltp 2>/dev/null | grep caddy || ss -nltp | grep caddy
    echo
    echo "--- 配置信息 ---"
    if [ -f /etc/caddy/.autoconfig ]; then
        cat /etc/caddy/.autoconfig
        config_domain=$(grep 'domain' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
        config_port=$(grep 'port' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
        config_user=$(grep 'user' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
        config_password=$(grep 'password' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
        if [[ -n "$config_domain" && -n "$config_port" && -n "$config_user" && -n "$config_password" ]]; then
            show_naive_qr "$config_user" "$config_password" "$config_domain" "$config_port"
        fi
    else
        echo -e "${red}配置文件不存在${none}"
    fi
    echo
    echo "========================================="
}

check_cert_info() {
    clear
    domain=$(grep 'domain' /etc/caddy/.autoconfig 2>/dev/null | awk -F'=' '{print $2}')

    if [ -z "$domain" ]; then
        echo ""
        echo -e "${red}错误：未找到域名配置${none}"
        echo ""
        return 1
    fi

    echo ""
    echo "========================================="
    echo "  证书详细信息"
    echo "========================================="
    echo ""
    certbot certificates 2>/dev/null

    echo ""
    echo "========================================="
    echo "  SSL 证书在线检查"
    echo "========================================="
    echo ""
    echo | openssl s_client -servername $domain -connect $domain:443 2>/dev/null | openssl x509 -noout -dates -subject -issuer

    echo ""
    echo "========================================="
    echo "  最近续期日志（最后 20 行）"
    echo "========================================="
    echo ""
    if [ -f /var/log/cert_renew.log ]; then
        tail -20 /var/log/cert_renew.log
    else
        echo "暂无续期日志"
    fi
    echo ""
    echo "========================================="
}

cert_renew() {
    domain=$(grep 'domain' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
    # caddy 常驻 80 端口提供 webroot 验证，无需停服
    certbot renew --webroot -w /var/www/html --deploy-hook "systemctl reload naive"
}

test_cert_renew() {
    clear
    echo ""
    echo "========================================="
    echo "  测试证书续期（dry-run 模式）"
    echo "========================================="
    echo ""
    certbot renew --dry-run --webroot -w /var/www/html

    if [ $? -eq 0 ]; then
        echo ""
        echo "========================================="
        echo -e "${green}✓ 续期测试通过！自动续期配置可用${none}"
        echo "注意：实际续期将在证书到期前 30 天内自动执行"
        echo "========================================="
    else
        echo ""
        echo "========================================="
        echo -e "${red}✗ 续期测试失败，请检查配置${none}"
        echo "========================================="
    fi
    echo ""
}

force_cert_renew() {
    clear
    domain=$(grep 'domain' /etc/caddy/.autoconfig 2>/dev/null | awk -F'=' '{print $2}')

    if [ -z "$domain" ]; then
        echo ""
        echo -e "${red}错误：未找到域名配置${none}"
        echo ""
        return 1
    fi

    echo ""
    echo "========================================="
    echo "  强制续期证书"
    echo -e "${yellow}域名: $domain${none}"
    echo "========================================="
    echo ""

    read -p "确认要强制续期证书吗？[y/N]: " confirm
    if [[ "$confirm" == [Yy] ]]; then
        echo ""
        echo "正在续期..."
        echo ""
        certbot renew --force-renewal --webroot -w /var/www/html

        if [ $? -eq 0 ]; then
            systemctl reload naive 2>/dev/null
            echo ""
            echo "========================================="
            echo -e "${green}✓ 证书强制续期成功！${none}"
            echo "========================================="
            echo ""
        else
            echo ""
            echo "========================================="
            echo -e "${red}✗ 证书续期失败${none}"
            echo "========================================="
            echo ""
        fi
    else
        echo ""
        echo "已取消操作"
        echo ""
    fi
}

start_naive() {
    if [[ -f /usr/bin/caddy && -f /etc/caddy/caddy_config.json ]]; then
        do_service enable naive
        do_service restart naive
        echo ""
        echo -e "${green}启动服务并添加自启动完成${none}"
        echo ""
        echo "服务状态："
        do_service status naive --no-pager
    else
        echo ""
        echo -e "${red}NaiveProxy 未安装${none}"
        echo ""
    fi
}

enable_bbr() {
    clear
    echo ""
    echo "========================================="
    echo "  开启 BBR 加速"
    echo "========================================="
    echo ""

    # bbr 在现代内核中可能内置或为模块，modprobe 失败不代表不支持，故忽略其结果
    modprobe tcp_bbr 2>/dev/null

    # 已开启则直接报告
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        echo -e "${green}✓ BBR 已经处于开启状态${none}"
        echo ""
        echo "当前拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control)"
        echo "当前队列调度算法: $(sysctl -n net.core.default_qdisc)"
        return 0
    fi

    # 检测内核是否支持 bbr
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        echo -e "${red}✗ 当前内核不支持 BBR${none}"
        echo "BBR 需要 Linux 内核 4.9 及以上版本"
        echo "当前内核: $(uname -r)"
        return 1
    fi

    # 写入前先去重，避免重复运行追加多行
    sed -i '/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    # 回读验证是否真正生效
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        echo -e "${green}✓ BBR 开启成功${none}"
        echo ""
        echo "当前拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control)"
        echo "当前队列调度算法: $(sysctl -n net.core.default_qdisc)"
        echo ""
        echo -e "${yellow}提示: BBR 仅对 TCP(HTTP/2) 流量生效，对 HTTP/3(QUIC/UDP) 不适用${none}"
    else
        echo -e "${red}✗ BBR 开启失败，请检查内核支持情况${none}"
        return 1
    fi
}

uninstall_naive() {
    echo ""
    echo -e "${yellow}警告：此操作将完全卸载 NaiveProxy！${none}"
    read -p "$(echo -e "确认卸载？[${red}y/N$none]: ")" confirm

    if [[ "$confirm" != [Yy] ]]; then
        echo "已取消卸载"
        return 0
    fi

    do_service disable naive
    do_service stop naive
    rm -f /etc/systemd/system/naive.service
    rm -rf /usr/bin/caddy /etc/caddy /root/src/caddy-forwardproxy-naive*
    # 清理证书续期定时任务
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v ".renew.sh") | crontab - 2>/dev/null
    fi
    echo ""
    echo -e "${green}NaiveProxy 卸载完成${none}"
    echo ""
}

# ==================== 主程序入口 ====================
while :; do
    clear
    echo
    echo "========================================="
    echo "  NaiveProxy 管理脚本"
    echo "========================================="
    echo
    echo " 1. 安装/更新 Install/Update"
    echo
    echo " 2. 显示信息 Show Info"
    echo
    echo " 3. 修改配置 Edit"
    echo
    echo " 4. 证书详情 Cert Info"
    echo
    echo " 5. 证书续签 Cert Renew"
    echo
    echo " 6. 重启服务 Restart Naive"
    echo
    echo " 7. 卸载 Uninstall Naive"
    echo
    echo " 8. 测试证书续期 Test Cert Renewal"
    echo
    echo " 9. 强制续期证书 Force Renew Cert"
    echo
    echo "10. 开启 BBR 加速 Enable BBR"
    echo
    echo " 0. 退出 Exit"
    echo
    echo "========================================="

    read -p "$(echo -e "请选择 [${magenta}0-10$none]：")" choose
    case $choose in
    1)
        install
        echo ""
        pause
        ;;
    2)
        show_config
        echo ""
        pause
        ;;
    3)
        edit_config
        echo ""
        pause
        ;;
    4)
        check_cert_info
        echo ""
        pause
        ;;
    5)
        cert_renew
        echo ""
        pause
        ;;
    6)
        start_naive
        echo ""
        pause
        ;;
    7)
        uninstall_naive
        ;;
    8)
        test_cert_renew
        echo ""
        pause
        ;;
    9)
        force_cert_renew
        echo ""
        pause
        ;;
    10)
        enable_bbr
        echo ""
        pause
        ;;
    0)
        echo ""
        echo -e "${green}感谢使用！再见~${none}"
        echo ""
        exit 0
        ;;
    *)
        error
        ;;
    esac
done
