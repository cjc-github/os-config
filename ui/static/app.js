"use strict";

// 所有服务端文本一律通过 textContent 写入，避免把数据当 HTML 解析。
const S = {
  catalog: [],
  catalogById: new Map(),
  profiles: [],
  paramGroups: [],
  selection: new Set(),
  params: {},
  resetParams: new Set(),
  originalParams: {},
  secrets: {},
  clearSecretsApplied: new Set(),
  planTimer: null,
  planSeq: 0,
  lastPlan: null,
  running: false,
  results: new Map(),
  activeRunId: null,
  eventSource: null,
  retries: 0,
  installed: [],
  catalogTools: [],
  rollingBack: false,
  tab: "results",
};

const TABS = ["results", "log", "history"];

function $(id) {
  return document.getElementById(id);
}

function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

function setTab(name) {
  if (TABS.indexOf(name) === -1) return;
  const changed = S.tab !== name;
  S.tab = name;
  TABS.forEach((tab) => {
    const button = $(tab + "-tab");
    const panel = $("panel-" + tab);
    const active = tab === name;
    if (button) {
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-selected", active ? "true" : "false");
      button.tabIndex = active ? 0 : -1;
    }
    if (panel) panel.hidden = !active;
  });
  if (changed && name === "history") refreshHistory();
}

function make(tag, text, cls) {
  const node = document.createElement(tag);
  if (text !== undefined && text !== null) node.textContent = String(text);
  if (cls) node.className = cls;
  return node;
}

function toast(message, kind) {
  const box = make("div", message, "toast " + (kind || "info"));
  $("toasts").appendChild(box);
  window.setTimeout(() => {
    if (box.parentNode) box.parentNode.removeChild(box);
  }, 4500);
}

async function api(method, path, body) {
  const opts = { method: method, headers: {}, credentials: "same-origin" };
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  let res;
  try {
    res = await fetch(path, opts);
  } catch (err) {
    toast("无法连接本机服务，请确认 ui.sh 仍在运行", "error");
    throw err;
  }
  if (res.status === 401) {
    toast("请通过 ui.sh 打开", "error");
    throw new Error("unauthorized");
  }
  let data = null;
  try {
    data = await res.json();
  } catch (err) {
    data = null;
  }
  if (!res.ok) {
    const message = data && data.error ? data.error : "HTTP " + res.status;
    toast(message, "error");
    throw new Error(message);
  }
  return data;
}

function stripToken() {
  const url = new URL(window.location.href);
  if (url.searchParams.has("token")) {
    url.searchParams.delete("token");
    const query = url.searchParams.toString();
    window.history.replaceState(null, "", url.pathname + (query ? "?" + query : "") + url.hash);
  }
}

function defaultProfileTools() {
  const profile = S.profiles.find((p) => p.name === "default");
  return profile && Array.isArray(profile.tools) ? profile.tools.slice() : [];
}

function catalogId(token) {
  return token.indexOf(":") === -1;
}

function selectedCatalogIds() {
  const ids = new Set();
  S.selection.forEach((token) => {
    if (catalogId(token)) ids.add(token);
  });
  return ids;
}

function statusLabel(status) {
  const labels = {
    ok: "成功",
    failed: "失败",
    skipped: "跳过",
    planned: "待执行",
    not_run: "未执行",
    running: "执行中",
  };
  return labels[status] || status || "未执行";
}

// ---------- 工具清单 ----------

function renderPreset() {
  const select = $("preset");
  clear(select);
  const none = make("option", "自定义选择");
  none.value = "";
  select.appendChild(none);
  S.profiles.forEach((profile) => {
    const option = make("option", profile.name + (profile.desc ? " — " + profile.desc : ""));
    option.value = profile.name;
    select.appendChild(option);
  });
}

function renderTools() {
  const list = $("tool-list");
  const query = ($("search").value || "").trim().toLowerCase();
  clear(list);
  const groups = new Map();
  S.catalog.forEach((tool) => {
    const name = tool.group || "其他";
    if (!groups.has(name)) groups.set(name, []);
    groups.get(name).push(tool);
  });
  let shown = 0;
  groups.forEach((tools, groupName) => {
    const section = make("div", null, "tool-group");
    section.appendChild(make("h3", groupName, "tool-group-title"));
    tools.forEach((tool) => {
      const haystack = (tool.id + " " + (tool.desc || "")).toLowerCase();
      if (query && haystack.indexOf(query) === -1) return;
      shown += 1;
      const line = make("label", null, "tool-row");
      const box = document.createElement("input");
      box.type = "checkbox";
      box.value = tool.id;
      box.checked = S.selection.has(tool.id);
      box.addEventListener("change", () => {
        if (box.checked) S.selection.add(tool.id);
        else S.selection.delete(tool.id);
        selectionChanged();
      });
      line.appendChild(box);
      const text = make("span", null, "tool-text");
      text.appendChild(make("span", tool.id, "tool-id"));
      if (tool.desc) text.appendChild(make("span", tool.desc, "tool-desc"));
      line.appendChild(text);
      section.appendChild(line);
    });
    if (section.querySelectorAll(".tool-row").length) list.appendChild(section);
  });
  const adhoc = Array.from(S.selection).filter((token) => !catalogId(token));
  if (adhoc.length) {
    const section = make("div", null, "tool-group");
    section.appendChild(make("h3", "内联包", "tool-group-title"));
    adhoc.forEach((token) => {
      if (query && token.toLowerCase().indexOf(query) === -1) return;
      const line = make("label", null, "tool-row");
      const box = document.createElement("input");
      box.type = "checkbox";
      box.value = token;
      box.checked = true;
      box.addEventListener("change", () => {
        if (!box.checked) S.selection.delete(token);
        selectionChanged();
      });
      line.appendChild(box);
      line.appendChild(make("span", token, "tool-id"));
      section.appendChild(line);
    });
    list.appendChild(section);
  }
  if (!shown && !adhoc.length) list.appendChild(make("p", "没有匹配的工具", "hint"));
}

function visibleIds() {
  const query = ($("search").value || "").trim().toLowerCase();
  return S.catalog
    .filter((tool) => !query || (tool.id + " " + (tool.desc || "")).toLowerCase().indexOf(query) !== -1)
    .map((tool) => tool.id);
}

function selectionChanged() {
  updateRunButton();
  renderParams();
  schedulePlan(300);
}

function schedulePlan(delay) {
  window.clearTimeout(S.planTimer);
  S.planTimer = window.setTimeout(runPlan, delay === undefined ? 300 : delay);
}

async function runPlan() {
  const pick = Array.from(S.selection);
  if (!pick.length) {
    S.lastPlan = null;
    renderPlan(null);
    return;
  }
  const seq = ++S.planSeq;
  try {
    const data = await api("POST", "/api/plan", { verb: "install", pick: pick });
    if (seq !== S.planSeq) return;
    S.lastPlan = data;
    renderPlan(data);
  } catch (err) {
    if (seq === S.planSeq) renderPlan(null);
  }
}

function renderPlan(data) {
  const box = $("plan-summary");
  clear(box);
  const banner = $("dep-banner");
  if (!data) {
    box.appendChild(make("p", S.selection.size ? "计划生成失败" : "未选择任何工具", "hint"));
    banner.hidden = true;
    return;
  }
  const items = data.items || [];
  box.appendChild(make("p", "共 " + items.length + " 项", "plan-count"));
  const deps = [];
  items.forEach((item) => {
    const line = make("div", null, "plan-item");
    line.appendChild(make("span", item.id, "plan-id"));
    if (item.selected) {
      line.appendChild(make("span", "主动选择", "tag tag-selected"));
    } else if (item.required_by && item.required_by.length) {
      const by = item.required_by.join("、");
      line.appendChild(make("span", "由 " + by + " 依赖引入", "tag tag-dep"));
      deps.push(item.id + "（由 " + by + " 依赖引入）");
    }
    line.appendChild(make("span", item.status || "", "plan-status status-" + (item.status || "planned")));
    box.appendChild(line);
  });
  if (deps.length) {
    banner.hidden = false;
    clear(banner);
    banner.appendChild(make("strong", "已自动引入依赖："));
    banner.appendChild(document.createTextNode(deps.join("；")));
  } else {
    banner.hidden = true;
  }
}

// ---------- 参数 ----------

function visibleGroups() {
  const ids = selectedCatalogIds();
  return S.paramGroups.filter((group) => (group.tools || []).some((tool) => ids.has(tool)));
}

function allSecretKeys() {
  const keys = [];
  S.paramGroups.forEach((group) => {
    (group.fields || []).forEach((field) => {
      if (field.secret) keys.push(field.key);
    });
  });
  return keys;
}

function currentValue(field) {
  if (Object.prototype.hasOwnProperty.call(S.params, field.key)) return S.params[field.key];
  if (field.secret) return "";
  return Object.prototype.hasOwnProperty.call(S.originalParams, field.key)
    ? S.originalParams[field.key]
    : "";
}

function renderParams() {
  const box = $("params");
  clear(box);
  const groups = visibleGroups();
  if (!groups.length) {
    box.appendChild(make("p", "选择工具后显示可调整的参数", "hint"));
    return;
  }
  groups.forEach((group) => {
    const section = make("fieldset", null, "param-group");
    section.appendChild(make("legend", group.title || group.id));
    (group.fields || []).forEach((field) => {
      const line = make("div", null, "param-row");
      const label = make("label", field.label || field.key, "param-label");
      label.setAttribute("for", "param-" + field.key);
      line.appendChild(label);
      let input;
      if (field.type === "select" && Array.isArray(field.options)) {
        input = document.createElement("select");
        field.options.forEach((opt) => {
          const option = make("option", opt.label || opt.value || opt);
          option.value = opt.value !== undefined ? opt.value : opt;
          input.appendChild(option);
        });
      } else {
        input = document.createElement("input");
        input.type = field.secret ? "password" : (field.type || "text");
        if (field.placeholder) input.placeholder = field.placeholder;
        if (field.secret) input.autocomplete = "new-password";
      }
      input.id = "param-" + field.key;
      if (!field.secret) input.value = currentValue(field);
      else if (Object.prototype.hasOwnProperty.call(S.secrets, field.key) && S.secrets[field.key]) {
        input.placeholder = "已设置（输入新值以覆盖）";
      }
      input.addEventListener("input", () => {
        S.resetParams.delete(field.key);
        if (field.secret && input.value === "") {
          delete S.params[field.key];
        } else if (!field.secret && input.value === (Object.prototype.hasOwnProperty.call(S.originalParams, field.key) ? S.originalParams[field.key] : "")) {
          delete S.params[field.key];
        } else {
          S.params[field.key] = input.value;
        }
      });
      line.appendChild(input);
      const reset = make("button", "恢复默认", "ghost tiny");
      reset.type = "button";
      reset.addEventListener("click", () => {
        delete S.params[field.key];
        S.resetParams.add(field.key);
        input.value = field.secret ? "" : (Object.prototype.hasOwnProperty.call(S.originalParams, field.key) ? S.originalParams[field.key] : "");
        if (field.secret) input.placeholder = "恢复为默认";
      });
      line.appendChild(reset);
      section.appendChild(line);
    });
    box.appendChild(section);
  });
}

function applyClearSecrets(enabled) {
  const keys = allSecretKeys();
  if (enabled) {
    keys.forEach((key) => {
      if (!Object.prototype.hasOwnProperty.call(S.params, key)) {
        S.params[key] = "";
        S.clearSecretsApplied.add(key);
      }
    });
    renderParams();
  } else {
    keys.forEach((key) => {
      if (S.clearSecretsApplied.has(key) && S.params[key] === "") delete S.params[key];
    });
    S.clearSecretsApplied.clear();
    renderParams();
  }
}

// ---------- sudo ----------

async function renderSudo() {
  const badge = $("sudo-badge");
  try {
    const data = await api("POST", "/api/sudo/check", {});
    if (!data.sudo) {
      badge.textContent = "未安装 sudo";
      badge.className = "pill warn";
    } else if (data.available) {
      badge.textContent = "sudo 已授权";
      badge.className = "pill ok";
    } else {
      badge.textContent = "sudo 未授权：请在终端执行 sudo -v";
      badge.className = "pill warn";
    }
  } catch (err) {
    badge.textContent = "sudo 状态未知";
    badge.className = "pill warn";
  }
}

// ---------- 运行与事件 ----------

function updateRunButton() {
  $("run-btn").disabled = S.running || S.selection.size === 0;
}

function setRunning(running) {
  S.running = running;
  $("run-state").textContent = running ? "运行中" : "空闲";
  $("run-state").className = "pill " + (running ? "busy" : "");
  $("plan-btn").disabled = running;
  $("remove-btn").disabled = running;
  updateRunButton();
  if (!running) {
    $("log-state").hidden = true;
    $("current-item").hidden = true;
  } else {
    $("log-state").hidden = false;
  }
}

function clearLog() {
  clear($("log"));
}

function appendLog(line, cls) {
  const row = make("span", line, "log-line" + (cls ? " " + cls : ""));
  $("log").appendChild(row);
  if ($("autoscroll").checked) $("log").scrollTop = $("log").scrollHeight;
}

function handleItem(event) {
  const id = event.id;
  if (!id) return;
  if (event.event === "item_start") {
    const indicator = $("current-item");
    indicator.textContent = (event.phase === "verify" ? "校验 " : "执行 ") + id;
    indicator.hidden = false;
    return;
  }
  if (event.event !== "item_end") return;
  const phase = event.phase === "verify" ? "verify" : "install";
  const entry = S.results.get(id) || { install: null, verify: null };
  entry[phase] = event.status || "failed";
  S.results.set(id, entry);
  renderResults();
}

function clearRollbackBanner() {
  const panel = $("results").closest(".panel");
  if (!panel) return;
  const old = panel.querySelector(".rollback-banner");
  if (old) old.remove();
}

function showRollback(event) {
  S.rollingBack = true;
  const panel = $("results").closest(".panel");
  if (!panel) return;
  clearRollbackBanner();
  const banner = make("div", "已回滚：安装失败，以下变更已撤销", "rollback-banner");
  panel.insertBefore(banner, panel.firstChild);
}

function resultIds() {
  return Array.from(new Set([
    ...selectedCatalogIds(),
    ...Array.from(S.results.keys()).filter(catalogId),
  ]));
}

function renderSummary(ids) {
  const counts = { ok: 0, skipped: 0, failed: 0, pending: 0 };
  ids.forEach((id) => {
    const entry = S.results.get(id) || {};
    if (entry.install === "failed" || entry.verify === "failed") counts.failed += 1;
    else if (entry.install === "ok" || entry.verify === "ok") counts.ok += 1;
    else if (entry.install === "skipped" || entry.verify === "skipped") counts.skipped += 1;
    else counts.pending += 1;
  });
  const parts = ["成功 " + counts.ok];
  if (counts.skipped) parts.push("跳过 " + counts.skipped);
  if (counts.failed) parts.push("失败 " + counts.failed);
  if (counts.pending) parts.push("未执行 " + counts.pending);
  $("result-summary").textContent = parts.join(" · ");
  $("results-count").textContent = String(ids.length);
  const tab = $("results-tab");
  if (counts.failed) tab.setAttribute("data-state", "failed");
  else if (counts.ok && !counts.pending) tab.setAttribute("data-state", "ok");
  else tab.removeAttribute("data-state");
}

function renderResults() {
  const body = $("results");
  clear(body);
  const ids = resultIds();
  renderSummary(ids);
  if (!ids.length) {
    const row = document.createElement("tr");
    const cell = make("td", "尚未选择工具", "hint");
    cell.colSpan = 3;
    row.appendChild(cell);
    body.appendChild(row);
    return;
  }
  ids.forEach((id) => {
    const entry = S.results.get(id) || { install: null, verify: null };
    const row = document.createElement("tr");
    row.appendChild(make("td", id));
    const install = entry.install || "not_run";
    const verify = entry.verify || "not_run";
    row.appendChild(make("td", statusLabel(install), "status status-" + install));
    row.appendChild(make("td", statusLabel(verify), "status status-" + verify));
    if (install === "failed" || verify === "failed") row.className = "failed-row";
    row.addEventListener("click", () => {
      if (install !== "failed" && verify !== "failed") return;
      highlightLog(id);
    });
    body.appendChild(row);
  });
}

function highlightLog(id) {
  const needle = "[" + id + "]";
  const lines = $("log").querySelectorAll(".log-line");
  lines.forEach((line) => line.classList.remove("highlight"));
  let first = null;
  lines.forEach((line) => {
    if ((line.textContent || "").indexOf(needle) !== -1) {
      line.classList.add("highlight");
      if (!first) first = line;
    }
  });
  if (first) {
    setTab("log");
    if (!$("autoscroll").checked) first.scrollIntoView({ block: "center" });
    else $("log").scrollTop = first.offsetTop - 40;
  } else {
    toast("日志中没有找到 " + needle);
  }
}

function finishRun(event) {
  const verifyOn = $("verify-after").checked;
  const installFailed = S.results.size === 0 || Array.from(S.results.values()).some((e) => e.install === "failed");
  const ids = resultIds();
  ids.forEach((id) => {
    const entry = S.results.get(id) || { install: null, verify: null };
    if (!entry.install) entry.install = "not_run";
    if (!entry.verify && (installFailed || !verifyOn || S.rollingBack)) entry.verify = "not_run";
    if (!entry.verify) entry.verify = "not_run";
    S.results.set(id, entry);
  });
  renderResults();
  setRunning(false);
  setTab("results");
  if (S.eventSource) S.eventSource.close();
  S.eventSource = null;
  toast(event && event.rc === 0 ? "执行完成" : "执行结束，请查看结果", event && event.rc === 0 ? "ok" : "warn");
  refreshHistory();
  refreshInstalled();
}

function handlePlanEvent(event) {
  if (!event || !event.ids) return;
  if (!S.lastPlan) {
    renderPlan({ items: (event.ids || []).map((id) => ({ id: id, selected: true, required_by: [], status: "running" })) });
  }
}

function connectEvents(runId) {
  if (S.eventSource) {
    S.eventSource.close();
    S.eventSource = null;
  }
  const target = runId || S.activeRunId;
  const source = target
    ? new EventSource("/api/events?run_id=" + encodeURIComponent(target))
    : new EventSource("/api/events");
  S.eventSource = source;
  source.addEventListener("open", () => {
    S.retries = 0;
    setRunning(true);
  });
  source.addEventListener("log", (ev) => {
    const data = JSON.parse(ev.data);
    appendLog(data.line, "");
  });
  source.addEventListener("plan", (ev) => {
    handlePlanEvent(JSON.parse(ev.data));
  });
  source.addEventListener("item", (ev) => {
    handleItem(JSON.parse(ev.data));
  });
  source.addEventListener("rollback", (ev) => {
    showRollback(JSON.parse(ev.data));
  });
  source.addEventListener("summary", (ev) => {
    S.summary = JSON.parse(ev.data);
  });
  source.addEventListener("done", (ev) => {
    let data = {};
    try {
      data = JSON.parse(ev.data);
    } catch (err) {
      data = {};
    }
    finishRun(data);
  });
  source.onerror = () => {
    source.close();
    if (S.eventSource === source) S.eventSource = null;
    if (!S.running || S.retries >= 5) return;
    S.retries += 1;
    const delay = Math.min(30000, 1000 * Math.pow(2, S.retries));
    window.setTimeout(() => connectEvents(S.activeRunId), delay);
  };
}

async function checkStatus() {
  if (S.running) return;
  const pick = Array.from(S.selection);
  if (!pick.length) {
    toast("请先选择工具", "warn");
    return;
  }
  try {
    const data = await api("GET", "/api/status?pick=" + encodeURIComponent(pick.join(",")));
    S.results = new Map();
    S.rollingBack = false;
    clearRollbackBanner();
    (data.items || []).forEach((item) => {
      if (!item.id) return;
      const entry = S.results.get(item.id) || { install: null, verify: null };
      if (item.phase === "verify") entry.verify = item.status || null;
      else entry.install = item.status || null;
      S.results.set(item.id, entry);
    });
    renderResults();
    setTab("results");
    clearLog();
    (data.logs || []).forEach((line) => appendLog(line));
    if (data.exit !== undefined) {
      toast("状态检查结束（rc=" + data.exit + "）", data.exit === 0 ? "ok" : "warn");
    }
  } catch (err) {
    /* toast 已由 api() 处理 */
  }
}

async function startRun(verb) {
  if (S.running) return;
  const pick = Array.from(S.selection);
  if (!pick.length) {
    toast("请先选择工具", "warn");
    return;
  }
  const body = {
    verb: verb,
    pick: pick,
    params: S.params,
    reset_params: Array.from(S.resetParams),
    keep_going: $("keep-going").checked,
    verify_after: $("verify-after").checked,
    force: $("force").checked,
  };
  if (verb === "remove") body.confirm = true;
  clearLog();
  clearRollbackBanner();
  S.results = new Map();
  S.rollingBack = false;
  renderResults();
  $("current-item").hidden = true;
  try {
    const data = await api("POST", "/api/run", body);
    S.activeRunId = data.run_id;
    setRunning(true);
    setTab("log");
    connectEvents(S.activeRunId);
    toast("已开始执行：" + data.run_id, "ok");
  } catch (err) {
    setRunning(false);
  }
}

// ---------- 卸载 ----------

async function refreshInstalled() {
  try {
    const data = await api("GET", "/api/installed");
    S.installed = data.entries || [];
    S.catalogTools = data.catalog_tools || [];
  } catch (err) {
    S.installed = [];
    S.catalogTools = [];
  }
  renderRemoveList();
}

function removeTargets() {
  const byId = new Map();
  S.installed.forEach((entry) => {
    if (!entry.id) return;
    byId.set(entry.id, {
      id: entry.id,
      action: entry.action || "",
      artifacts: entry.artifacts || [],
    });
  });
  S.catalogTools.forEach((tool) => {
    if (!tool.id || byId.has(tool.id)) return;
    if (tool.type !== "config" && !(tool.artifacts || []).length) return;
    byId.set(tool.id, {
      id: tool.id,
      action: tool.action || "",
      artifacts: tool.artifacts || [],
    });
  });
  return Array.from(byId.values());
}

function renderRemoveList() {
  const list = $("remove-list");
  clear(list);
  const targets = removeTargets();
  if (!targets.length) {
    list.appendChild(make("p", "没有可卸载的已安装工具", "hint"));
    return;
  }
  targets.forEach((entry) => {
    const line = make("label", null, "tool-row");
    const box = document.createElement("input");
    box.type = "checkbox";
    box.value = entry.id;
    line.appendChild(box);
    line.appendChild(make("span", entry.id + (entry.action ? " · " + entry.action : ""), "tool-id"));
    if ((entry.artifacts || []).length) {
      line.appendChild(make("span", " · " + entry.artifacts.join(" "), "hint"));
    }
    list.appendChild(line);
  });
}

function openRemoveModal() {
  const picked = Array.from($("remove-list").querySelectorAll("input:checked")).map((b) => b.value);
  if (!picked.length) {
    toast("请先勾选要卸载的工具", "warn");
    return;
  }
  const targets = new Map(removeTargets().map((entry) => [entry.id, entry]));
  const details = picked.map((id) => {
    const entry = targets.get(id);
    const artifacts = entry && entry.artifacts && entry.artifacts.length
      ? "（产物：" + entry.artifacts.join("、") + "）" : "";
    return id + artifacts;
  });
  $("confirm-text").textContent = "将卸载：" + details.join("；") + "。该操作会删除已写入的配置，确认继续？";
  $("confirm-modal").hidden = false;
  $("confirm-ok").onclick = async () => {
    $("confirm-modal").hidden = true;
    S.selection = new Set(picked);
    await startRun("remove");
  };
}

// ---------- 历史 ----------

async function refreshHistory() {
  try {
    const runs = await api("GET", "/api/history");
    const box = $("history");
    clear(box);
    if (!Array.isArray(runs) || !runs.length) {
      box.appendChild(make("p", "暂无历史记录", "hint"));
      return;
    }
    runs.forEach((run) => {
      const button = make("button", null, "history-row");
      button.type = "button";
      button.appendChild(make("span", run.run_id, "history-id"));
      button.appendChild(make("span", (run.verb || "") + " · rc=" + run.rc, "history-meta"));
      button.addEventListener("click", () => loadHistory(run.run_id));
      box.appendChild(button);
    });
  } catch (err) {
    /* toast 已由 api() 处理 */
  }
}

async function loadHistory(runId) {
  try {
    const data = await api("GET", "/api/history/" + encodeURIComponent(runId));
    S.results = new Map();
    S.rollingBack = false;
    clearRollbackBanner();
    (data.events || []).forEach((event) => {
      if (event.event === "item_end") handleItem(event);
      if (event.event === "rollback") S.rollingBack = true;
    });
    renderResults();
    renderTools();
    clearLog();
    (data.log || "").split("\n").forEach((line) => {
      if (line) appendLog(line);
    });
    $("log").scrollTop = 0;
    setTab("results");
    toast("已载入历史：" + runId);
  } catch (err) {
    /* toast 已由 api() 处理 */
  }
}

// ---------- 日志导出 ----------

async function copyLog() {
  try {
    await navigator.clipboard.writeText($("log").textContent || "");
    toast("日志已复制", "ok");
  } catch (err) {
    toast("复制失败，请手动选择日志", "error");
  }
}

function downloadLog() {
  const blob = new Blob([$("log").textContent || ""], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = "os-config-" + (S.activeRunId || "log") + ".log";
  document.body.appendChild(anchor);
  anchor.click();
  document.body.removeChild(anchor);
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// ---------- 引导 ----------

async function bootstrap() {
  stripToken();
  try {
    const cat = await api("GET", "/api/catalog");
    const st = await api("GET", "/api/state");
    S.catalog = cat.catalog || [];
    S.catalogById = new Map(S.catalog.map((tool) => [tool.id, tool]));
    S.profiles = cat.profiles || st.profiles || [];
    S.paramGroups = cat.param_groups || [];
    S.secrets = st.secrets || {};
    S.originalParams = Object.assign({}, st.params || {});
    const selection = st.selection || {};
    const tools = Array.isArray(selection.tools) ? selection.tools : defaultProfileTools();
    S.selection = new Set([].concat(tools, selection.adhoc || []));
    renderPreset();
    renderTools();
    renderParams();
    renderResults();
    setRunning(!!st.running);
    renderSudo();
    refreshInstalled();
    refreshHistory();
    schedulePlan(0);
    if (st.running) connectEvents(st.current && st.current.run_id);
  } catch (err) {
    setRunning(false);
  }
}

function wireEvents() {
  $("search").addEventListener("input", () => {
    renderTools();
  });
  $("preset").addEventListener("change", () => {
    const name = $("preset").value;
    if (!name) return;
    const profile = S.profiles.find((p) => p.name === name);
    if (!profile) return;
    S.selection = new Set(profile.tools || []);
    renderTools();
    selectionChanged();
  });
  $("select-all").addEventListener("click", () => {
    visibleIds().forEach((id) => S.selection.add(id));
    renderTools();
    selectionChanged();
  });
  $("select-none").addEventListener("click", () => {
    visibleIds().forEach((id) => S.selection.delete(id));
    renderTools();
    selectionChanged();
  });
  $("keep-going").addEventListener("change", () => {
    const hint = document.querySelector(".options .hint");
    if (hint) {
      hint.textContent = $("keep-going").checked
        ? "开启时：某项失败后继续执行其余项。"
        : "关闭时：遇到失败立即回滚并停止。";
    }
  });
  $("clear-secrets").addEventListener("change", () => {
    applyClearSecrets($("clear-secrets").checked);
  });
  $("plan-btn").addEventListener("click", () => runPlan());
  $("status-btn").addEventListener("click", () => checkStatus());
  $("run-btn").addEventListener("click", () => startRun("install"));
  $("remove-btn").addEventListener("click", openRemoveModal);
  $("confirm-cancel").addEventListener("click", () => {
    $("confirm-modal").hidden = true;
  });
  TABS.forEach((name) => {
    const button = $(name + "-tab");
    button.addEventListener("click", () => setTab(name));
    button.addEventListener("keydown", (ev) => {
      let next = null;
      const index = TABS.indexOf(S.tab);
      if (ev.key === "ArrowRight") next = (index + 1) % TABS.length;
      else if (ev.key === "ArrowLeft") next = (index - 1 + TABS.length) % TABS.length;
      else if (ev.key === "Home") next = 0;
      else if (ev.key === "End") next = TABS.length - 1;
      if (next === null) return;
      ev.preventDefault();
      setTab(TABS[next]);
      $(TABS[next] + "-tab").focus();
    });
  });
  $("history-refresh").addEventListener("click", refreshHistory);
  $("log-copy").addEventListener("click", copyLog);
  $("log-download").addEventListener("click", downloadLog);
}

wireEvents();
bootstrap();
