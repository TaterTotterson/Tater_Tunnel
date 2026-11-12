"use strict";

const HEALTH_REFRESH_MS = 10_000;
const CONTROL_REFRESH_MS = 30_000;
const HEALTH_FRESH_MS = 35_000;
const JOB_POLL_MS = 1_000;
const SERVICE_PRESETS = {
  tater: { name: "tater", host: "127.0.0.1", port: 8501, protocol: "tcp" },
  matrix: { name: "matrix", host: "127.0.0.1", port: 8008, protocol: "tcp" },
  emby: { name: "emby", host: "127.0.0.1", port: 8096, protocol: "tcp" }
};

const defaultState = {
  paired: false,
  migrationRequired: false,
  vps: "",
  version: "",
  homeAgent: { runtime: null, accessForwarding: null },
  vpsAgent: null,
  devices: [],
  accessRoutes: {},
  accessAddress: "10.88.0.2"
};

let state = structuredClone(defaultState);
let control = null;
let controlError = "";
let connectionError = "";
let currentApp = "";
let activeFilter = "all";
let reconnectMode = false;
let refreshInFlight = false;
let healthTimer = null;
let controlTimer = null;
let toastTimer = null;

const $ = (id) => document.getElementById(id);
const elements = Object.fromEntries([
  "setupScreen", "controlShell", "pairForm", "vpsAddress", "pairingCode", "setupError",
  "cancelReconnect", "mobileMenu", "currentViewLabel", "refreshButton", "liveState",
  "liveStateText", "vpsIdentity", "vpsIdentityStatus", "reconnectButton", "appCount",
  "overviewTitle", "overviewCopy", "cpuValue", "cpuMeter", "cpuDetail", "memoryValue",
  "memoryMeter", "memoryDetail", "diskValue", "diskMeter", "diskDetail", "uptimeValue",
  "uptimeDetail", "overviewApps", "tunnelBadge", "tunnelCheckTime", "uploadValue",
  "downloadValue", "overviewDevices", "checkAppsButton", "appSummary", "appCatalog",
  "addServiceButton", "deviceForm", "personName", "deviceName", "deviceType", "serviceForm",
  "servicePreset", "serviceName", "serviceHost", "servicePort", "serviceProtocol",
  "serviceAccessPort", "deviceCountBadge", "deviceList", "routeList", "qrPanel", "qrImage",
  "qrTitle", "qrToken", "closeQrButton", "homeVersion", "vpsVersion", "updateVpsName",
  "vpsUpdateBadge", "checkUpdatesButton", "updateVpsButton", "vpsUpdateMessage", "systemFacts",
  "processList", "auditButton", "auditBadge",
  "auditOutput", "appDialog", "appManagerForm", "closeAppDialog", "cancelAppChanges",
  "disableAppButton", "saveAppChanges", "dialogAppMark", "dialogTitle", "sftpgoRuntimeBadge",
  "sftpgoEndpoints", "sftpgoStorage", "sftpAccess", "ftpAccess", "webdavAccess",
  "webdavDomainField", "webdavDomain", "cloudflareEnabled", "cloudflareZone",
  "cloudflareToken", "cloudflareIpv4", "zncRuntimeBadge", "zncEndpoints", "zncUser",
  "zncDataDir", "zncIrcPort", "zncWebPort", "zncInitialAdmin", "zncAdminUser",
  "zncAdminPassword", "jobPanel", "jobTitle", "jobMessage", "toast"
].map((id) => [id, $(id)]));

bindEvents();
boot();

function bindEvents() {
  elements.pairForm.addEventListener("submit", pairVps);
  elements.cancelReconnect.addEventListener("click", () => { reconnectMode = false; renderShell(); });
  elements.reconnectButton.addEventListener("click", () => {
    reconnectMode = true;
    elements.vpsAddress.value = state.vps || "";
    elements.pairingCode.value = "";
    elements.cancelReconnect.hidden = false;
    showSetupMessage("Reopen pairing from the VPS setup menu, then enter its fresh one-time code.");
    renderShell();
  });
  elements.mobileMenu.addEventListener("click", () => elements.controlShell.classList.toggle("menu-open"));
  elements.refreshButton.addEventListener("click", () => refreshAll(false));
  elements.checkAppsButton.addEventListener("click", () => refreshControl(false));
  elements.checkUpdatesButton.addEventListener("click", () => refreshAll(false));
  elements.updateVpsButton.addEventListener("click", updateVps);
  elements.auditButton.addEventListener("click", runSecurityAudit);
  elements.addServiceButton.addEventListener("click", () => openInlineForm(elements.serviceForm, elements.serviceName));
  document.querySelectorAll("[data-open-device]").forEach((button) => button.addEventListener("click", () => {
    showView("tunnel");
    openInlineForm(elements.deviceForm, elements.personName);
  }));
  document.querySelectorAll("[data-cancel-form]").forEach((button) => button.addEventListener("click", () => {
    button.closest("form").hidden = true;
  }));
  elements.deviceForm.addEventListener("submit", addDevice);
  elements.serviceForm.addEventListener("submit", addService);
  elements.servicePreset.addEventListener("change", applyServicePreset);
  elements.closeQrButton.addEventListener("click", () => { elements.qrPanel.hidden = true; });
  elements.closeAppDialog.addEventListener("click", closeAppDialog);
  elements.cancelAppChanges.addEventListener("click", closeAppDialog);
  elements.disableAppButton.addEventListener("click", disableCurrentApp);
  elements.appManagerForm.addEventListener("submit", saveAppChanges);
  elements.webdavAccess.addEventListener("change", syncConditionalFields);
  elements.cloudflareEnabled.addEventListener("change", syncConditionalFields);
  elements.zncUser.addEventListener("input", () => {
    if (!getApp("znc")?.settings?.hasConfig) {
      elements.zncDataDir.value = elements.zncUser.value ? `/home/${elements.zncUser.value}/.znc` : "";
    }
  });
  document.querySelectorAll("[data-view]").forEach((button) => button.addEventListener("click", () => showView(button.dataset.view)));
  document.querySelectorAll("[data-go]").forEach((button) => button.addEventListener("click", () => showView(button.dataset.go)));
  document.querySelectorAll("[data-filter]").forEach((button) => button.addEventListener("click", () => {
    activeFilter = button.dataset.filter;
    renderApps();
  }));
}

async function boot() {
  try {
    state = normalizeState(await requestApi("/api/state"));
  } catch (error) {
    connectionError = `Home Agent API is not available: ${error.message}`;
  }
  document.body.classList.remove("is-loading");
  renderShell();
  if (state.paired) {
    await refreshAll(true);
    healthTimer = window.setInterval(() => refreshHealth(true), HEALTH_REFRESH_MS);
    controlTimer = window.setInterval(() => refreshControl(true), CONTROL_REFRESH_MS);
  }
}

async function pairVps(event) {
  event.preventDefault();
  const vpsAddress = elements.vpsAddress.value.trim();
  const pairingCode = elements.pairingCode.value.trim().toUpperCase();
  if (!vpsAddress || !pairingCode) return showSetupMessage("Enter the VPS URL and one-time pairing code.", true);
  await withBusy(elements.pairForm, async () => {
    try {
      const result = await requestApi("/api/pair", { method: "POST", body: { vpsAddress, pairingCode } });
      state = normalizeState(result);
      reconnectMode = false;
      connectionError = "";
      elements.pairingCode.value = "";
      elements.cancelReconnect.hidden = true;
      renderShell();
      await refreshAll(true);
      if (!healthTimer) healthTimer = window.setInterval(() => refreshHealth(true), HEALTH_REFRESH_MS);
      if (!controlTimer) controlTimer = window.setInterval(() => refreshControl(true), CONTROL_REFRESH_MS);
    } catch (error) {
      showSetupMessage(pairingErrorMessage(error), true);
    }
  });
}

async function refreshAll(silent = true) {
  if (!state.paired || refreshInFlight) return;
  refreshInFlight = true;
  elements.refreshButton.disabled = true;
  try {
    await refreshHealth(true);
    await refreshControl(true);
    if (!silent) showToast("VPS, apps, and tunnel status refreshed.");
  } finally {
    refreshInFlight = false;
    elements.refreshButton.disabled = false;
  }
}

async function refreshHealth(silent = true) {
  if (!state.paired) return;
  try {
    state = normalizeState(await requestApi("/api/health", { method: "POST", body: {} }));
    connectionError = "";
  } catch (error) {
    connectionError = error.message || "The private tunnel did not answer.";
    if (!silent) showToast(connectionError, true);
  }
  renderStatus();
  renderTunnel();
  renderOverview();
}

async function refreshControl(silent = true) {
  if (!state.paired) return;
  try {
    control = await requestApi("/api/control/overview");
    controlError = "";
  } catch (error) {
    controlError = /endpoint not found|control helper is unavailable/i.test(String(error.message || ""))
      ? "Update the VPS Agent to enable Control Center app management."
      : (error.message || "VPS controls are unavailable.");
    if (!silent) showToast(controlError, true);
  }
  renderControl();
}

function renderShell() {
  const showSetup = !state.paired || reconnectMode;
  elements.setupScreen.hidden = !showSetup;
  elements.controlShell.hidden = showSetup;
  if (showSetup) {
    elements.cancelReconnect.hidden = !state.paired;
    if (state.vps && !elements.vpsAddress.value) elements.vpsAddress.value = state.vps;
    if (state.migrationRequired) showSetupMessage("This installation needs to be paired again after the VPS is updated.", true);
    if (connectionError && !state.paired) showSetupMessage(connectionError, true);
    return;
  }
  renderStatus();
  renderOverview();
  renderControl();
  renderTunnel();
  renderUpdates();
}

function renderStatus() {
  const status = connectionStatus();
  elements.liveStateText.textContent = status.label;
  elements.liveState.classList.toggle("is-bad", status.kind === "bad");
  elements.vpsIdentity.textContent = vpsDisplayName();
  elements.vpsIdentityStatus.textContent = status.short;
  elements.overviewTitle.textContent = status.kind === "good" ? "Everything is running smoothly." : status.title;
  elements.overviewCopy.textContent = status.detail;
  elements.tunnelBadge.textContent = status.kind === "good" ? "Healthy" : status.short;
  elements.tunnelBadge.className = `state-badge ${status.kind === "good" ? "is-good" : "is-warm"}`;
  elements.tunnelCheckTime.textContent = status.kind === "good" ? formatCheckTime(state.vpsAgent?.health?.checkedAt) : "Waiting";
}

function renderControl() {
  renderMetrics();
  renderApps();
  renderSystem();
  renderUpdates();
}

function renderMetrics() {
  const system = control?.system || {};
  setMetric(elements.cpuValue, elements.cpuMeter, elements.cpuDetail, system.cpuPercent, `${number(system.cpuPercent)}%`, `${system.cpuCount || 0} virtual cores / load ${number(system.load1)}`);
  const memory = system.memory || {};
  setMetric(elements.memoryValue, elements.memoryMeter, elements.memoryDetail, memory.percent, formatBytes(memory.usedBytes), `of ${formatBytes(memory.totalBytes)}`);
  const disk = system.disk || {};
  setMetric(elements.diskValue, elements.diskMeter, elements.diskDetail, disk.percent, formatBytes(disk.usedBytes), `${formatBytes(disk.freeBytes)} available`);
  elements.uptimeValue.textContent = system.uptimeLabel || "--";
  elements.uptimeDetail.textContent = system.hostname ? `Host ${system.hostname}` : (controlError || "Waiting for VPS");
}

function setMetric(valueElement, meterElement, detailElement, percent, value, detail) {
  valueElement.textContent = percent === undefined ? "--" : value;
  meterElement.style.width = `${Math.max(0, Math.min(100, Number(percent) || 0))}%`;
  detailElement.textContent = percent === undefined ? (controlError || "Waiting for VPS") : detail;
}

function renderApps() {
  const apps = [getApp("sftpgo"), getApp("znc")].filter(Boolean);
  const installed = apps.filter((app) => app.installed).length;
  elements.appCount.textContent = String(installed);
  elements.appSummary.textContent = control ? `${installed} installed, ${apps.length - installed} available` : (controlError || "Checking apps");
  document.querySelectorAll("[data-filter]").forEach((button) => button.classList.toggle("is-selected", button.dataset.filter === activeFilter));
  elements.appCatalog.replaceChildren();
  if (!control) {
    elements.appCatalog.append(emptyRow(controlError || "Waiting for the VPS control helper."));
    renderOverviewApps([]);
    return;
  }
  const visibleApps = apps.filter((app) => activeFilter === "all" || (activeFilter === "installed") === Boolean(app.installed));
  if (!visibleApps.length) elements.appCatalog.append(emptyRow(`No ${activeFilter} apps.`));
  visibleApps.forEach((app) => {
    const row = document.createElement("article");
    row.className = "app-row";
    row.dataset.appKind = app.installed ? "installed" : "available";
    const endpoints = (app.endpoints || []).slice(0, 2).map((item) => `<code>${escapeHtml(item.url)}</code>`).join("");
    const detail = app.id === "sftpgo"
      ? `<span>Storage</span><strong>${formatBytes(app.storage?.usedBytes)}</strong>`
      : `<span>Networks</span><strong>${app.settings?.networkCount || 0}</strong>`;
    row.innerHTML = `<div class="app-mark ${app.id === "sftpgo" ? "app-mark-files" : "app-mark-chat"}">${app.name.charAt(0)}</div><div class="app-description"><div><h2>${escapeHtml(app.name)}</h2><span class="state-badge ${app.service?.active ? "is-good" : ""}">${app.service?.active ? "Running" : app.installed ? "Stopped" : "Available"}</span></div><p>${app.id === "sftpgo" ? "Secure file access with SFTP, FTP, WebDAV, quotas, and private administration." : "Always-on IRC bouncer with a private web console and managed listeners."}</p><div class="endpoint-preview"><span>WG</span>${endpoints || "<code>Configure to create private links</code>"}</div></div><div class="app-facts"><span>Version</span><strong>${escapeHtml(app.version || "Not installed")}</strong>${detail}</div>`;
    const button = document.createElement("button");
    button.type = "button";
    button.className = `button ${app.installed ? "button-secondary" : "button-primary"}`;
    button.textContent = app.installed ? "Manage" : "Install";
    button.addEventListener("click", () => openAppDialog(app.id));
    row.append(button);
    elements.appCatalog.append(row);
  });
  renderOverviewApps(apps);
}

function renderOverviewApps(apps) {
  elements.overviewApps.replaceChildren();
  if (!apps.length) return elements.overviewApps.append(emptyRow(controlError || "No app status yet."));
  apps.forEach((app) => {
    const row = document.createElement("article");
    row.className = "service-row";
    row.innerHTML = `<div class="app-mark ${app.id === "sftpgo" ? "app-mark-files" : "app-mark-chat"}">${app.name.charAt(0)}</div><div class="service-main"><strong>${escapeHtml(app.name)}</strong><span>${app.id === "sftpgo" ? "Files and WebDAV" : "IRC bouncer"}</span></div><span class="state-badge ${app.service?.active ? "is-good" : ""}">${app.service?.active ? "Running" : app.installed ? "Stopped" : "Available"}</span><div class="service-meta"><strong>${escapeHtml(app.version || "-")}</strong><span>version</span></div>`;
    const button = document.createElement("button");
    button.className = "row-button";
    button.type = "button";
    button.textContent = app.installed ? "Manage" : "Install";
    button.addEventListener("click", () => openAppDialog(app.id));
    row.append(button);
    elements.overviewApps.append(row);
  });
}

function renderOverview() {
  const devices = state.devices || [];
  elements.overviewDevices.replaceChildren();
  if (!devices.length) elements.overviewDevices.append(emptyRow("No approved devices yet."));
  devices.slice(0, 3).forEach((device) => elements.overviewDevices.append(deviceRow(device, false)));
  let rx = 0;
  let tx = 0;
  devices.forEach((device) => {
    rx += Number(device.wireguard?.live?.transferRxBytes || 0);
    tx += Number(device.wireguard?.live?.transferTxBytes || 0);
  });
  elements.uploadValue.textContent = formatBytes(rx);
  elements.downloadValue.textContent = formatBytes(tx);
}

function renderTunnel() {
  const devices = state.devices || [];
  const connected = devices.filter(isDeviceConnected).length;
  elements.deviceCountBadge.textContent = `${connected} online / ${devices.length} approved`;
  elements.deviceCountBadge.className = `state-badge ${connected ? "is-good" : ""}`;
  elements.deviceList.replaceChildren();
  if (!devices.length) elements.deviceList.append(emptyRow("No devices have been approved."));
  devices.forEach((device) => elements.deviceList.append(deviceRow(device, true)));

  elements.routeList.replaceChildren();
  const routes = Object.entries(state.accessRoutes || {});
  if (!routes.length) elements.routeList.append(emptyRow("No home services have been shared."));
  const listeners = new Map((state.homeAgent?.accessForwarding?.listeners || []).map((item) => [item.name, item]));
  const errors = state.homeAgent?.accessForwarding?.errors || {};
  routes.forEach(([name, route]) => {
    const row = document.createElement("div");
    const active = listeners.has(name) && !errors[name];
    row.innerHTML = `<span class="route-port">${escapeHtml(route.accessPort)}</span><div><strong>${escapeHtml(name)}</strong><small>${escapeHtml(route.targetHost)}:${escapeHtml(route.targetPort)} / ${String(route.protocol || "tcp").toUpperCase()}<br>Use ${escapeHtml(route.accessAddress || state.accessAddress || "10.88.0.2")}:${escapeHtml(route.accessPort)}</small></div>`;
    const action = document.createElement("button");
    action.className = "row-button danger-row-button";
    action.type = "button";
    action.textContent = active ? "Remove" : "Fix / remove";
    action.title = errors[name] || "Remove private service";
    action.addEventListener("click", () => removeService(name, action));
    row.append(action);
    elements.routeList.append(row);
  });
}

function deviceRow(device, actionable) {
  const row = document.createElement("div");
  const connected = isDeviceConnected(device);
  row.className = `device-row ${connected ? "" : "is-muted"}`.trim();
  row.innerHTML = `<span class="device-icon">${escapeHtml((device.name || "D").charAt(0).toUpperCase())}</span><div><strong>${escapeHtml(device.name || "Device")}</strong><span>${escapeHtml(device.type || "Device")} / ${escapeHtml(device.person || "Tater user")}${actionable ? ` / ${escapeHtml(formatTransfer(device.wireguard?.live || {}))}` : ""}</span></div><div class="last-seen"><strong>${connected ? "Connected" : "Waiting"}</strong><span>${escapeHtml(device.lastSeen || "No handshake yet")}</span></div>`;
  if (actionable) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "row-button danger-row-button";
    button.textContent = "Revoke";
    button.addEventListener("click", () => revokeDevice(device.id, device.name, button));
    row.append(button);
  } else {
    const dot = document.createElement("span");
    dot.className = connected ? "pulse-dot" : "offline-dot";
    row.append(dot);
  }
  return row;
}

function renderSystem() {
  const system = control?.system || {};
  const facts = [
    ["Hostname", system.hostname], ["Operating system", system.operatingSystem],
    ["Kernel", system.kernel], ["Architecture", system.architecture],
    ["Private address", "10.88.0.1"], ["CPU", system.cpuCount ? `${system.cpuCount} cores` : ""]
  ];
  elements.systemFacts.replaceChildren();
  facts.forEach(([label, value]) => {
    const row = document.createElement("div");
    row.innerHTML = `<dt>${label}</dt><dd>${escapeHtml(value || "Unavailable")}</dd>`;
    elements.systemFacts.append(row);
  });
  elements.processList.replaceChildren();
  const processes = system.topProcesses || [];
  if (!processes.length) elements.processList.append(emptyRow("No process sample is available."));
  processes.forEach((process) => {
    const row = document.createElement("div");
    row.className = "process-row";
    row.innerHTML = `<strong>${escapeHtml(process.name || "process")} <span>PID ${escapeHtml(process.pid)}</span></strong><span>${number(process.cpuPercent)}% CPU</span><span>${number(process.memoryPercent)}% memory</span>`;
    elements.processList.append(row);
  });
}

function renderUpdates() {
  elements.homeVersion.textContent = state.version || "--";
  elements.vpsVersion.textContent = state.vpsAgent?.health?.version || control?.updates?.vps?.installed || "--";
  elements.updateVpsName.textContent = vpsDisplayName();
  const update = control?.updates?.vps;
  const status = update?.status || "current";
  const statusLabels = { current: "Current", scheduled: "Scheduled", running: "Updating", complete: "Updated", failed: "Failed" };
  elements.vpsUpdateBadge.textContent = statusLabels[status] || "Ready";
  elements.vpsUpdateBadge.className = `state-badge ${["current", "complete"].includes(status) ? "is-good" : "is-warm"}`;
  elements.vpsUpdateMessage.textContent = update?.message || "Checks the official stable releases.";
  elements.updateVpsButton.hidden = control?.capabilities?.vpsUpdate !== true;
  elements.updateVpsButton.disabled = ["scheduled", "running"].includes(status);
}

async function updateVps() {
  if (!window.confirm("Update the VPS Agent from the newest official stable release? Pairing, devices, routes, and app settings will be preserved.")) return;
  elements.updateVpsButton.disabled = true;
  elements.vpsUpdateMessage.textContent = "Scheduling the protected VPS update.";
  try {
    await runJob("update-vps", {}, "Scheduling VPS update", false);
    showToast("VPS update started. The private tunnel may pause briefly.");
    await waitForVpsUpdate();
    showToast("The VPS Agent update is complete.");
  } catch (error) {
    showToast(error.message, true);
  } finally {
    elements.updateVpsButton.disabled = false;
  }
}

async function waitForVpsUpdate() {
  const deadline = Date.now() + 10 * 60 * 1000;
  let lastError = "";
  await wait(6_000);
  while (Date.now() < deadline) {
    elements.vpsUpdateMessage.textContent = "Waiting for the VPS Agent to restart.";
    try {
      state = normalizeState(await requestApi("/api/health", { method: "POST", body: {} }));
      control = await requestApi("/api/control/overview");
      connectionError = "";
      controlError = "";
      renderStatus();
      renderControl();
      const update = control?.updates?.vps || {};
      if (update.status === "failed") throw new Error(update.message || "The VPS update failed.");
      if (["current", "complete"].includes(update.status)) return;
    } catch (error) {
      lastError = error.message || "The private tunnel is restarting.";
      if (/update failed/i.test(lastError)) throw error;
    }
    await wait(3_000);
  }
  throw new Error(lastError || "Timed out waiting for the VPS Agent update.");
}

function openAppDialog(appId) {
  const app = getApp(appId);
  if (!app) return showToast(controlError || "App controls are not available.", true);
  currentApp = appId;
  elements.dialogTitle.textContent = app.name;
  elements.dialogAppMark.textContent = app.name.charAt(0);
  elements.dialogAppMark.className = `app-mark ${appId === "sftpgo" ? "app-mark-files" : "app-mark-chat"}`;
  document.querySelectorAll("[data-config-app]").forEach((section) => { section.hidden = section.dataset.configApp !== appId; });
  elements.disableAppButton.hidden = !app.installed || !app.service?.active;
  elements.jobPanel.hidden = true;
  elements.saveAppChanges.disabled = false;
  if (appId === "sftpgo") fillSftpgoForm(app); else fillZncForm(app);
  elements.appDialog.showModal();
}

function fillSftpgoForm(app) {
  const settings = app.settings || {};
  elements.sftpgoRuntimeBadge.textContent = app.service?.active ? "Running" : app.installed ? "Stopped" : "Ready to install";
  elements.sftpgoRuntimeBadge.className = `state-badge ${app.service?.active ? "is-good" : ""}`;
  elements.sftpgoStorage.value = settings.maxStorageGb || 20;
  elements.sftpAccess.value = settings.sftpAccess || "private";
  elements.ftpAccess.value = settings.ftpAccess || "disabled";
  elements.webdavAccess.value = settings.webdavAccess || "disabled";
  elements.webdavDomain.value = settings.webdavDomain || "";
  elements.cloudflareEnabled.checked = false;
  elements.cloudflareZone.value = "";
  elements.cloudflareToken.value = "";
  elements.cloudflareIpv4.value = "";
  renderEndpoints(elements.sftpgoEndpoints, app.endpoints || []);
  syncConditionalFields();
}

function fillZncForm(app) {
  const settings = app.settings || {};
  elements.zncRuntimeBadge.textContent = app.service?.active ? "Running" : app.installed ? "Stopped" : "Ready to install";
  elements.zncRuntimeBadge.className = `state-badge ${app.service?.active ? "is-good" : ""}`;
  elements.zncUser.value = settings.user || control?.system?.suggestedUser || "";
  elements.zncDataDir.value = settings.dataDir || (elements.zncUser.value ? `/home/${elements.zncUser.value}/.znc` : "");
  elements.zncIrcPort.value = settings.ircPort || 6697;
  elements.zncWebPort.value = settings.webPort || 6698;
  elements.zncAdminUser.value = settings.adminUser || "";
  elements.zncAdminPassword.value = "";
  elements.zncInitialAdmin.hidden = Boolean(settings.hasConfig);
  renderEndpoints(elements.zncEndpoints, app.endpoints || []);
}

function renderEndpoints(container, endpoints) {
  container.replaceChildren();
  if (!endpoints.length) return container.append(emptyRow("Private links appear after installation."));
  endpoints.forEach((endpoint) => {
    const row = document.createElement("div");
    const label = document.createElement("span");
    label.textContent = endpoint.label;
    const code = document.createElement("code");
    code.textContent = endpoint.url;
    const copy = document.createElement("button");
    copy.type = "button";
    copy.textContent = "Copy";
    copy.addEventListener("click", () => copyText(endpoint.url));
    row.append(label, code, copy);
    container.append(row);
  });
}

function syncConditionalFields() {
  const https = elements.webdavAccess.value === "https";
  elements.webdavDomainField.classList.toggle("is-hidden", !https);
  if (!https) elements.cloudflareEnabled.checked = false;
  document.querySelectorAll(".cloudflare-field").forEach((field) => field.classList.toggle("is-hidden", !elements.cloudflareEnabled.checked));
}

async function saveAppChanges(event) {
  event.preventDefault();
  const app = getApp(currentApp);
  if (!app) return;
  let settings;
  if (currentApp === "sftpgo") {
    settings = {
      sftpAccess: elements.sftpAccess.value,
      ftpAccess: elements.ftpAccess.value,
      webdavAccess: elements.webdavAccess.value,
      webdavDomain: elements.webdavDomain.value.trim(),
      maxStorageGb: elements.sftpgoStorage.value
    };
    if ([settings.sftpAccess, settings.ftpAccess, settings.webdavAccess].every((value) => value === "disabled")) return showToast("Enable at least one SFTPGo protocol.", true);
    if (settings.ftpAccess === "public" && !window.confirm("Public FTP is unencrypted. Open it to the internet anyway?")) return;
    settings.allowInsecurePublicFtp = settings.ftpAccess === "public";
    if (elements.cloudflareEnabled.checked) {
      settings.cloudflare = { enabled: true, zone: elements.cloudflareZone.value.trim(), apiToken: elements.cloudflareToken.value.trim(), publicIpv4: elements.cloudflareIpv4.value.trim() };
    }
  } else {
    settings = { user: elements.zncUser.value.trim(), ircPort: elements.zncIrcPort.value, webPort: elements.zncWebPort.value };
    if (!app.settings?.hasConfig) {
      settings.adminUser = elements.zncAdminUser.value.trim();
      settings.adminPassword = elements.zncAdminPassword.value;
    }
  }
  try {
    await runJob("configure-app", { app: currentApp, settings }, `Configuring ${app.name}`);
    elements.cloudflareToken.value = "";
    elements.zncAdminPassword.value = "";
    await refreshControl(true);
    closeAppDialog();
    showToast(`${app.name} is ready.`);
  } catch (error) {
    showToast(error.message, true);
  }
}

async function disableCurrentApp() {
  const app = getApp(currentApp);
  if (!app || !window.confirm(`Stop ${app.name} and disable it at startup? Its configuration and data will be kept.`)) return;
  try {
    await runJob("service-action", { app: currentApp, action: "disable" }, `Disabling ${app.name}`);
    await refreshControl(true);
    closeAppDialog();
    showToast(`${app.name} is disabled. Its data was kept.`);
  } catch (error) {
    showToast(error.message, true);
  }
}

async function runSecurityAudit() {
  elements.auditButton.disabled = true;
  elements.auditBadge.textContent = "Running";
  elements.auditBadge.className = "state-badge is-warm";
  try {
    const result = await runJob("security-audit", {}, "Running security audit", false);
    elements.auditBadge.textContent = result.passed ? "Passed" : "Needs attention";
    elements.auditBadge.className = `state-badge ${result.passed ? "is-good" : "is-warm"}`;
    elements.auditOutput.replaceChildren();
    const output = document.createElement("pre");
    output.textContent = result.output || "Audit completed without output.";
    elements.auditOutput.append(output);
    showToast(result.passed ? "Security audit passed." : "Security audit found items to review.", !result.passed);
  } catch (error) {
    elements.auditBadge.textContent = "Failed";
    elements.auditBadge.className = "state-badge is-warm";
    showToast(error.message, true);
  } finally {
    elements.auditButton.disabled = false;
  }
}

async function runJob(operation, payload, title, showPanel = true) {
  if (showPanel) {
    elements.jobPanel.hidden = false;
    elements.jobTitle.textContent = title;
    elements.jobMessage.textContent = "The VPS is working. This may take a few minutes.";
    elements.saveAppChanges.disabled = true;
    elements.disableAppButton.disabled = true;
  }
  const started = await requestApi("/api/control/jobs", { method: "POST", body: { operation, payload } });
  const jobId = started.job?.id;
  if (!jobId) throw new Error("The VPS did not return a control job.");
  try {
    while (true) {
      await wait(JOB_POLL_MS);
      const response = await requestApi(`/api/control/jobs/${encodeURIComponent(jobId)}`);
      const job = response.job || {};
      if (showPanel) elements.jobMessage.textContent = job.status === "queued" ? "Waiting for the VPS helper." : "Applying the selected configuration.";
      if (job.status === "complete") return job.result || {};
      if (job.status === "failed") throw new Error(job.error || "VPS control job failed.");
    }
  } finally {
    if (showPanel) {
      elements.saveAppChanges.disabled = false;
      elements.disableAppButton.disabled = false;
    }
  }
}

async function addDevice(event) {
  event.preventDefault();
  await withBusy(elements.deviceForm, async () => {
    try {
      const result = await requestApi("/api/devices", { method: "POST", body: { person: elements.personName.value.trim(), name: elements.deviceName.value.trim(), type: elements.deviceType.value } });
      state = normalizeState(result.state);
      const config = String(result.enrollment?.wireguardConfig || "");
      if (!config) throw new Error("The VPS did not return a WireGuard configuration.");
      window.TaterQr.render(config, elements.qrImage);
      elements.qrTitle.textContent = elements.deviceName.value.trim() || `${elements.personName.value.trim()}'s ${elements.deviceType.value}`;
      elements.qrToken.textContent = config;
      elements.qrPanel.hidden = false;
      elements.deviceForm.reset();
      elements.deviceType.value = "Phone";
      elements.deviceForm.hidden = true;
      renderTunnel();
      renderOverview();
    } catch (error) { showToast(error.message, true); }
  });
}

async function revokeDevice(id, name, button) {
  if (!window.confirm(`Revoke ${name || "this device"}? Its WireGuard profile will stop working.`)) return;
  await withBusy(button, async () => {
    try {
      state = normalizeState(await requestApi(`/api/devices/${encodeURIComponent(id)}`, { method: "DELETE" }));
      renderTunnel();
      renderOverview();
    } catch (error) { showToast(error.message, true); }
  });
}

async function addService(event) {
  event.preventDefault();
  const body = { name: elements.serviceName.value.trim().toLowerCase(), host: elements.serviceHost.value.trim(), port: elements.servicePort.value, protocol: elements.serviceProtocol.value };
  if (elements.serviceAccessPort.value) body.accessPort = elements.serviceAccessPort.value;
  await withBusy(elements.serviceForm, async () => {
    try {
      state = normalizeState(await requestApi("/api/access-routes", { method: "POST", body }));
      elements.serviceForm.reset();
      elements.serviceHost.value = "127.0.0.1";
      elements.serviceProtocol.value = "tcp";
      elements.serviceForm.hidden = true;
      renderTunnel();
      showToast("Private service added.");
    } catch (error) { showToast(error.message, true); }
  });
}

async function removeService(name, button) {
  if (!window.confirm(`Remove the private route for ${name}?`)) return;
  await withBusy(button, async () => {
    try {
      state = normalizeState(await requestApi(`/api/access-routes/${encodeURIComponent(name)}`, { method: "DELETE" }));
      renderTunnel();
    } catch (error) { showToast(error.message, true); }
  });
}

function applyServicePreset() {
  const preset = SERVICE_PRESETS[elements.servicePreset.value];
  if (!preset) return;
  elements.serviceName.value = preset.name;
  elements.serviceHost.value = preset.host;
  elements.servicePort.value = String(preset.port);
  elements.serviceProtocol.value = preset.protocol;
  elements.serviceAccessPort.value = "";
}

function showView(name) {
  document.querySelectorAll("[data-view-panel]").forEach((panel) => panel.classList.toggle("is-visible", panel.dataset.viewPanel === name));
  document.querySelectorAll("[data-view]").forEach((button) => button.classList.toggle("is-active", button.dataset.view === name));
  elements.currentViewLabel.textContent = name.charAt(0).toUpperCase() + name.slice(1);
  elements.controlShell.classList.remove("menu-open");
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function closeAppDialog() {
  if (elements.jobPanel.hidden || elements.saveAppChanges.disabled === false) elements.appDialog.close();
}

function getApp(id) { return control?.apps?.[id] || null; }

function connectionStatus() {
  if (!state.paired) return { kind: "bad", label: "Not connected", short: "Not connected", title: "Connect your VPS.", detail: "Pair the Home Agent to begin." };
  const runtime = state.homeAgent?.runtime || {};
  if (String(runtime.lastAction || "").includes("error")) return { kind: "bad", label: "Tunnel needs attention", short: "Setup issue", title: "WireGuard needs attention.", detail: runtime.message || "The Home Agent could not start its private tunnel." };
  const health = state.vpsAgent?.health || {};
  if (health.status === "ok" && isRecent(health.checkedAt, HEALTH_FRESH_MS) && !connectionError) return { kind: "good", label: "Private path healthy", short: "VPS connected", title: "Everything is running smoothly.", detail: `Last checked ${formatCheckTime(health.checkedAt)} through the private management tunnel.` };
  if (connectionError) return { kind: "bad", label: "Private path unavailable", short: "Not connected", title: "The private tunnel is not responding.", detail: connectionError };
  return { kind: "warm", label: "Starting private path", short: "Starting", title: "Starting your private tunnel.", detail: "The VPS is paired and the Home Agent is waiting for a fresh check." };
}

function normalizeState(payload) {
  const source = payload?.state || payload || {};
  return { ...structuredClone(defaultState), ...source, homeAgent: { ...defaultState.homeAgent, ...(source.homeAgent || {}) }, devices: Array.isArray(source.devices) ? source.devices : [], accessRoutes: source.accessRoutes && typeof source.accessRoutes === "object" ? source.accessRoutes : {} };
}

async function requestApi(path, options = {}) {
  const request = { method: options.method || "GET", headers: { Accept: "application/json" } };
  if (options.body !== undefined) {
    request.headers["Content-Type"] = "application/json";
    request.body = JSON.stringify(options.body);
  }
  const response = await fetch(path, request);
  let payload = {};
  try { payload = await response.json(); } catch { payload = {}; }
  if (!response.ok) throw new Error(payload.error || `Request failed with status ${response.status}`);
  return payload;
}

async function withBusy(target, operation) {
  const buttons = target.matches?.("button") ? [target] : [...target.querySelectorAll("button")];
  buttons.forEach((button) => { button.disabled = true; });
  try { return await operation(); } finally { buttons.forEach((button) => { button.disabled = false; }); }
}

function openInlineForm(form, focusTarget) { form.hidden = false; window.setTimeout(() => focusTarget.focus(), 0); }
function emptyRow(message) { const row = document.createElement("div"); row.className = "empty-row"; row.textContent = message; return row; }
function isDeviceConnected(device) { return Boolean(device.wireguard?.live?.connected) || String(device.status).toLowerCase() === "connected"; }
function isRecent(value, maxAge) { const timestamp = Date.parse(value || ""); return Number.isFinite(timestamp) && Date.now() - timestamp < maxAge; }
function formatCheckTime(value) { if (!value) return "just now"; const seconds = Math.max(0, Math.round((Date.now() - Date.parse(value)) / 1000)); return seconds < 60 ? `${seconds}s ago` : `${Math.round(seconds / 60)}m ago`; }
function formatBytes(value) { const bytes = Number(value || 0); if (!bytes) return "0 B"; const units = ["B", "KB", "MB", "GB", "TB"]; const index = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024))); return `${(bytes / (1024 ** index)).toFixed(index > 1 ? 1 : 0)} ${units[index]}`; }
function formatTransfer(live) { return `${formatBytes(live.transferRxBytes)} in / ${formatBytes(live.transferTxBytes)} out`; }
function number(value) { return Number(value || 0).toFixed(Number(value || 0) % 1 ? 1 : 0); }
function vpsDisplayName() { try { return new URL(state.vps).hostname || "VPS"; } catch { return state.vps || "VPS"; } }
function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
function wait(milliseconds) { return new Promise((resolve) => window.setTimeout(resolve, milliseconds)); }

async function copyText(value) {
  try { await navigator.clipboard.writeText(value); showToast(`Copied ${value}`); }
  catch { showToast(value); }
}

function showSetupMessage(message, error = false) {
  elements.setupError.textContent = message;
  elements.setupError.hidden = !message;
  elements.setupError.style.borderLeftColor = error ? "var(--red)" : "var(--cyan)";
}

function showToast(message, error = false) {
  window.clearTimeout(toastTimer);
  elements.toast.textContent = message;
  elements.toast.style.borderColor = error ? "rgba(225,93,82,.4)" : "rgba(120,197,87,.3)";
  elements.toast.classList.add("is-visible");
  toastTimer = window.setTimeout(() => elements.toast.classList.remove("is-visible"), 4200);
}

function pairingErrorMessage(error) {
  const message = String(error?.message || error || "Pairing failed");
  if (/pairing mode is disabled/i.test(message)) return "Pairing is closed on the VPS. Reopen it from the setup menu and use the fresh code.";
  return message;
}
