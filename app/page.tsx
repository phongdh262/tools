"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";

type ToolId = "dns" | "ssl" | "domain" | "headers" | "mail" | "propagation";
type DnsView = "overview" | "A" | "AAAA" | "MX" | "NS" | "TXT" | "CAA" | "email";

type DnsAnswer = { name: string; type: number; TTL: number; data: string };

type ScanResult = {
  domain: string;
  duration: number;
  score: number;
  dns: Record<string, DnsAnswer[]>;
  mailCname: DnsAnswer[];
  googleA: DnsAnswer[];
  rdap?: {
    registrar: string;
    created: string;
    expires: string;
    statuses: string[];
  };
  https: {
    reachable: boolean;
    headers: Record<string, string>;
  };
};

const tools: Array<{
  id: ToolId;
  number: string;
  label: string;
  short: string;
  description: string;
  accent: string;
}> = [
  {
    id: "dns",
    number: "01",
    label: "DNS Lookup",
    short: "DNS",
    description: "Phân tích A, AAAA, MX, NS, TXT và CAA theo thời gian thực.",
    accent: "blue",
  },
  {
    id: "ssl",
    number: "02",
    label: "SSL Check",
    short: "SSL",
    description: "Kiểm tra kết nối HTTPS, CAA và các tín hiệu bảo mật cốt lõi.",
    accent: "cyan",
  },
  {
    id: "domain",
    number: "03",
    label: "Domain WHOIS",
    short: "WHOIS",
    description: "Tra cứu registrar, ngày đăng ký, hết hạn và trạng thái tên miền.",
    accent: "violet",
  },
  {
    id: "headers",
    number: "04",
    label: "HTTP Headers",
    short: "HTTP",
    description: "Đọc các header phản hồi và phát hiện lớp bảo vệ phía máy chủ.",
    accent: "orange",
  },
  {
    id: "mail",
    number: "05",
    label: "Email Security",
    short: "MAIL",
    description: "Kiểm tra MX, SPF và DMARC để giảm nguy cơ giả mạo email.",
    accent: "green",
  },
  {
    id: "propagation",
    number: "06",
    label: "DNS Propagation",
    short: "GLOBAL",
    description: "Đối chiếu kết quả phân giải giữa nhiều nhà cung cấp DNS công cộng.",
    accent: "pink",
  },
];

const recordTypes = ["A", "AAAA", "MX", "NS", "TXT", "CAA"] as const;
const dnsViews: Array<{ value: DnsView; label: string }> = [
  { value: "overview", label: "Tổng quan DNS" },
  { value: "A", label: "A — IPv4" },
  { value: "AAAA", label: "AAAA — IPv6" },
  { value: "MX", label: "MX — Mail server" },
  { value: "NS", label: "NS — Nameserver" },
  { value: "TXT", label: "TXT records" },
  { value: "CAA", label: "CAA — Certificate" },
  { value: "email", label: "Email Health" },
];

function normalizeDomain(value: string) {
  return value
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/^www\./, "")
    .split("/")[0]
    .split(":")[0]
    .replace(/\.$/, "");
}

function isDomain(value: string) {
  return /^(?=.{3,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i.test(
    value,
  );
}

function cleanRecord(value: string) {
  return value.replace(/^"|"$/g, "").replace(/\\"/g, '"');
}

function readableDate(value?: string) {
  if (!value) return "Chưa công bố";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("vi-VN", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(date);
}

function getEvent(rdap: any, action: string) {
  return rdap?.events?.find((event: any) => event.eventAction === action)?.eventDate || "";
}

function getRegistrar(rdap: any) {
  const entity = rdap?.entities?.find((item: any) =>
    item.roles?.some((role: string) => role === "registrar"),
  );
  const fn = entity?.vcardArray?.[1]?.find((item: any[]) => item[0] === "fn");
  return fn?.[3] || entity?.handle || "Chưa công bố";
}

function withTimeout(ms = 9000) {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), ms);
  return { controller, clear: () => window.clearTimeout(timer) };
}

async function queryDns(name: string, type: string, provider: "cloudflare" | "google" = "cloudflare") {
  const endpoint =
    provider === "cloudflare"
      ? `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(name)}&type=${type}`
      : `https://dns.google/resolve?name=${encodeURIComponent(name)}&type=${type}`;
  const timeout = withTimeout();
  try {
    const response = await fetch(endpoint, {
      headers: { Accept: "application/dns-json" },
      signal: timeout.controller.signal,
    });
    if (!response.ok) return [];
    const data = await response.json();
    return (data.Answer || []) as DnsAnswer[];
  } catch {
    return [];
  } finally {
    timeout.clear();
  }
}

async function inspectHttps(domain: string) {
  const timeout = withTimeout();
  try {
    const response = await fetch(`https://${domain}`, {
      method: "HEAD",
      signal: timeout.controller.signal,
    });
    return {
      reachable: true,
      headers: Object.fromEntries(response.headers.entries()),
    };
  } catch {
    try {
      await fetch(`https://${domain}`, { mode: "no-cors", signal: timeout.controller.signal });
      return { reachable: true, headers: {} };
    } catch {
      return { reachable: false, headers: {} };
    }
  } finally {
    timeout.clear();
  }
}

function ResultIcon({ ok }: { ok: boolean }) {
  return <span className={ok ? "status-icon ok" : "status-icon warn"}>{ok ? "✓" : "!"}</span>;
}

function RubikLogo() {
  return <span className="rubik-mark" aria-hidden="true">{Array.from({ length: 9 }, (_, index) => <i key={index} />)}</span>;
}

function DnsRecordsPanel({ dns, view }: { dns: Record<string, DnsAnswer[]>; view: DnsView }) {
  const visibleTypes = view === "overview" ? recordTypes : [view as (typeof recordTypes)[number]];

  return (
    <div className="dns-record-groups">
      {visibleTypes.map((type) => {
        const records = dns[type] || [];
        return (
          <section className="dns-record-group" key={type}>
            <header>
              <div><span className="record-type">{type}</span><strong>{type === "A" ? "IPv4 address" : type === "AAAA" ? "IPv6 address" : type === "MX" ? "Mail exchange" : type === "NS" ? "Authoritative nameserver" : type === "TXT" ? "Text policy" : "Certificate authority"}</strong></div>
              <em>{records.length} RECORD{records.length === 1 ? "" : "S"}</em>
            </header>
            {records.length ? records.map((record, index) => (
              <div className="dns-record-row" key={`${record.data}-${index}`}>
                <code>{cleanRecord(record.data)}</code>
                <span>TTL {record.TTL}s</span>
              </div>
            )) : (
              <div className="dns-empty-row"><ResultIcon ok={false} /><span>Không tìm thấy bản ghi {type}</span></div>
            )}
          </section>
        );
      })}
      <div className="dns-source-note"><span>◎</span><p>Dữ liệu trực tiếp từ Cloudflare DNS. Kết quả cục bộ có thể khác cho đến khi TTL hết hạn.</p></div>
    </div>
  );
}

export default function Home() {
  const [theme, setTheme] = useState<"dark" | "light">("dark");
  const [domain, setDomain] = useState("phongdinh.info.vn");
  const [activeTool, setActiveTool] = useState<ToolId>("dns");
  const [scanning, setScanning] = useState(false);
  const [error, setError] = useState("");
  const [result, setResult] = useState<ScanResult | null>(null);
  const [progress, setProgress] = useState(0);
  const [dnsView, setDnsView] = useState<DnsView>("email");
  const [dkimSelector, setDkimSelector] = useState("default");
  const [dkimResult, setDkimResult] = useState<{ loading: boolean; records: DnsAnswer[] | null; host: string }>({
    loading: false,
    records: null,
    host: "",
  });

  const active = tools.find((tool) => tool.id === activeTool) || tools[0];

  useEffect(() => {
    const saved = window.localStorage.getItem("nexa-theme");
    if (saved === "dark" || saved === "light") {
      setTheme(saved);
      return;
    }
    setTheme(window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  }, []);

  function toggleTheme() {
    const nextTheme = theme === "dark" ? "light" : "dark";
    setTheme(nextTheme);
    window.localStorage.setItem("nexa-theme", nextTheme);
  }

  const summary = useMemo(() => {
    if (!result) return null;
    const txt = result.dns.TXT || [];
    const mx = result.dns.MX || [];
    const dmarc = result.dns.DMARC || [];
    const ips = (result.dns.A || []).map((item) => item.data);
    const googleIps = result.googleA.map((item) => item.data);
    return {
      spf: txt.some((item) => item.data.toLowerCase().includes("v=spf1")),
      dmarc: dmarc.some((item) => item.data.toLowerCase().includes("v=dmarc1")),
      mx: mx.length > 0,
      propagated: ips.length > 0 && ips.some((ip) => googleIps.includes(ip)),
      records: Object.values(result.dns).reduce((total, list) => total + list.length, 0),
    };
  }, [result]);

  async function runScan(event?: FormEvent) {
    event?.preventDefault();
    const target = normalizeDomain(domain);
    if (!isDomain(target)) {
      setError("Hãy nhập tên miền hợp lệ, ví dụ: nexatools.vn");
      return;
    }

    setDomain(target);
    setError("");
    setScanning(true);
    setProgress(10);
    setDkimResult({ loading: false, records: null, host: "" });
    const startedAt = performance.now();

    try {
      const progressTimer = window.setInterval(
        () => setProgress((value) => Math.min(value + Math.ceil(Math.random() * 8), 88)),
        260,
      );

      const dnsPromises = recordTypes.map(async (type) => [type, await queryDns(target, type)] as const);
      const [dnsEntries, dmarc, googleA, rdapResponse, https] = await Promise.all([
        Promise.all(dnsPromises),
        queryDns(`_dmarc.${target}`, "TXT"),
        queryDns(target, "A", "google"),
        fetch(`https://rdap.org/domain/${encodeURIComponent(target)}`).then((res) =>
          res.ok ? res.json() : null,
        ).catch(() => null),
        inspectHttps(target),
      ]);

      window.clearInterval(progressTimer);
      const dns = Object.fromEntries(dnsEntries) as Record<string, DnsAnswer[]>;
      dns.DMARC = dmarc;
      const mxHosts = (dns.MX || [])
        .map((record) => record.data.trim().split(/\s+/).pop()?.replace(/\.$/, ""))
        .filter((host): host is string => Boolean(host));
      const mailCname = (await Promise.all(mxHosts.slice(0, 5).map((host) => queryDns(host, "CNAME")))).flat();
      const rdap = rdapResponse
        ? {
            registrar: getRegistrar(rdapResponse),
            created: getEvent(rdapResponse, "registration"),
            expires: getEvent(rdapResponse, "expiration"),
            statuses: rdapResponse.status || [],
          }
        : undefined;

      const hasSpf = (dns.TXT || []).some((item) => item.data.toLowerCase().includes("v=spf1"));
      const hasDmarc = dmarc.some((item) => item.data.toLowerCase().includes("v=dmarc1"));
      const propagated = (dns.A || []).some((item) => googleA.some((other) => other.data === item.data));
      const score = Math.min(
        100,
        30 +
          (dns.A?.length ? 10 : 0) +
          (dns.NS?.length ? 10 : 0) +
          (dns.MX?.length ? 8 : 0) +
          (hasSpf ? 10 : 0) +
          (hasDmarc ? 12 : 0) +
          (https.reachable ? 15 : 0) +
          (propagated ? 5 : 0),
      );

      setProgress(100);
      setResult({
        domain: target,
        duration: Math.max(0.2, (performance.now() - startedAt) / 1000),
        score,
        dns,
        mailCname,
        googleA,
        rdap,
        https,
      });
      window.setTimeout(() => setScanning(false), 340);
    } catch {
      setError("Không thể hoàn tất lần kiểm tra này. Vui lòng thử lại sau.");
      setScanning(false);
      setProgress(0);
    }
  }

  async function checkDkim(event: FormEvent) {
    event.preventDefault();
    if (!result) return;
    const selector = dkimSelector.trim().toLowerCase().replace(/^\.+|\.+$/g, "");
    if (!selector || !/^[a-z0-9._-]+$/.test(selector)) {
      setDkimResult({ loading: false, records: [], host: "Selector không hợp lệ" });
      return;
    }
    const host = selector.includes("._domainkey.")
      ? selector
      : selector.endsWith("._domainkey")
        ? `${selector}.${result.domain}`
        : `${selector}._domainkey.${result.domain}`;
    setDkimResult({ loading: true, records: null, host });
    const records = await queryDns(host, "TXT");
    setDkimResult({ loading: false, records, host });
  }

  function selectTool(id: ToolId) {
    setActiveTool(id);
    document.getElementById("scanner")?.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  return (
    <main className={`app-theme ${theme}`}>
      <section className="hero" id="home">
        <div className="hero-grid" aria-hidden="true" />
        <div className="orb orb-one" aria-hidden="true" />
        <div className="orb orb-two" aria-hidden="true" />
        <div className="beam beam-a" aria-hidden="true" />
        <div className="beam beam-b" aria-hidden="true" />

        <header className="nav-shell">
          <a className="brand" href="#home" aria-label="TwoK TOOLS — Trang chủ">
            <RubikLogo />
            <span className="brand-name">TwoK <span className="brand-muted">TOOLS</span></span>
          </a>
          <nav className="desktop-nav" aria-label="Điều hướng chính">
            <a href="#tools">Công cụ</a>
            <a href="#workflow">Hệ thống</a>
            <a href="#insights">Tài nguyên</a>
          </nav>
          <div className="nav-actions">
            <button className="theme-toggle" type="button" onClick={toggleTheme} aria-label={`Chuyển sang giao diện ${theme === "dark" ? "sáng" : "tối"}`} aria-pressed={theme === "light"}>
              <span aria-hidden="true">{theme === "dark" ? "☀" : "☾"}</span>
              {theme === "dark" ? "Light" : "Dark"}
            </button>
            <a className="nav-cta" href="#scanner">Kiểm tra <b>↗</b></a>
          </div>
        </header>

        <div className="hero-content">
          <div className="eyebrow"><span>◆</span> INTERNET INTELLIGENCE SUITE</div>
          <h1>
            Hiểu mọi tín hiệu<br />
            <span className="gradient-text">trước khi có sự cố.</span>
          </h1>
          <p className="hero-copy">
            Một nơi duy nhất để kiểm tra DNS, SSL, tên miền và cấu hình bảo mật—
            nhanh, rõ ràng, không cần đăng ký.
          </p>

          <form className="hero-search" onSubmit={runScan}>
            <span className="search-prefix">//</span>
            <label className="sr-only" htmlFor="hero-domain">Tên miền cần kiểm tra</label>
            <input
              id="hero-domain"
              value={domain}
              onChange={(event) => setDomain(event.target.value)}
              placeholder="Nhập tên miền, ví dụ nexatools.vn"
              autoComplete="url"
              spellCheck={false}
            />
            <button type="submit" disabled={scanning}>
              {scanning ? "Đang quét" : "Quét toàn diện"}<span>↗</span>
            </button>
          </form>
          {error && <p className="form-error" role="alert">{error}</p>}

          <div className="hero-meta" aria-label="Thông số dịch vụ">
            <span><b>06</b> BỘ KIỂM TRA</span>
            <span><b>&lt;2s</b> PHẢN HỒI DNS</span>
            <span><b>24/7</b> SẴN SÀNG</span>
          </div>
        </div>

        <div className="floating-card card-dns" aria-hidden="true">
          <span className="floating-label">DNS RESOLVER</span>
          <b>104.21.7.92</b>
          <small><i /> RESOLVED · 34ms</small>
        </div>
        <div className="floating-card card-ssl" aria-hidden="true">
          <div className="grade">A+</div>
          <div><span className="floating-label">SSL GRADE</span><b>Secure connection</b></div>
        </div>
        <div className="scroll-cue" aria-hidden="true"><span>SCROLL TO EXPLORE</span><i /></div>
      </section>

      <section className="tools-section" id="tools">
        <div className="section-intro">
          <div>
            <span className="section-kicker">01 / BỘ CÔNG CỤ</span>
            <h2>Mọi lớp tín hiệu.<br /><em>Một góc nhìn.</em></h2>
          </div>
          <p>Chọn từng lớp hạ tầng cần phân tích hoặc chạy một lần quét toàn diện để có bức tranh hoàn chỉnh.</p>
        </div>

        <div className="tool-grid">
          {tools.map((tool) => (
            <button
              key={tool.id}
              type="button"
              className={`tool-card ${activeTool === tool.id ? "active" : ""}`}
              onClick={() => selectTool(tool.id)}
            >
              <span className="tool-number">{tool.number}</span>
              <span className={`tool-glyph ${tool.accent}`}>{tool.short.slice(0, 2)}</span>
              <strong>{tool.label}</strong>
              <small>{tool.description}</small>
              <span className="tool-arrow">↗</span>
            </button>
          ))}
        </div>
      </section>

      <section className="scanner-section" id="scanner">
        <div className="scanner-topline">
          <span className="section-kicker light">02 / LIVE SCANNER</span>
          <span className="live-indicator"><i /> LIVE DATA</span>
        </div>
        <div className="scanner-layout">
          <div className="scanner-copy">
            <span className={`large-glyph ${active.accent}`}>{active.short.slice(0, 2)}</span>
            <h2>{active.label}</h2>
            <p>{active.description}</p>

            <form className="scanner-form" onSubmit={runScan}>
              <div className="scanner-label-row">
                <label htmlFor="scanner-domain">Tên miền cần phân tích</label>
                {activeTool === "dns" && (
                  <label className="dns-view-label">
                    <span>Loại truy vấn</span>
                    <select value={dnsView} onChange={(event) => setDnsView(event.target.value as DnsView)}>
                      {dnsViews.map((view) => <option key={view.value} value={view.value}>{view.label}</option>)}
                    </select>
                  </label>
                )}
              </div>
              <div className="scanner-input-row">
                <input
                  id="scanner-domain"
                  value={domain}
                  onChange={(event) => setDomain(event.target.value)}
                  placeholder="yourdomain.com"
                  spellCheck={false}
                />
                <button type="submit" disabled={scanning}>
                  {scanning ? "Đang xử lý…" : "Kiểm tra"}<span>↗</span>
                </button>
              </div>
            </form>
            {error && <p className="form-error scanner-error" role="alert">{error}</p>}
            <div className="privacy-note"><span>◎</span> Không lưu lịch sử tra cứu hoặc dữ liệu tên miền của bạn.</div>
          </div>

          <div className={`result-console ${scanning ? "is-scanning" : ""}`}>
            <div className="console-header">
              <div className="console-dots"><i /><i /><i /></div>
              <span>{result ? result.domain : "ready://new-scan"}</span>
              <span className="console-time">{result ? `${result.duration.toFixed(2)}s` : "IDLE"}</span>
            </div>

            {scanning ? (
              <div className="scanning-state">
                <div className="radar"><i /><i /><span /></div>
                <h3>Đang dựng bản đồ tín hiệu</h3>
                <p>Đối chiếu DNS, registry và kết nối bảo mật…</p>
                <div className="progress-track"><i style={{ width: `${progress}%` }} /></div>
                <span>{progress}% COMPLETE</span>
              </div>
            ) : result && summary ? (
              <div className="console-results">
                <div className="score-row">
                  <div className="score-ring" style={{ "--score": `${result.score * 3.6}deg` } as React.CSSProperties}>
                    <div><b>{result.score}</b><span>/100</span></div>
                  </div>
                  <div>
                    <span className="result-overline">HEALTH SCORE</span>
                    <h3>{result.score >= 85 ? "Cấu hình rất tốt" : result.score >= 65 ? "Cấu hình ổn định" : "Cần cải thiện"}</h3>
                    <p>{summary.records} bản ghi được phát hiện trong {result.duration.toFixed(2)} giây.</p>
                  </div>
                </div>

                <div className="result-list">
                  {activeTool === "dns" && (
                    dnsView === "email" ? (
                      <div className="email-health-panel">
                        <div className="health-summary">
                          <div><ResultIcon ok={summary.mx} /><span><b>MX</b><small>{summary.mx ? "PASS" : "FAIL"}</small></span></div>
                          <div><ResultIcon ok={summary.spf} /><span><b>SPF</b><small>{summary.spf ? "PASS" : "WARN"}</small></span></div>
                          <div><ResultIcon ok={summary.dmarc} /><span><b>DMARC</b><small>{summary.dmarc ? "PASS" : "WARN"}</small></span></div>
                        </div>

                        <section className="email-check-block">
                          <header><div><span>MX</span><strong>Mail Exchange</strong></div><em className={summary.mx ? "pass" : "warning"}>{summary.mx ? "PASS" : "NOT FOUND"}</em></header>
                          <div className="email-values">
                            {(result.dns.MX || []).length ? (result.dns.MX || []).map((record, index) => (
                              <code key={`${record.data}-${index}`}><b>{record.data.trim().split(/\s+/)[0]}</b>{record.data.trim().split(/\s+/).slice(1).join(" ")}<span>TTL {record.TTL}s</span></code>
                            )) : <p>Không tìm thấy máy chủ nhận mail.</p>}
                          </div>
                        </section>

                        <section className="email-check-block">
                          <header><div><span>CN</span><strong>Mail host CNAME</strong></div><em>{result.mailCname.length ? "ALIAS" : "DIRECT"}</em></header>
                          <div className="email-values">
                            {result.mailCname.length ? result.mailCname.map((record, index) => <code key={`${record.data}-${index}`}>{record.name} <i>→</i> {record.data}<span>TTL {record.TTL}s</span></code>) : <p>Mail host trỏ trực tiếp, không có CNAME trung gian.</p>}
                          </div>
                        </section>

                        <section className="email-check-block">
                          <header><div><span>SP</span><strong>SPF policy</strong></div><em className={summary.spf ? "pass" : "warning"}>{summary.spf ? "PASS" : "MISSING"}</em></header>
                          <div className="email-values">
                            {(result.dns.TXT || []).filter((record) => record.data.toLowerCase().includes("v=spf1")).map((record, index) => <code key={`${record.data}-${index}`}>{cleanRecord(record.data)}<span>TTL {record.TTL}s</span></code>)}
                            {!summary.spf && <p>Chưa có chính sách SPF. Email gửi đi có thể dễ bị giả mạo hơn.</p>}
                          </div>
                        </section>

                        <section className="email-check-block">
                          <header><div><span>DM</span><strong>DMARC policy</strong></div><em className={summary.dmarc ? "pass" : "warning"}>{summary.dmarc ? "PASS" : "MISSING"}</em></header>
                          <div className="email-values">
                            {(result.dns.DMARC || []).map((record, index) => <code key={`${record.data}-${index}`}>{cleanRecord(record.data)}<span>TTL {record.TTL}s</span></code>)}
                            {!summary.dmarc && <p>Chưa có DMARC tại _dmarc.{result.domain}.</p>}
                          </div>
                        </section>

                        <section className="dkim-check-block">
                          <header><div><span>DK</span><strong>DKIM record check</strong></div>{dkimResult.records && <em className={dkimResult.records.length ? "pass" : "warning"}>{dkimResult.records.length ? "PASS" : "NOT FOUND"}</em>}</header>
                          <form onSubmit={checkDkim}>
                            <label><span>Domain</span><input value={result.domain} readOnly /></label>
                            <label><span>Selector</span><input value={dkimSelector} onChange={(event) => setDkimSelector(event.target.value)} placeholder="default" /></label>
                            <button type="submit" disabled={dkimResult.loading}>{dkimResult.loading ? "Đang kiểm tra…" : "Check DKIM"}</button>
                          </form>
                          {dkimResult.records && (
                            <div className={`dkim-output ${dkimResult.records.length ? "found" : "missing"}`}>
                              <span>{dkimResult.host}</span>
                              <code>{dkimResult.records.length ? dkimResult.records.map((record) => cleanRecord(record.data)).join("\n") : "Không tìm thấy TXT record cho selector này."}</code>
                            </div>
                          )}
                        </section>

                        <div className="dns-source-note"><span>◎</span><p>Kết quả truy vấn trực tiếp có thể khác nameserver cục bộ trong thời gian bản ghi đang chờ hết TTL.</p></div>
                      </div>
                    ) : <DnsRecordsPanel dns={result.dns} view={dnsView} />
                  )}
                  {activeTool === "ssl" && (
                    <>
                      <div className="result-item"><ResultIcon ok={result.https.reachable} /><span><b>HTTPS handshake</b><small>{result.https.reachable ? "Kết nối TLS thành công" : "Không thể thiết lập kết nối"}</small></span><em>{result.https.reachable ? "PASS" : "FAIL"}</em></div>
                      <div className="result-item"><ResultIcon ok={(result.dns.CAA || []).length > 0} /><span><b>CAA policy</b><small>{(result.dns.CAA || []).map((item) => cleanRecord(item.data)).join(" · ") || "Chưa khai báo CAA"}</small></span><em>{(result.dns.CAA || []).length}</em></div>
                      <div className="result-item"><ResultIcon ok={Boolean(result.https.headers["strict-transport-security"])} /><span><b>HSTS protection</b><small>{result.https.headers["strict-transport-security"] || "Máy chủ không công khai header cho trình duyệt"}</small></span><em>{result.https.headers["strict-transport-security"] ? "ON" : "N/A"}</em></div>
                    </>
                  )}
                  {activeTool === "domain" && (
                    <>
                      <div className="result-item"><ResultIcon ok={Boolean(result.rdap)} /><span><b>Registrar</b><small>{result.rdap?.registrar || "Không có dữ liệu RDAP"}</small></span><em>RDAP</em></div>
                      <div className="result-item"><ResultIcon ok={Boolean(result.rdap?.created)} /><span><b>Ngày đăng ký</b><small>{readableDate(result.rdap?.created)}</small></span><em>CREATED</em></div>
                      <div className="result-item"><ResultIcon ok={Boolean(result.rdap?.expires)} /><span><b>Ngày hết hạn</b><small>{readableDate(result.rdap?.expires)}</small></span><em>EXPIRY</em></div>
                    </>
                  )}
                  {activeTool === "headers" && (
                    <>
                      {["server", "content-type", "strict-transport-security", "content-security-policy"].map((name) => (
                        <div className="result-item" key={name}>
                          <ResultIcon ok={Boolean(result.https.headers[name])} />
                          <span><b>{name}</b><small>{result.https.headers[name] || "Không được công khai qua CORS"}</small></span>
                          <em>{result.https.headers[name] ? "FOUND" : "HIDDEN"}</em>
                        </div>
                      ))}
                    </>
                  )}
                  {activeTool === "mail" && (
                    <>
                      <div className="result-item"><ResultIcon ok={summary.mx} /><span><b>Mail exchange</b><small>{(result.dns.MX || []).slice(0, 2).map((item) => item.data).join(" · ") || "Không tìm thấy MX"}</small></span><em>{summary.mx ? "PASS" : "FAIL"}</em></div>
                      <div className="result-item"><ResultIcon ok={summary.spf} /><span><b>SPF policy</b><small>{summary.spf ? "Đã khai báo chính sách người gửi" : "Chưa phát hiện SPF"}</small></span><em>{summary.spf ? "PASS" : "WARN"}</em></div>
                      <div className="result-item"><ResultIcon ok={summary.dmarc} /><span><b>DMARC policy</b><small>{summary.dmarc ? "Đã bật xác thực và báo cáo" : "Chưa phát hiện DMARC"}</small></span><em>{summary.dmarc ? "PASS" : "WARN"}</em></div>
                    </>
                  )}
                  {activeTool === "propagation" && (
                    <>
                      <div className="result-item"><ResultIcon ok={(result.dns.A || []).length > 0} /><span><b>Cloudflare resolver</b><small>{(result.dns.A || []).map((item) => item.data).join(" · ") || "Không phản hồi"}</small></span><em>1.1.1.1</em></div>
                      <div className="result-item"><ResultIcon ok={result.googleA.length > 0} /><span><b>Google resolver</b><small>{result.googleA.map((item) => item.data).join(" · ") || "Không phản hồi"}</small></span><em>8.8.8.8</em></div>
                      <div className="result-item"><ResultIcon ok={summary.propagated} /><span><b>Độ đồng nhất</b><small>{summary.propagated ? "Các resolver trả về kết quả tương đồng" : "Kết quả có thể đang cập nhật"}</small></span><em>{summary.propagated ? "SYNC" : "CHECK"}</em></div>
                    </>
                  )}
                </div>
                <button className="copy-report" type="button" onClick={() => navigator.clipboard?.writeText(`TwoK TOOLS report — ${result.domain}: ${result.score}/100`)}>Sao chép tóm tắt <span>⌘C</span></button>
              </div>
            ) : (
              <div className="console-empty">
                <div className="empty-symbol">N/</div>
                <h3>Sẵn sàng phân tích</h3>
                <p>Nhập một tên miền để bắt đầu truy vấn dữ liệu trực tiếp.</p>
                <div className="empty-lines"><i /><i /><i /></div>
              </div>
            )}
          </div>
        </div>
      </section>

      <section className="workflow-section" id="workflow">
        <div className="section-intro compact">
          <div>
            <span className="section-kicker">03 / CÁCH HOẠT ĐỘNG</span>
            <h2>Từ tín hiệu thô<br /><em>đến quyết định.</em></h2>
          </div>
          <p>Mỗi lần quét đi qua ba lớp xử lý độc lập để biến dữ liệu kỹ thuật thành câu trả lời có thể hành động ngay.</p>
        </div>

        <div className="workflow-track">
          <article>
            <span>01</span>
            <div className="process-icon"><i className="pulse-dot" /></div>
            <h3>Thu thập</h3>
            <p>Gửi truy vấn song song tới DNS resolver, registry và máy chủ đích.</p>
          </article>
          <div className="connector"><i /></div>
          <article>
            <span>02</span>
            <div className="process-icon rings"><i /><i /><i /></div>
            <h3>Đối chiếu</h3>
            <p>Chuẩn hóa dữ liệu và phát hiện cấu hình thiếu, lệch hoặc chưa đồng bộ.</p>
          </article>
          <div className="connector"><i /></div>
          <article>
            <span>03</span>
            <div className="process-icon bars"><i /><i /><i /></div>
            <h3>Diễn giải</h3>
            <p>Trả về health score và các tín hiệu ưu tiên theo ngôn ngữ dễ hiểu.</p>
          </article>
        </div>
      </section>

      <section className="insights-section" id="insights">
        <div className="insight-copy">
          <span className="section-kicker light">04 / BUILT FOR CLARITY</span>
          <h2>Không chỉ là<br />một dòng kết quả.</h2>
          <p>TwoK TOOLS cho bạn thấy điều gì đang hoạt động, điều gì cần chú ý và dữ liệu đến từ đâu—trong cùng một giao diện.</p>
          <a href="#scanner">Chạy lần kiểm tra đầu tiên <span>↗</span></a>
        </div>
        <div className="insight-board" aria-hidden="true">
          <div className="board-header"><span>INFRASTRUCTURE MAP</span><i>LIVE</i></div>
          <div className="map-lines"><i /><i /><i /><i /><i /></div>
          <div className="map-node root">NX<span>ROOT</span></div>
          <div className="map-node node-a">DNS<span>32ms</span></div>
          <div className="map-node node-b">TLS<span>A+</span></div>
          <div className="map-node node-c">MX<span>PASS</span></div>
          <div className="map-node node-d">NS<span>SYNC</span></div>
          <div className="board-stat"><span>UPTIME SIGNAL</span><b>99.99%</b><small>↑ 0.04 this month</small></div>
        </div>
      </section>

      <section className="cta-section">
        <div className="cta-noise" aria-hidden="true" />
        <span className="section-kicker light">READY WHEN YOU ARE</span>
        <h2>Một tên miền.<br /><em>Toàn bộ tín hiệu.</em></h2>
        <p>Bắt đầu kiểm tra miễn phí. Không tài khoản, không cài đặt.</p>
        <a href="#scanner">Kiểm tra ngay <span>↗</span></a>
      </section>

      <footer>
        <a className="brand footer-brand" href="#home">
          <RubikLogo />
          <span className="brand-name">TwoK <span className="brand-muted">TOOLS</span></span>
        </a>
        <p>Internet intelligence for everyone.</p>
        <div><span>© 2026 TWOK TOOLS</span><a href="#home">LÊN ĐẦU TRANG ↑</a></div>
      </footer>
    </main>
  );
}
