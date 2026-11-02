/* Sever configuration processing. Runs in JavaScriptCore on iOS and Node in tests. */
(function (root) {
  'use strict';
  var MAX_BYTES = 4 * 1024 * 1024;
  function fail(message) { throw new Error(message); }
  function object(value) { return value && typeof value === 'object' && !Array.isArray(value); }
  function clone(value) { return JSON.parse(JSON.stringify(value)); }
  function name(value, fallback) {
    if (typeof value !== 'string' || /:\/\/|@[\w.-]+/.test(value)) return fallback;
    return value.replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 90).trim() || fallback;
  }
  function unbase64(text) {
    var input = text.replace(/\s/g, '').replace(/-/g, '+').replace(/_/g, '/');
    if (!input || /[^A-Za-z0-9+/=]/.test(input) || input.length % 4 === 1 || !/^[^=]*={0,2}$/.test(input)) fail('Некорректный Base64');
    var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var bits = 0, count = 0, bytes = [], i;
    for (i = 0; i < input.length && input[i] !== '='; i++) {
      bits = (bits << 6) | alphabet.indexOf(input[i]); count += 6;
      if (count >= 8) { count -= 8; bytes.push((bits >>> count) & 255); }
    }
    var encoded = bytes.map(function (b) { return '%' + ('0' + b.toString(16)).slice(-2); }).join('');
    try { return decodeURIComponent(encoded); } catch (_) { fail('Ожидался текст UTF-8'); }
  }
  function uri(text) {
    var match = /^([a-z0-9]+):\/\/([^/?#]+)([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/i.exec(text.trim());
    if (!match) fail('Некорректная ссылка подключения');
    var authority = match[2], at = authority.lastIndexOf('@'), user = '', hostport;
    if (at >= 0) { user = decodeURIComponent(authority.slice(0, at)); hostport = authority.slice(at + 1); }
    else hostport = authority;
    var hp = /^(\[[^\]]+\]|[^:]+)(?::(\d+))?$/.exec(hostport);
    if (!hp) fail('Не удалось прочитать адрес сервера');
    var port = Number(hp[2] || 443);
    if (!Number.isInteger(port) || port < 1 || port > 65535) fail('Некорректный порт');
    var query = {};
    (match[4] || '').split('&').filter(Boolean).forEach(function (part) {
      var eq = part.indexOf('='), key = decodeURIComponent(eq < 0 ? part : part.slice(0, eq));
      query[key] = decodeURIComponent((eq < 0 ? '' : part.slice(eq + 1)).replace(/\+/g, '%20'));
    });
    return { scheme: match[1].toLowerCase(), user: user, host: hp[1].replace(/^\[|\]$/g, ''), port: port, query: query, label: decodeURIComponent(match[5] || '') };
  }
  function shareConfig(text) {
    var u = uri(text), q = u.query;
    if (u.scheme !== 'vless' && u.scheme !== 'trojan') fail('В этой версии поддержаны ссылки VLESS и Trojan; остальные импортируйте полным Xray JSON');
    if (!u.user) fail('В ссылке нет параметров доступа');
    var network = q.type || 'tcp', security = q.security || (u.scheme === 'trojan' ? 'tls' : 'none');
    if (['tcp','raw','ws','grpc','xhttp'].indexOf(network) < 0) fail('Транспорт ссылки пока не поддержан');
    if (['none','tls','reality'].indexOf(security) < 0) fail('Неизвестный тип защиты');
    var stream = { network: network, security: security };
    if (security === 'reality') {
      if (!q.pbk) fail('В REALITY-ссылке нет публичного ключа');
      stream.realitySettings = { serverName: q.sni || u.host, fingerprint: q.fp || 'chrome', publicKey: q.pbk, shortId: q.sid || '', spiderX: q.spx || '' };
    } else if (security === 'tls') {
      stream.tlsSettings = { serverName: q.sni || u.host };
      if (q.fp) stream.tlsSettings.fingerprint = q.fp;
      if (q.alpn) stream.tlsSettings.alpn = q.alpn.split(',');
      if (/^(1|true)$/i.test(q.allowInsecure || q.insecure || '')) fail('Ссылки с отключённой проверкой TLS не принимаются');
    }
    if (network === 'ws') stream.wsSettings = { path: q.path || '/', headers: q.host ? { Host: q.host } : {} };
    if (network === 'grpc') stream.grpcSettings = { serviceName: q.serviceName || '', multiMode: q.mode === 'multi', authority: q.authority || '' };
    if (network === 'xhttp') {
      stream.xhttpSettings = { path: q.path || '/', mode: q.mode || 'auto' };
      if (q.host) stream.xhttpSettings.host = q.host;
      if (q.extra) { try { stream.xhttpSettings.extra = JSON.parse(q.extra); } catch (_) { fail('Некорректные параметры XHTTP'); } }
    }
    var outbound = { tag: 'proxy', protocol: u.scheme, streamSettings: stream };
    if (u.scheme === 'vless') {
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(u.user)) fail('Некорректный UUID VLESS');
      outbound.settings = { vnext: [{ address: u.host, port: u.port, users: [{ id: u.user, encryption: q.encryption || 'none', flow: q.flow || '' }] }] };
    } else outbound.settings = { servers: [{ address: u.host, port: u.port, password: u.user }] };
    return { remarks: name(u.label, 'Импортированный сервер'), outbounds: [outbound] };
  }
  function xrayProfile(input, index) {
    if (!object(input) || !Array.isArray(input.outbounds) || !input.outbounds.length) fail('В JSON нет выходных подключений');
    var cfg = clone(input), supported = ['vless','vmess','trojan','shadowsocks','socks','http','hysteria','hysteria2','wireguard','freedom','blackhole','dns','loopback'];
    var tags = {}, proxies = 0;
    cfg.outbounds.forEach(function (out, i) {
      if (!object(out) || supported.indexOf(out.protocol) < 0) fail('Неизвестный протокол в конфигурации');
      out.tag = out.tag || 'proxy-' + (i + 1);
      if (tags[out.tag]) fail('Теги подключений должны быть уникальны');
      tags[out.tag] = true;
      if (['freedom','blackhole','dns','loopback'].indexOf(out.protocol) < 0) proxies++;
      if (out.proxySettings) fail('Устаревшие proxySettings не поддержаны текущим ядром');
      var tls = (out.streamSettings || {}).tlsSettings;
      if (tls && tls.allowInsecure) fail('Конфигурация отключает проверку TLS-сертификата');
      if (tls && (tls.certificates || []).some(function (cert) { return cert.certificateFile || cert.keyFile; })) fail('Внешние файлы TLS-сертификатов пока не поддержаны');
    });
    if (!proxies) fail('В конфигурации нет VPN-сервера');
    var serialized = JSON.stringify(cfg);
    if (/"(?:geoip|geosite|ext):/i.test(serialized)) fail('Этот профиль требует геоданных; импорт таких профилей пока не включён');
    return { name: name(cfg.remarks, 'Профиль ' + (index + 1)), engine: 'xray', configuration: serialized, host: '', port: 0, country: '', source: 'import', nodes: proxies };
  }
  function openvpnProfile(text, label) {
    if (!/<ca>[\s\S]+<\/ca>/i.test(text)) fail('В OpenVPN-профиле нет встроенного сертификата CA');
    if (/^\s*(?:plugin|up|down|route-up|ipchange|script-security|management|tls-verify|auth-user-pass-verify|client-connect|client-disconnect)\b/im.test(text)) fail('OpenVPN-профиль содержит неподдерживаемые внешние команды');
    if (/^[ \t]*(?:ca|cert|key|pkcs12|auth-user-pass)[ \t]+\S+/im.test(text)) fail('Внешние файлы сертификатов и паролей пока не поддержаны');
    var remote = /^\s*remote\s+(\[[^\]]+\]|\S+)\s+(\d+)/im.exec(text);
    if (!remote || Number(remote[2]) < 1 || Number(remote[2]) > 65535) fail('Нет корректного адреса OpenVPN');
    if (!/^\s*remote-cert-tls\s+server\s*$/im.test(text)) text += '\nremote-cert-tls server\n';
    return { name: name(label, 'OpenVPN'), engine: 'openvpn', configuration: text, host: remote[1].replace(/^\[|\]$/g, ''), port: Number(remote[2]), country: '', source: 'import', nodes: 1 };
  }
  function importText(raw) {
    if (typeof raw !== 'string' || raw.length > MAX_BYTES) fail('Файл слишком большой: максимум 4 МБ');
    var text = raw.replace(/^\uFEFF/, '').trim(), parsed;
    if (!text) fail('Пустой файл');
    if (/^\s*(?:client\b|dev\s|#|;)/.test(text) && /^\s*remote\s/m.test(text)) return [openvpnProfile(text)];
    if (text[0] === '{' || text[0] === '[') {
      try { parsed = JSON.parse(text); } catch (_) { fail('Некорректный JSON'); }
      var array = Array.isArray(parsed) ? parsed : [parsed];
      if (!array.length || array.length > 150) fail('Допустимо от 1 до 150 профилей за импорт');
      return array.map(xrayProfile);
    }
    if (!/^(?:vless|trojan):\/\//i.test(text)) text = unbase64(text).trim();
    if (text[0] === '{' || text[0] === '[') return importText(text);
    var lines = text.split(/\r?\n/).map(function (s) { return s.trim(); }).filter(function (s) { return s && s[0] !== '#'; });
    if (!lines.length || lines.length > 150) fail('Допустимо от 1 до 150 ссылок за импорт');
    return lines.map(function (line, i) { return xrayProfile(shareConfig(line), i); });
  }
  function strictXray(raw) {
    var original = JSON.parse(raw), cfg = {}, keep = ['outbounds','dns','routing','observatory','burstObservatory'];
    keep.forEach(function (key) { if (original[key] !== undefined) cfg[key] = clone(original[key]); });
    if (!cfg.outbounds || !cfg.outbounds.length) fail('Нет подключений');
    var used = {}; cfg.outbounds.forEach(function (out) { used[out.tag] = true; });
    var block = 'sever-block'; while (used[block]) block += '-1';
    cfg.outbounds.forEach(function (out) { if (out.protocol === 'freedom') { out.protocol = 'blackhole'; out.settings = {}; delete out.streamSettings; } });
    cfg.outbounds.push({ tag: block, protocol: 'blackhole', settings: {} });
    cfg.routing = cfg.routing || {}; cfg.routing.rules = cfg.routing.rules || [];
    cfg.routing.rules.forEach(function (rule) { delete rule.webhook; });
    (cfg.routing.balancers || []).forEach(function (balancer) { balancer.fallbackTag = block; });
    var proxyTags = cfg.outbounds.filter(function (out) { return ['freedom','blackhole','dns','loopback'].indexOf(out.protocol) < 0; }).map(function (out) { return out.tag; });
    if (!proxyTags.length) fail('Нет VPN-сервера');
    // Direct rules would break strict mode. Remove them so the final VPN rule handles these sites.
    var originallyDirect = (original.outbounds || []).filter(function (out) { return out.protocol === 'freedom'; }).map(function (out) { return out.tag; });
    cfg.routing.rules = cfg.routing.rules.filter(function (r) { return originallyDirect.indexOf(r.outboundTag) < 0; });
    var balancers = cfg.routing.balancers || [];
    var finalRoute;
    if (balancers.length) finalRoute = { type: 'field', network: 'tcp,udp', balancerTag: balancers[0].tag };
    else {
      var balancerTag = 'sever-auto';
      cfg.routing.balancers = [{ tag: balancerTag, selector: proxyTags, fallbackTag: block, strategy: { type: 'leastPing' } }];
      cfg.observatory = { subjectSelector: proxyTags, probeUrl: 'https://cp.cloudflare.com/generate_204', probeInterval: '30s', enableConcurrency: true };
      delete cfg.burstObservatory;
      finalRoute = { type: 'field', network: 'tcp,udp', balancerTag: balancerTag };
    }
    cfg.routing.rules.push(finalRoute);
    // Application-owned DNS avoids provider webhooks, file paths and direct/local resolvers.
    var dnsTag = 'sever-dns'; while (used[dnsTag]) dnsTag += '-1';
    cfg.dns = { servers: ['https://1.1.1.1/dns-query','https://8.8.8.8/dns-query'], queryStrategy: 'UseIP', tag: 'sever-dns-query' };
    cfg.outbounds.push({ tag: dnsTag, protocol: 'dns', settings: {} });
    cfg.routing.rules.unshift({ type: 'field', inboundTag: ['sever-tun'], port: '53', outboundTag: dnsTag });
    var dnsRoute = clone(finalRoute); delete dnsRoute.network; dnsRoute.inboundTag = ['sever-dns-query']; cfg.routing.rules.unshift(dnsRoute);
    cfg.log = { loglevel: 'none' };
    cfg.policy = { levels: { '0': { connIdle: 120, bufferSize: 64 } } };
    return JSON.stringify(cfg);
  }
  function csvRows(text) {
    var rows = [], row = [], field = '', quoted = false;
    for (var i = 0; i < text.length; i++) {
      var ch = text[i];
      if (ch === '"') { if (quoted && text[i + 1] === '"') { field += '"'; i++; } else quoted = !quoted; }
      else if (ch === ',' && !quoted) { row.push(field); field = ''; }
      else if ((ch === '\n' || ch === '\r') && !quoted) { if (ch === '\r' && text[i + 1] === '\n') i++; row.push(field); if (row.some(Boolean)) rows.push(row); row = []; field = ''; }
      else field += ch;
    }
    if (quoted) fail('Неполный CSV');
    row.push(field); if (row.some(Boolean)) rows.push(row);
    return rows;
  }
  function publicIPv4(ip) {
    var a = ip.split('.').map(Number);
    if (a.length !== 4 || !a.every(function (v) { return Number.isInteger(v) && v >= 0 && v <= 255; })) return false;
    return !(a[0] === 0 || a[0] === 10 || a[0] === 127 || a[0] >= 224 || (a[0] === 169 && a[1] === 254) || (a[0] === 172 && a[1] >= 16 && a[1] <= 31) || (a[0] === 192 && (a[1] === 168 || a[1] === 0)) || (a[0] === 100 && a[1] >= 64 && a[1] <= 127) || (a[0] === 198 && (a[1] === 18 || a[1] === 19)));
  }
  function vpnGate(raw) {
    if (typeof raw !== 'string' || raw.length > MAX_BYTES) fail('Каталог слишком большой');
    var rows = csvRows(raw), head = -1;
    for (var i = 0; i < rows.length; i++) if (rows[i].indexOf('OpenVPN_ConfigData_Base64') >= 0 && rows[i].indexOf('IP') >= 0) { head = i; break; }
    if (head < 0) fail('Источник вернул неизвестный формат каталога');
    var header = rows[head], profiles = [], seen = {};
    rows.slice(head + 1).forEach(function (row) {
      function val(k) { return row[header.indexOf(k)] || ''; }
      if (!publicIPv4(val('IP')) || !val('OpenVPN_ConfigData_Base64')) return;
      try {
        var text = unbase64(val('OpenVPN_ConfigData_Base64'));
        var profile = openvpnProfile(text, name(val('CountryLong'), 'VPN Gate'));
        if (profile.host !== val('IP')) return;
        var remotes = /^[ \t]*remote[ \t]+(\S+)[ \t]+\d+/gim, remote;
        while ((remote = remotes.exec(text)) !== null) { if (remote[1] !== val('IP')) return; }
        if (/^[ \t]*(?:http-proxy|socks-proxy)\b/im.test(text)) return;
        if (!/^\s*proto\s+tcp(?:-client)?\s*$/im.test(text)) return; // TCP probes must represent the actual transport.
        var key = profile.host + ':' + profile.port; if (seen[key]) return; seen[key] = true;
        profile.country = /^[A-Z]{2}$/i.test(val('CountryShort')) ? val('CountryShort').toUpperCase() : '';
        profile.source = 'vpngate'; profile.score = Number(val('Score')) || 0;
        profiles.push(profile);
      } catch (_) { /* A broken volunteer row must not discard the rest of the catalog. */ }
    });
    profiles.sort(function (a, b) { return b.score - a.score; });
    if (!profiles.length) fail('В каталоге нет совместимых TCP-серверов');
    // Round-robin countries so one large country does not crowd out all alternatives.
    var groups = {}, order = [];
    profiles.forEach(function (p) { if (!groups[p.country]) { groups[p.country] = []; order.push(p.country); } groups[p.country].push(p); });
    var balanced = [], position = 0;
    while (balanced.length < 30 && balanced.length < profiles.length) {
      order.forEach(function (country) { if (groups[country][position] && balanced.length < 30) balanced.push(groups[country][position]); });
      position++;
    }
    return balanced;
  }
  function safeDiagnostic(value) {
    var result = { version: 1, tunnel: ['disconnected','connecting','connected','reasserting','disconnecting','invalid'].indexOf(value.tunnel) >= 0 ? value.tunnel : 'unknown', checks: [] };
    if (['xray','openvpn'].indexOf(value.engine) >= 0) result.engine = value.engine;
    (Array.isArray(value.checks) ? value.checks : []).slice(0, 4).forEach(function (check) {
      var item = { target: ['cloudflare','google','apple'].indexOf(check.target) >= 0 ? check.target : 'unknown', ok: check.ok === true };
      if (Number.isFinite(check.milliseconds)) item.milliseconds = Math.max(0, Math.min(120000, Math.round(check.milliseconds)));
      if (['timeout','network','http','cancelled'].indexOf(check.error) >= 0) item.error = check.error;
      result.checks.push(item);
    });
    return result;
  }
  var api = { importText: importText, strictXray: strictXray, vpnGate: vpnGate, safeDiagnostic: safeDiagnostic };
  root.SeverCore = api;
  root.severCall = function (method, inputJSON) {
    try { if (!Object.prototype.hasOwnProperty.call(api, method)) fail('Неизвестная операция'); return JSON.stringify({ ok: true, value: api[method](JSON.parse(inputJSON)) }); }
    catch (e) { return JSON.stringify({ ok: false, error: e instanceof SyntaxError || e instanceof URIError ? 'Не удалось прочитать конфигурацию' : String(e.message || 'Ошибка импорта') }); }
  };
  if (typeof module !== 'undefined') module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
