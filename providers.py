#!/usr/bin/env python3
"""usage-monitor 数据聚合器 — 查询各 AI 订阅的用量/余额，输出统一 JSON。

层次:
  凭据层  cred() / _OPENCODE / _HERMES / Keychain — 自动复用本机 agent CLI 已配置凭据
  传输层  http_json() — 统一 GET/POST + 超时
  声明层  @provider — 统一注册、缺凭据提示、异常兜底; pct_row() 统一百分比行格式

配置覆盖: ~/.config/usage-monitor/env  (KEY=VALUE, 优先级最高)
输出: {"updated": "HH:MM", "providers": [{id,name,kind,ok,pct,value,detail}]}
"""
import base64
import concurrent.futures as cf
import datetime
import json
import os
import re
import shutil
import subprocess
import urllib.parse
import urllib.request

CONF = os.path.expanduser("~/.config/usage-monitor/env")
STATE = os.path.expanduser("~/.config/usage-monitor/state.json")
TIMEOUT = 8
WEEK = 7 * 24 * 3600 * 1000


# ── 凭据层 ───────────────────────────────────────────────────────────────────

def load_env():
    env = {}
    if os.path.exists(CONF):
        for line in open(CONF):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def _json_file(path):
    try:
        return json.load(open(os.path.expanduser(path)))
    except Exception:
        return {}


ENV = load_env()
_OPENCODE = _json_file("~/.local/share/opencode/auth.json")   # {name: {key}}
_HERMES = _json_file("~/.hermes/auth.json").get("credential_pool", {})


class MissingCred(Exception):
    """凭据缺失（带给用户的提示文本）"""


def cred(env_key, opencode=None, hermes=None, hint=None):
    """优先级: env 文件 > opencode auth > hermes credential_pool；缺失即抛 MissingCred"""
    if ENV.get(env_key):
        return ENV[env_key]
    if opencode and _OPENCODE.get(opencode, {}).get("key"):
        return _OPENCODE[opencode]["key"]
    if hermes:
        pool = _HERMES.get(hermes) or []
        if pool and pool[0].get("access_token"):
            return pool[0]["access_token"]
    raise MissingCred(hint or f"no key: {env_key}")


def jwt_exp(token):
    """JWT 的 exp 声明 (epoch 秒); 解析失败返回 0 (视为已过期)"""
    try:
        return json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "==="))["exp"]
    except Exception:
        return 0


def keychain(service):
    out = subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                         capture_output=True, text=True, timeout=5).stdout.strip()
    if not out:
        raise MissingCred(f"no keychain: {service}")
    return json.loads(out)


# ── 传输层 ───────────────────────────────────────────────────────────────────

def http_json(url, headers=None, data=None, timeout=TIMEOUT):
    req = urllib.request.Request(url, headers=headers or {}, data=data,
                                 method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


# ── 声明层 ───────────────────────────────────────────────────────────────────

PROVIDERS = []


def row(pid, name, kind="balance", ok=False, pct=None, value="—", detail="", tone=None, wins=None, cval=None):
    return {"id": pid, "name": name, "kind": kind, "ok": ok,
            "pct": pct, "value": value, "detail": detail, "tone": tone,
            "wins": wins or [], "cval": cval}


def provider(pid, name):
    """注册 provider；统一处理缺凭据与异常，函数只需返回 row 或抛异常"""
    def deco(fn):
        def wrapper():
            try:
                return fn()
            except MissingCred as e:
                return row(pid, name, kind="missing", detail=str(e))
            except Exception as e:
                return row(pid, name, detail=f"err: {type(e).__name__}")
        wrapper.pid = pid
        PROVIDERS.append(wrapper)
        return wrapper
    return deco


def win(label, pct, reset=None, text=None, left_ms=None, window_ms=None):
    """一个限额窗口: dict 结构 (供 wins 数组 + 显示串两用)；pct 为 None 时返回 None
    text 覆盖列表模式的显示串 (如 MCP 配额显示计数而非百分比)
    给出 left_ms+window_ms 时附带 pace 速度评级"""
    if pct is None:
        return None
    return {"label": label, "pct": round(pct), "reset": reset, "text": text,
            "tone": pace(pct, left_ms, window_ms) if left_ms and window_ms else None}


def win_str(w):
    return w.get("text") or (f"{w['label']} {w['pct']}%" + (f" /{w['reset']}" if w["reset"] else ""))


def pace(pct, left_ms, window_ms):
    """预计耗尽时间 vs 重置时间 (同 Claude Code 状态栏):
    ratio ≥1.5 green, ≥1.0 yellow, ≥0.5 orange, <0.5 red; 窗口刚开始不评估"""
    if not left_ms or left_ms <= 0:
        return None
    elapsed = window_ms - left_ms
    if elapsed < window_ms / 60:   # 预热期不评估 (5h 窗口=5min, 7d 窗口=2.8h)
        return None
    if pct <= 0:
        return "green"
    ratio = elapsed * (100 - pct) / pct / left_ms
    return ("green" if ratio >= 1.5 else "yellow" if ratio >= 1.0
            else "orange" if ratio >= 0.5 else "red")


def pct_row(pid, name, used5, reset_ms=None, *details,
            main_label="5h", main_window_ms=5 * 3600 * 1000, cval=None):
    """百分比类订阅的统一行: 主值为 5h 窗口(按消耗速度配色), 次行 ' · ' 连接
    details 中的 win() dict 进入 wins 数组(圆环视图用), 字符串作为备注
    cval: 紧凑模式补充串 (圆环悬停框追加一行, 如 Claude 的美元超额)"""
    wins = [win(main_label, used5, fmt_ms(reset_ms) if reset_ms else None,
                left_ms=reset_ms, window_ms=main_window_ms)]
    wins += [d for d in details if isinstance(d, dict)]
    return row(pid, name, "percent", True, pct=round(used5),
               value=win_str(wins[0]),
               detail=" · ".join(win_str(d) if isinstance(d, dict) else str(d)
                                 for d in details if d),
               tone=wins[0]["tone"], wins=wins, cval=cval)


def fmt_ms(ms):
    """自适应单位: <1h → '45m', <6h → '2.5h', <24h → '8h', 其余 → '3d'"""
    m = int(ms / 60000)
    if m < 60:
        return f"{m}m"
    if m < 6 * 60:
        return f"{round(m / 60, 1):g}h"
    h = round(m / 60)
    return f"{h}h" if h < 24 else f"{round(h / 24)}d"


def window_label(seconds):
    """窗口秒数 → 短标签；未知时仍按 5h 兜底"""
    if not seconds:
        return "5h"
    if seconds % (24 * 3600) == 0:
        d = seconds // (24 * 3600)
        if 28 <= d <= 31:
            return "mo"
        return "7d" if d == 7 else f"{d}d"
    if seconds % 3600 == 0:
        return f"{seconds // 3600}h"
    return fmt_ms(seconds * 1000)


def day_spend(pid, balance):
    """余额差值法估算今日消耗: 每日首次轮询记基线; 余额回升(充值)则重置基线"""
    s = _json_file(STATE)
    today = datetime.date.today().isoformat()
    e = s.get(pid) or {}
    if e.get("date") != today or balance > e.get("baseline", 0):
        s[pid] = {"date": today, "baseline": balance}
        json.dump(s, open(STATE, "w"))
        return 0.0
    return e["baseline"] - balance


def ms_left(ts_ms):
    """毫秒时间戳 → 距现在的剩余毫秒数"""
    return max(ts_ms - datetime.datetime.now().timestamp() * 1000, 0)


def ms_left_iso(s):
    """ISO8601 (含 Z 后缀) → 剩余毫秒数"""
    return ms_left(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000)


# ── providers ────────────────────────────────────────────────────────────────

@provider("deepseek", "DeepSeek")
def p_deepseek():
    key = cred("DEEPSEEK_API_KEY", opencode="deepseek")
    d = http_json("https://api.deepseek.com/user/balance",
                  {"Authorization": f"Bearer {key}"})
    b = (d.get("balance_infos") or [{}])[0]
    cur = "¥" if b.get("currency") == "CNY" else b.get("currency", "")
    total = float(b.get("total_balance") or 0)
    spend = day_spend("deepseek", total)
    # 紧凑模式(圆环/条状)pill 显示今日消耗(带负号, 与 detail 一致) 而非总余额; 余额仍在 value/悬停 tooltip
    return row("deepseek", "DeepSeek", "balance", True,
               value=f"{cur}{total:.2f}",
               detail=f"today -{cur}{spend:.2f}"
                      + ("" if d.get("is_available", True) else " · unavailable"),
               cval=f"-{cur}{spend:.2f}")


@provider("claude", "Claude")
def p_claude():
    kc = keychain("Claude Code-credentials")["claudeAiOauth"]
    d = http_json("https://api.anthropic.com/api/oauth/usage",
                  {"Authorization": f"Bearer {kc['accessToken']}",
                   "anthropic-beta": "oauth-2025-04-20",
                   "User-Agent": "claude-code/2.0.0",   # 必须：否则进入严格限流桶
                   "Content-Type": "application/json"})
    fh, sd = d.get("five_hour") or {}, d.get("seven_day") or {}
    if fh.get("utilization") is None:
        return row("claude", "Claude", detail="schema changed")
    # rateLimitTier 形如 default_claude_max_20x → 把倍率拼进订阅名: 'max 20x'
    sub = kc.get("subscriptionType") or ""
    mult = (kc.get("rateLimitTier") or "").rsplit("_", 1)[-1]
    if mult.endswith("x") and mult[:-1].isdigit():
        sub = f"{sub} {mult}"
    sleft = ms_left_iso(sd["resets_at"]) if sd.get("resets_at") else None
    # extra_usage = 订阅外按量付费额度 (随消耗累加, 比限流%更"活"); 仅开启时显示
    eu = d.get("extra_usage") or {}
    extra = None
    if eu.get("is_enabled") and eu.get("monthly_limit"):
        # 金额按 decimal_places 缩放: 接口给的是最小单位(美分), 除 10^dp 得美元
        scale = 10 ** eu.get("decimal_places", 0)
        used, lim = float(eu.get("used_credits") or 0) / scale, float(eu["monthly_limit"]) / scale
        cur = "$" if eu.get("currency") == "USD" else (eu.get("currency") or "")
        extra = f"{cur}{used:.2f}/{cur}{lim:.0f}"
    return pct_row("claude", "Claude", fh["utilization"],
                   ms_left_iso(fh["resets_at"]) if fh.get("resets_at") else None,
                   win("7d", sd.get("utilization"), fmt_ms(sleft) if sleft else None,
                       left_ms=sleft, window_ms=WEEK),
                   sub, extra, cval=extra)


@provider("glm", "GLM")
def p_glm():
    # z.ai coding plan 配额（注意 Authorization 不加 Bearer）
    key = cred("GLM_API_KEY", opencode="zai-coding-plan", hermes="zai")
    d = http_json("https://api.z.ai/api/monitor/usage/quota/limit",
                  {"Authorization": key, "Accept-Language": "en-US,en",
                   "Content-Type": "application/json"})
    data = d.get("data") or {}
    limits = {l.get("type"): l for l in data.get("limits") or []}
    tok = limits.get("TOKENS_LIMIT")
    mcp = limits.get("TIME_LIMIT")   # MCP 工具月度配额: currentValue=已用, usage=上限
    if not tok:
        return row("glm", "GLM", detail="no quota data")
    return pct_row("glm", "GLM", tok.get("percentage") or 0,
                   ms_left(tok["nextResetTime"]) if tok.get("nextResetTime") else None,
                   data.get("level"),
                   win("MCP", mcp["currentValue"] * 100 / mcp["usage"],
                       text=f"MCP/mo {mcp['currentValue']}/{mcp['usage']}")
                   if mcp and mcp.get("usage") else None)


@provider("minimax", "MiniMax")
def p_minimax():
    key = cred("MINIMAX_API_KEY", opencode="minimax-cn-coding-plan", hermes="minimax-cn")
    d = http_json("https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains",
                  {"Authorization": f"Bearer {key}",
                   "Referer": "https://platform.minimaxi.com/", "Accept": "application/json"})
    if (d.get("base_resp") or {}).get("status_code") not in (0, None):
        return row("minimax", "MiniMax",
                   detail=f"err: {(d.get('base_resp') or {}).get('status_msg', '?')}")
    m = (d.get("model_remains") or [{}])[0]
    # 接口返回『剩余%』→ 转已用%
    return pct_row("minimax", "MiniMax",
                   100 - (m.get("current_interval_remaining_percent") or 100),
                   m.get("remains_time"),
                   win("wk", 100 - (m.get("current_weekly_remaining_percent") or 100),
                       fmt_ms(m["weekly_remains_time"]) if m.get("weekly_remains_time") else None,
                       left_ms=m.get("weekly_remains_time"), window_ms=WEEK))


# codex CLI 的公开 OAuth client (官方源码 login/src/auth/manager.rs)
_CODEX_CLIENT = "app_EMoamEEZ73f0CkXaXp7hrann"


@provider("codex", "Codex")
def p_codex():
    path = os.path.expanduser("~/.codex/auth.json")
    auth = _json_file(path)
    tokens = auth.get("tokens") or {}
    if not tokens.get("access_token"):
        raise MissingCred("codex not logged in")
    # access_token (JWT) ~10 天过期: 临期则用 refresh_token 静默换新并回写 (与 CLI 共用凭据文件)
    if jwt_exp(tokens["access_token"]) < datetime.datetime.now().timestamp() + 60:
        try:
            tok = http_json("https://auth.openai.com/oauth/token",
                            {"Content-Type": "application/json"},
                            data=json.dumps({"client_id": _CODEX_CLIENT,
                                             "grant_type": "refresh_token",
                                             "refresh_token": tokens["refresh_token"]}).encode())
        except Exception:
            raise MissingCred("codex re-login needed")
        tokens.update({k: tok[k] for k in ("access_token", "id_token", "refresh_token")
                       if tok.get(k)})
        auth["tokens"] = tokens
        auth["last_refresh"] = datetime.datetime.now(datetime.timezone.utc) \
            .isoformat().replace("+00:00", "Z")
        json.dump(auth, open(path, "w"), indent=2)
    d = http_json("https://chatgpt.com/backend-api/wham/usage",
                  {"Authorization": f"Bearer {tokens['access_token']}",
                   "ChatGPT-Account-Id": tokens.get("account_id", ""),
                   "User-Agent": "codex-cli"})
    rl = d.get("rate_limit") or {}
    pw, sw = rl.get("primary_window") or {}, rl.get("secondary_window") or {}
    if pw.get("used_percent") is None:
        return row("codex", "Codex", detail=d.get("plan_type", "no data"))
    pwin_ms = (pw.get("limit_window_seconds") or 5 * 3600) * 1000
    sleft = ms_left(sw["reset_at"] * 1000) if sw.get("reset_at") else None
    return pct_row("codex", "Codex", pw["used_percent"],
                   ms_left(pw["reset_at"] * 1000) if pw.get("reset_at") else None,
                   win("7d", sw.get("used_percent"), fmt_ms(sleft) if sleft else None,
                       left_ms=sleft, window_ms=WEEK),
                   d.get("plan_type"),
                   main_label=window_label(pw.get("limit_window_seconds")),
                   main_window_ms=pwin_ms)


# grok CLI 公开 OIDC token 端点 (issuer https://auth.x.ai well-known)
_GROK_TOKEN = "https://auth.x.ai/oauth2/token"
_GROK_BILLING = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
_GROK_SETTINGS = "https://cli-chat-proxy.grok.com/v1/settings"


def grok_home():
    return os.path.expanduser(os.environ.get("GROK_HOME") or "~/.grok")


def grok_cred_slot(auth):
    """优先 https://auth.x.ai::<client-id> 的 grok login 槽; 否则退第一条带 key 的。"""
    slots = [(k, v) for k, v in (auth or {}).items()
             if isinstance(v, dict) and v.get("key")]
    if not slots:
        raise MissingCred("run grok login once")
    preferred = [s for s in slots if str(s[0]).startswith("https://auth.x.ai::")]
    return (preferred or slots)[0]


def grok_plan_name(raw):
    if raw is None:
        return None
    s = str(raw).strip()
    if not s:
        return None
    token = "".join(c for c in s.lower() if c.isalpha())
    if token in ("supergrokheavy", "heavy"):
        return "SuperGrok Heavy"
    if token == "supergrok":
        return "SuperGrok"
    return s


def grok_from_credits(billing, settings=None):
    """CLI-proxy credits JSON → 统一 pct_row。对应 Grok Build /usage 的 Usage limit。

    主窗口按 currentPeriod 长度标 7d/mo, 不是 5h。percent 缺省但有周期 → 0%
    (SuperGrok Heavy 刚重置时 billing 会省略 creditUsagePercent)。
    """
    cfg = (billing or {}).get("config") or {}
    period = cfg.get("currentPeriod") or {}
    start = period.get("start") or cfg.get("billingPeriodStart")
    end = period.get("end") or cfg.get("billingPeriodEnd")
    used = cfg.get("creditUsagePercent")
    if used is None:
        cap = (cfg.get("onDemandCap") or {}).get("val") or 0
        od = (cfg.get("onDemandUsed") or {}).get("val")
        if cap > 0 and od is not None:
            used = od / cap * 100
        elif end:
            used = 0
        else:
            return row("grok", "Grok", detail="no quota data")
    window_ms = WEEK
    if start and end:
        try:
            a = datetime.datetime.fromisoformat(start.replace("Z", "+00:00"))
            b = datetime.datetime.fromisoformat(end.replace("Z", "+00:00"))
            window_ms = max((b - a).total_seconds() * 1000, 1)
        except Exception:
            window_ms = WEEK
    plan = (grok_plan_name((settings or {}).get("subscription_tier_display"))
            or grok_plan_name(cfg.get("subscriptionTier"))
            or grok_plan_name((billing or {}).get("subscriptionTier")))
    return pct_row("grok", "Grok", used,
                   ms_left_iso(end) if end else None, plan,
                   main_label=window_label(window_ms / 1000),
                   main_window_ms=window_ms)


def grok_headers(token):
    return {"Authorization": f"Bearer {token}",
            "x-xai-token-auth": "xai-grok-cli",
            "Accept": "application/json"}


def grok_refresh(auth, slot, path):
    """临期则 OIDC refresh_token 换新并回写 ~/.grok/auth.json (与 grok CLI 共用)。"""
    key, entry = slot
    token = entry.get("key")
    exp = 0
    if entry.get("expires_at"):
        try:
            exp = datetime.datetime.fromisoformat(
                entry["expires_at"].replace("Z", "+00:00")).timestamp()
        except Exception:
            exp = 0
    if not exp and token:
        exp = jwt_exp(token)
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    if token and exp > now + 60:
        return token
    rt, cid = entry.get("refresh_token"), entry.get("oidc_client_id")
    if not rt or not cid:
        raise MissingCred("grok re-login needed")
    try:
        tok = http_json(_GROK_TOKEN,
                        {"Content-Type": "application/x-www-form-urlencoded"},
                        data=urllib.parse.urlencode({
                            "grant_type": "refresh_token",
                            "refresh_token": rt,
                            "client_id": cid,
                        }).encode())
    except Exception:
        raise MissingCred("grok re-login needed")
    if not tok.get("access_token"):
        raise MissingCred("grok re-login needed")
    entry["key"] = tok["access_token"]
    if tok.get("refresh_token"):
        entry["refresh_token"] = tok["refresh_token"]
    ttl = tok.get("expires_in") or 6 * 3600
    entry["expires_at"] = datetime.datetime.fromtimestamp(
        now + ttl, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    auth[key] = entry
    json.dump(auth, open(path, "w"), indent=2)
    return entry["key"]


@provider("grok", "Grok")
def p_grok():
    path = os.path.join(grok_home(), "auth.json")
    auth = _json_file(path)
    token = grok_refresh(auth, grok_cred_slot(auth), path)
    headers = grok_headers(token)
    billing = http_json(_GROK_BILLING, headers)
    try:
        settings = http_json(_GROK_SETTINGS, headers)
    except Exception:
        settings = {}
    return grok_from_credits(billing, settings)


def _gemini_clients():
    """返回 [(client_id, client_secret), ...] 候选列表, 运行时从本机 agy (Antigravity CLI,
    gemini-cli 2026-06-18 停服后的继任者) 优先, 回退旧 gemini-cli node 包。
    installed-app 凭据公开, 但 GitHub push protection 按模式拦截 secret, 故不内置源码;
    refresh_token 与签发它的 client 绑定, agy 复用 gemini-cli 的 client, 多候选时逐个尝试刷新"""
    out = []
    # 1. agy (Go 二进制) — 相邻 secret 在二进制里可能粘连, 按 GOCSPX- 前缀切分
    agy = shutil.which("agy") or os.path.expanduser("~/.local/bin/agy")
    if agy and os.path.exists(agy):
        try:
            raw = open(agy, "rb").read()
            ids = [i.decode() for i in re.findall(rb"\d+-[a-z0-9]+\.apps\.googleusercontent\.com", raw)]
            secs = []
            for b in re.findall(rb"GOCSPX-[A-Za-z0-9_-]+", raw):
                secs += [s.decode() for s in re.split(rb"(?=GOCSPX-)", b) if s.startswith(b"GOCSPX-")]
            out += [(i, s) for i in ids for s in secs]
        except Exception:
            pass
    # 2. 回退: 旧 gemini-cli (node 包) — 遍历包目录 grep .js 分片
    for gp in [shutil.which("gemini"), "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"]:
        if not gp or not os.path.exists(gp):
            continue
        root = os.path.dirname(os.path.dirname(os.path.realpath(gp)))
        for dirpath, _, files in os.walk(root):
            for fn in files:
                if not fn.endswith((".js", ".cjs", ".mjs")):
                    continue
                src = open(os.path.join(dirpath, fn), errors="ignore").read()
                sec = re.search(r"GOCSPX-[\w-]+", src)
                if not sec:
                    continue
                ids = [m.group() for m in re.finditer(r"\d+-[a-z0-9]+\.apps\.googleusercontent\.com", src)]
                out += [(i, sec.group()) for i in ids]
        break
    if not out:
        raise MissingCred("agy / gemini CLI not found")
    seen = set()
    return [c for c in out if not (c in seen or seen.add(c))]


@provider("gemini", "Gemini")
def p_gemini():
    path = os.path.expanduser("~/.gemini/oauth_creds.json")
    creds = _json_file(path)
    if not creds.get("refresh_token"):
        raise MissingCred("run gemini CLI login once")
    # access_token 1h 过期: 临期则用 refresh_token 静默换新并回写 (与 agy/gemini-cli 共用凭据文件)
    now_ms = datetime.datetime.now().timestamp() * 1000
    if creds.get("expiry_date", 0) < now_ms + 60000:
        tok = None
        for cid, csecret in _gemini_clients():   # 多候选逐个试, refresh_token 只在匹配的 client 上刷成
            try:
                tok = http_json("https://oauth2.googleapis.com/token",
                                {"Content-Type": "application/x-www-form-urlencoded"},
                                data=urllib.parse.urlencode({
                                    "grant_type": "refresh_token",
                                    "refresh_token": creds["refresh_token"],
                                    "client_id": cid,
                                    "client_secret": csecret}).encode())
                break
            except Exception:
                continue
        if not tok:
            raise MissingCred("gemini/agy re-login needed")
        creds.update(access_token=tok["access_token"],
                     expiry_date=int(now_ms + tok.get("expires_in", 3600) * 1000))
        json.dump(creds, open(path, "w"))
    d = http_json("https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
                  {"Authorization": f"Bearer {creds['access_token']}",
                   "Content-Type": "application/json"}, data=b"{}")
    buckets = d.get("userQuotaBuckets") or d.get("buckets") or []
    if not buckets:
        return row("gemini", "Gemini", detail="no data (token expired?)")
    frac = min((b.get("remainingFraction", 1) for b in buckets), default=1)
    return pct_row("gemini", "Gemini", (1 - frac) * 100, None, "Code Assist")


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    with cf.ThreadPoolExecutor(len(PROVIDERS)) as ex:
        out = list(ex.map(lambda p: p(), PROVIDERS))
    # 本机没配凭据的订阅直接隐藏 (面板自适应); 真实错误仍显示
    out = [r for r in out if r["kind"] != "missing"]
    order = ["claude", "codex", "grok", "glm", "minimax", "gemini", "deepseek"]
    out.sort(key=lambda r: order.index(r["id"]) if r["id"] in order else 99)
    payload = json.dumps({
        "updated": datetime.datetime.now().strftime("%H:%M"),
        "providers": out,
    }, ensure_ascii=False)
    print(payload)
    # 同步写缓存，供 bridge /usage 端点（手表）读取
    try:
        open(os.path.join(os.path.dirname(STATE), "usage.json"), "w").write(payload)
    except OSError:
        pass


if __name__ == "__main__":
    main()
