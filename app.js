"use strict";

const HEALTH_REFRESH_MS = 10_000;
const HEALTH_FRESH_MS = 30_000;
const SERVICE_PRESETS = {
  tater: { name: "tater", host: "127.0.0.1", port: 8501, protocol: "tcp" },
  matrix: { name: "matrix", host: "127.0.0.1", port: 8008, protocol: "tcp" },
  emby: { name: "emby", host: "127.0.0.1", port: 8096, protocol: "tcp" }
};

const defaultState = {
  schemaVersion: 2,
  paired: false,
  migrationRequired: false,
  vps: "",
  wireguardPort: 51888,
  lastCheck: "",
  homeAgent: { wireguard: null, runtime: null, accessForwarding: null },
  management: null,
  vpsAgent: null,
  devices: [],
  accessRoutes: {},
  accessAddress: "10.88.0.2"
};

let state = structuredClone(defaultState);
let apiAvailable = false;
let refreshTimer = null;
let refreshInFlight = false;
let reconnectOpen = false;
let connectionError = "";
const serviceTests = {};

const elements = Object.fromEntries(
  [
    "appShell", "statusText", "metricHome", "metricVps", "metricDevices", "metricServices", "notice",
    "connectionState", "connectionSummary", "connectedVps", "connectionDetail", "checkConnectionButton",
    "pairForm", "vpsAddress", "pairingCode", "connectionSettings", "connectAgainButton", "resetButton",
    "addDeviceButton", "deviceForm", "personName", "deviceName", "deviceType", "cancelDeviceButton",
    "qrPanel", "qrImage", "qrTitle", "qrToken", "closeQrButton", "emptyDevices", "deviceList",
    "addServiceButton", "serviceForm", "servicePreset", "serviceName", "serviceHost", "servicePort",
    "serviceProtocol", "serviceAccessPort", "cancelServiceButton", "emptyServices", "serviceList"
  ].map((id) => [id, document.getElementById(id)])
);

elements.pairForm.addEventListener("submit", handlePair);
elements.checkConnectionButton.addEventListener("click", () => refreshHealth({ silent: false }));
elements.connectAgainButton.addEventListener("click", () => {
  reconnectOpen = !reconnectOpen;
  if (reconnectOpen) {
    elements.vpsAddress.value = state.vps || "";
    elements.pairingCode.value = "";
    window.setTimeout(() => elements.pairingCode.focus(), 0);
  }
  render();
});
elements.resetButton.addEventListener("click", handleReset);

elements.addDeviceButton.addEventListener("click", () => {
  elements.deviceForm.hidden = false;
  elements.personName.focus();
});
elements.cancelDeviceButton.addEventListener("click", () => {
  elements.deviceForm.hidden = true;
});
elements.deviceForm.addEventListener("submit", handleAddDevice);
elements.closeQrButton.addEventListener("click", closeQrPanel);

elements.addServiceButton.addEventListener("click", () => {
  elements.serviceForm.hidden = false;
  elements.serviceName.focus();
});
elements.cancelServiceButton.addEventListener("click", () => {
  elements.serviceForm.hidden = true;
});
elements.servicePreset.addEventListener("change", applyServicePreset);
elements.serviceForm.addEventListener("submit", handleAddService);

boot();

async function boot() {
  try {
    state = normalizeState(await requestApi("/api/state"));
    apiAvailable = true;
  } catch (error) {
    connectionError = `Home Agent API is not available: ${error.message}`;
  }
  render();
  syncRefreshTimer();
  if (apiAvailable && state.paired) {
    refreshHealth({ silent: true });
  }
}

async function handlePair(event) {
  event.preventDefault();
  const vpsAddress = elements.vpsAddress.value.trim();
  const pairingCode = elements.pairingCode.value.trim().toUpperCase();
  if (!vpsAddress || !pairingCode) {
    showNotice("Enter the VPS URL and one-time pairing code.");
    return;
  }

  await withBusy(elements.pairForm, async () => {
    try {
      const result = await requestApi("/api/pair", {
        method: "POST",
        body: { vpsAddress, pairingCode }
      });
      state = normalizeState(result);
      reconnectOpen = false;
      connectionError = "";
      elements.pairingCode.value = "";
      clearNotice();
      syncRefreshTimer();
      window.setTimeout(() => refreshHealth({ silent: true }), 1200);
    } catch (error) {
      showNotice(pairingErrorMessage(error));
    }
  });
}

async function handleReset() {
  if (!window.confirm("Reset this Home Agent? Approved device records and private services on this computer will be removed.")) {
    return;
  }
  await withBusy(elements.resetButton, async () => {
    const result = await requestApi("/api/reset", { method: "POST", body: {} });
    state = normalizeState(result);
    reconnectOpen = false;
    connectionError = "";
    closeQrPanel();
    clearNotice();
    syncRefreshTimer();
  });
}

async function handleAddDevice(event) {
  event.preventDefault();
  const person = elements.personName.value.trim();
  const name = elements.deviceName.value.trim();
  const type = elements.deviceType.value;
  if (!person) {
    showNotice("Enter the person who will use this device.");
    return;
  }

  await withBusy(elements.deviceForm, async () => {
    try {
      const result = await requestApi("/api/devices", {
        method: "POST",
        body: { person, name, type }
      });
      state = normalizeState(result.state);
      const config = String(result.enrollment?.wireguardConfig || "");
      if (!config) {
        throw new Error("The VPS did not return a WireGuard configuration.");
      }
      window.TaterQr.render(config, elements.qrImage);
      elements.qrTitle.textContent = name || `${person}'s ${type}`;
      elements.qrToken.textContent = config;
      elements.qrPanel.hidden = false;
      elements.deviceForm.reset();
      elements.deviceType.value = "Phone";
      elements.deviceForm.hidden = true;
      clearNotice();
    } catch (error) {
      showNotice(error.message);
    }
  });
}

async function handleAddService(event) {
  event.preventDefault();
  const name = elements.serviceName.value.trim().toLowerCase();
  const host = elements.serviceHost.value.trim();
  const port = elements.servicePort.value.trim();
  const protocol = elements.serviceProtocol.value;
  const accessPort = elements.serviceAccessPort.value.trim();
  if (!name || !host || !port) {
    showNotice("Service name, local address, and local port are required.");
    return;
  }

  const body = { name, host, port, protocol };
  if (accessPort) {
    body.accessPort = accessPort;
  }
  await withBusy(elements.serviceForm, async () => {
    try {
      const result = await requestApi("/api/access-routes", { method: "POST", body });
      state = normalizeState(result);
      elements.serviceForm.reset();
      elements.serviceHost.value = "127.0.0.1";
      elements.serviceProtocol.value = "tcp";
      elements.serviceForm.hidden = true;
      clearNotice();
    } catch (error) {
      showNotice(error.message);
    }
  });
}

function applyServicePreset() {
  const preset = SERVICE_PRESETS[elements.servicePreset.value];
  if (!preset) {
    return;
  }
  elements.serviceName.value = preset.name;
  elements.serviceHost.value = preset.host;
  elements.servicePort.value = String(preset.port);
  elements.serviceProtocol.value = preset.protocol;
  elements.serviceAccessPort.value = "";
}

async function refreshHealth({ silent }) {
  if (!state.paired || refreshInFlight) {
    return;
  }
  refreshInFlight = true;
  try {
    const result = await requestApi("/api/health", { method: "POST", body: {} });
    state = normalizeState(result);
    connectionError = "";
    if (!silent) {
      clearNotice();
    }
  } catch (error) {
    connectionError = error.message || "The private tunnel check failed.";
    if (!silent) {
      showNotice(connectionError);
    }
  } finally {
    refreshInFlight = false;
    render();
  }
}

function syncRefreshTimer() {
  if (state.paired && !refreshTimer) {
    refreshTimer = window.setInterval(() => refreshHealth({ silent: true }), HEALTH_REFRESH_MS);
  } else if (!state.paired && refreshTimer) {
    window.clearInterval(refreshTimer);
    refreshTimer = null;
  }
}

function render() {
  const connection = connectionStatus();
  elements.appShell.classList.toggle("is-connected", connection.kind === "connected");
  elements.appShell.classList.toggle("needs-attention", connection.kind === "error");
  elements.statusText.textContent = connection.label;
  elements.connectionState.textContent = connection.shortLabel;
  elements.connectionState.className = `section-state ${connection.kind === "connected" ? "" : connection.kind === "error" ? "is-bad" : "is-waiting"}`.trim();

  elements.metricHome.textContent = runtimeLabel();
  elements.metricVps.textContent = state.vps || "Not connected";
  const connectedDevices = state.devices.filter(isDeviceConnected).length;
  elements.metricDevices.textContent = state.devices.length
    ? `${connectedDevices} connected / ${state.devices.length}`
    : "0 approved";
  elements.metricServices.textContent = `${Object.keys(state.accessRoutes).length} shared`;

  elements.connectionSummary.hidden = !state.paired;
  elements.connectionSettings.hidden = !state.paired;
  elements.pairForm.hidden = state.paired && !reconnectOpen;
  elements.connectAgainButton.textContent = reconnectOpen ? "Hide form" : "Connect again";
  elements.connectedVps.textContent = state.vps || "Connected VPS";
  elements.connectionDetail.textContent = connection.detail;
  if (state.vps && !elements.vpsAddress.value) {
    elements.vpsAddress.value = state.vps;
  }

  elements.addDeviceButton.disabled = connection.kind !== "connected";
  elements.addServiceButton.disabled = !state.paired;
  if (!state.paired) {
    elements.deviceForm.hidden = true;
    elements.serviceForm.hidden = true;
  }

  renderDevices();
  renderServices();
}

function connectionStatus() {
  if (!apiAvailable) {
    return {
      kind: "error",
      label: "Home Agent needs attention",
      shortLabel: "Unavailable",
      detail: connectionError || "The local Home Agent API is not available."
    };
  }
  if (state.migrationRequired) {
    return {
      kind: "error",
      label: "Reconnect required",
      shortLabel: "Upgrade needed",
      detail: "This install used the retired HTTPS path. Run the VPS update, reopen pairing, and connect once."
    };
  }
  if (!state.paired) {
    return {
      kind: "waiting",
      label: "Ready to connect",
      shortLabel: "Not connected",
      detail: "Enter the VPS URL and the one-time code shown by the installer."
    };
  }
  const runtime = state.homeAgent?.runtime || {};
  if (String(runtime.lastAction || "").includes("error")) {
    return {
      kind: "error",
      label: "WireGuard setup needs attention",
      shortLabel: "Setup issue",
      detail: runtime.message || "The Home Agent could not start its WireGuard tunnel."
    };
  }
  const health = state.vpsAgent?.health || {};
  const fresh = health.status === "ok" && isRecent(health.checkedAt, HEALTH_FRESH_MS);
  if (fresh && !connectionError) {
    return {
      kind: "connected",
      label: "Private tunnel connected",
      shortLabel: "Connected",
      detail: `Private management answered ${formatCheckTime(health.checkedAt)}.`
    };
  }
  if (connectionError) {
    return {
      kind: "error",
      label: "Private tunnel is not responding",
      shortLabel: "Not connected",
      detail: connectionError
    };
  }
  return {
    kind: "waiting",
    label: "Starting private tunnel",
    shortLabel: "Starting",
    detail: "The VPS is paired. Waiting for the WireGuard path to answer."
  };
}

function runtimeLabel() {
  const action = String(state.homeAgent?.runtime?.lastAction || "");
  if (!state.paired) {
    return "Ready";
  }
  if (action === "applied") {
    return "WireGuard active";
  }
  if (action === "rendered") {
    return "Tunnel prepared";
  }
  if (action.includes("error")) {
    return "Needs attention";
  }
  return "Starting";
}

function renderDevices() {
  elements.deviceList.replaceChildren();
  elements.emptyDevices.hidden = state.devices.length > 0;
  state.devices.forEach((device) => {
    const card = document.createElement("article");
    card.className = "item-card";
    const content = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = device.name || "Device";
    const owner = document.createElement("p");
    owner.textContent = device.person || "Tater user";
    const meta = document.createElement("div");
    meta.className = "item-meta";
    appendChip(meta, device.type || "Device");
    appendChip(meta, device.status || "Waiting", isDeviceConnected(device) ? "is-connected" : "is-waiting");
    appendChip(meta, device.lastSeen || "No handshake yet");
    const endpoint = device.wireguard?.live?.endpoint;
    if (endpoint) {
      appendChip(meta, endpoint, "is-endpoint");
    }
    const transfer = document.createElement("small");
    transfer.textContent = formatTransfer(device.wireguard?.live || {});
    transfer.hidden = !transfer.textContent;
    content.append(title, owner, meta, transfer);

    const actions = document.createElement("div");
    actions.className = "item-actions";
    const revoke = document.createElement("button");
    revoke.className = "danger-button";
    revoke.type = "button";
    revoke.textContent = "Revoke";
    revoke.addEventListener("click", () => revokeDevice(device.id, revoke));
    actions.append(revoke);
    card.append(content, actions);
    elements.deviceList.append(card);
  });
}

function renderServices() {
  elements.serviceList.replaceChildren();
  const entries = Object.entries(state.accessRoutes);
  elements.emptyServices.hidden = entries.length > 0;
  const listeners = new Map(
    (state.homeAgent?.accessForwarding?.listeners || []).map((listener) => [listener.name, listener])
  );
  const errors = state.homeAgent?.accessForwarding?.errors || {};

  entries.forEach(([name, route]) => {
    const card = document.createElement("article");
    card.className = "item-card";
    const content = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = name;
    const target = document.createElement("p");
    target.textContent = `Local target: ${route.targetHost}:${route.targetPort}`;
    const address = document.createElement("code");
    address.className = "service-address";
    address.textContent = `${route.accessAddress || state.accessAddress || "10.88.0.2"}:${route.accessPort}`;
    const meta = document.createElement("div");
    meta.className = "item-meta";
    appendChip(meta, String(route.protocol || "tcp").toUpperCase());
    appendChip(meta, listeners.has(name) ? "Listening" : "Waiting", listeners.has(name) ? "is-connected" : "is-waiting");
    const health = document.createElement("small");
    const test = serviceTests[name];
    health.className = `route-health ${test?.ok ? "is-ok" : test ? "is-bad" : ""}`.trim();
    health.textContent = errors[name]
      ? `Listener: ${errors[name]}`
      : test
        ? `${test.ok ? "Reachable" : "Needs attention"}: ${test.message}`
        : "Not tested yet";
    content.append(title, target, address, meta, health);

    const actions = document.createElement("div");
    actions.className = "item-actions";
    const copy = createButton("ghost-button", "Copy address", () => copyAddress(address.textContent));
    const testButton = createButton("secondary-button", "Test", () => testService(name, testButton));
    const remove = createButton("danger-button", "Remove", () => removeService(name, remove));
    actions.append(copy, testButton, remove);
    card.append(content, actions);
    elements.serviceList.append(card);
  });
}

async function revokeDevice(id, button) {
  await withBusy(button, async () => {
    try {
      const result = await requestApi(`/api/devices/${encodeURIComponent(id)}`, { method: "DELETE" });
      state = normalizeState(result);
      clearNotice();
    } catch (error) {
      showNotice(error.message);
    }
  });
}

async function testService(name, button) {
  await withBusy(button, async () => {
    try {
      const result = await requestApi("/api/access-routes/test", {
        method: "POST",
        body: { name }
      });
      serviceTests[name] = result.result;
      clearNotice();
    } catch (error) {
      serviceTests[name] = { ok: false, message: error.message };
      showNotice(error.message);
    }
  });
}

async function removeService(name, button) {
  await withBusy(button, async () => {
    try {
      const result = await requestApi(`/api/access-routes/${encodeURIComponent(name)}`, { method: "DELETE" });
      state = normalizeState(result);
      delete serviceTests[name];
      clearNotice();
    } catch (error) {
      showNotice(error.message);
    }
  });
}

async function copyAddress(value) {
  try {
    await navigator.clipboard.writeText(value);
    showNotice("Private service address copied.", "ok");
  } catch {
    showNotice(`Private service address: ${value}`);
  }
}

function closeQrPanel() {
  elements.qrPanel.hidden = true;
  elements.qrImage.removeAttribute("src");
  elements.qrToken.textContent = "";
}

function appendChip(container, text, className = "") {
  if (!text) {
    return;
  }
  const chip = document.createElement("span");
  chip.className = `chip ${className}`.trim();
  chip.textContent = text;
  container.append(chip);
}

function createButton(className, label, handler) {
  const button = document.createElement("button");
  button.className = className;
  button.type = "button";
  button.textContent = label;
  button.addEventListener("click", handler);
  return button;
}

function isDeviceConnected(device) {
  return device?.wireguard?.live?.connected === true;
}

function formatTransfer(live) {
  const received = Number(live.transferRxBytes || 0);
  const sent = Number(live.transferTxBytes || 0);
  if (!received && !sent) {
    return "";
  }
  return `${formatBytes(received)} in / ${formatBytes(sent)} out`;
}

function formatBytes(value) {
  if (value < 1024) {
    return `${value} B`;
  }
  if (value < 1024 * 1024) {
    return `${(value / 1024).toFixed(1)} KB`;
  }
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}

function formatCheckTime(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "recently";
  }
  return new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit" }).format(date);
}

function isRecent(value, maxAge) {
  const timestamp = new Date(value).getTime();
  return Number.isFinite(timestamp) && Date.now() - timestamp <= maxAge;
}

function normalizeState(payload) {
  const source = payload?.state || payload || {};
  return {
    ...structuredClone(defaultState),
    ...source,
    homeAgent: {
      ...defaultState.homeAgent,
      ...(source.homeAgent || {})
    },
    devices: Array.isArray(source.devices) ? source.devices : [],
    accessRoutes: source.accessRoutes && typeof source.accessRoutes === "object" ? source.accessRoutes : {}
  };
}

async function requestApi(path, options = {}) {
  const response = await fetch(path, {
    method: options.method || "GET",
    headers: options.body ? { "Content-Type": "application/json" } : {},
    body: options.body ? JSON.stringify(options.body) : undefined,
    cache: "no-store"
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `Request failed with HTTP ${response.status}`);
  }
  apiAvailable = true;
  return payload;
}

async function withBusy(control, action) {
  const buttons = control instanceof HTMLFormElement
    ? [...control.querySelectorAll("button")]
    : [control];
  const states = buttons.map((button) => [button, button.disabled]);
  buttons.forEach((button) => {
    button.disabled = true;
  });
  try {
    await action();
  } finally {
    states.forEach(([button, wasDisabled]) => {
      button.disabled = wasDisabled;
    });
    render();
  }
}

function showNotice(message, kind = "error") {
  elements.notice.textContent = message;
  elements.notice.hidden = false;
  elements.notice.style.borderLeftColor = kind === "ok" ? "var(--green)" : "var(--red)";
}

function clearNotice() {
  elements.notice.hidden = true;
  elements.notice.textContent = "";
}

function pairingErrorMessage(error) {
  const message = String(error?.message || "Could not connect to the VPS");
  const normalized = message.toLowerCase();
  if (normalized.includes("pairing mode is disabled")) {
    return "Pairing is closed on the VPS. Use Update existing install or reopen pairing, then enter the new code.";
  }
  if (normalized.includes("pairing code is not valid")) {
    return "That pairing code is not valid. Use the current code shown by the VPS installer.";
  }
  if (normalized.includes("not reachable")) {
    return `${message}. Check the DNS-only VPS hostname and HTTPS certificate.`;
  }
  return message;
}
