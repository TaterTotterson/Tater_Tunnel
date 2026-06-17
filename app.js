const STORAGE_KEY = "tater-tunnel-prototype";
const HEALTH_REFRESH_MS = 10000;
const LIVE_SNAPSHOT_STALE_MS = 120000;
const RELAY_RUNTIME_STALE_MS = 45000;
const ROUTE_PRESETS = {
  tater: {
    name: "tater",
    host: "127.0.0.1",
    port: "8501",
    path: "/",
    websocket: true,
    rootPathPrefixes: ["/api", "/static", "/v1"],
    timeoutSeconds: ""
  },
  matrix: {
    name: "matrix",
    host: "127.0.0.1",
    port: "8008",
    path: "/",
    websocket: true,
    rootPathPrefixes: ["/_matrix", "/_synapse", "/.well-known"],
    timeoutSeconds: "65"
  },
  emby: {
    name: "emby",
    host: "127.0.0.1",
    port: "8096",
    path: "/",
    websocket: true,
    rootPathPrefixes: [],
    timeoutSeconds: ""
  }
};

const defaultState = {
  paired: false,
  vps: "",
  endpoint: "",
  mode: "safe",
  lastCheck: "",
  routes: {
    taterServices: true,
    localNetwork: false
  },
  devices: []
};

let state = structuredClone(defaultState);
let apiAvailable = false;
let liveRefreshTimer = null;
let liveRefreshInFlight = false;
let pairingSettingsOpen = false;
let routeHealthResults = {};
let attentionMessage = "";

const appShell = document.querySelector(".app-shell");
const headerState = document.querySelector("#headerState");
const statusText = document.querySelector("#statusText");
const metricVps = document.querySelector("#metricVps");
const metricEndpoint = document.querySelector("#metricEndpoint");
const metricDevices = document.querySelector("#metricDevices");
const metricCheck = document.querySelector("#metricCheck");
const pairingForm = document.querySelector("#pairingForm");
const pairingState = document.querySelector("#pairingState");
const claimSummary = document.querySelector("#claimSummary");
const claimStatus = document.querySelector("#claimStatus");
const claimDetails = document.querySelector("#claimDetails");
const reclaimButton = document.querySelector("#reclaimButton");
const cancelReclaimButton = document.querySelector("#cancelReclaimButton");
const vpsAddress = document.querySelector("#vpsAddress");
const pairingCode = document.querySelector("#pairingCode");
const securityMode = document.querySelector("#securityMode");
const addDeviceButton = document.querySelector("#addDeviceButton");
const quickAddButton = document.querySelector("#quickAddButton");
const deviceForm = document.querySelector("#deviceForm");
const personName = document.querySelector("#personName");
const deviceName = document.querySelector("#deviceName");
const deviceType = document.querySelector("#deviceType");
const emptyState = document.querySelector("#emptyState");
const deviceList = document.querySelector("#deviceList");
const qrPanel = document.querySelector("#qrPanel");
const qrDeviceName = document.querySelector("#qrDeviceName");
const qrToken = document.querySelector("#qrToken");
const qrImage = document.querySelector("#qrImage");
const healthButton = document.querySelector("#healthButton");
const resetButton = document.querySelector("#resetButton");
const addRouteButton = document.querySelector("#addRouteButton");
const routeForm = document.querySelector("#routeForm");
const routePreset = document.querySelector("#routePreset");
const routeName = document.querySelector("#routeName");
const routeHost = document.querySelector("#routeHost");
const routePort = document.querySelector("#routePort");
const routePath = document.querySelector("#routePath");
const routeWebsocket = document.querySelector("#routeWebsocket");
const routeHostHeader = document.querySelector("#routeHostHeader");
const routeRootPaths = document.querySelector("#routeRootPaths");
const routeTimeout = document.querySelector("#routeTimeout");
const relayRouteList = document.querySelector("#relayRouteList");

pairingForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  const vps = vpsAddress.value.trim();
  const code = pairingCode.value.trim();

  if (!vps || !code) {
    setAttention("VPS address and pairing code required");
    return;
  }

  await withBusy(pairingForm, async () => {
    try {
      if (apiAvailable) {
        const result = await requestApi("/api/pair", {
          method: "POST",
          body: {
            vpsAddress: vps,
            pairingCode: code,
            securityMode: securityMode.value
          }
        });
        applyState(result.state);
      } else {
        applyState({
          ...state,
          paired: true,
          vps,
          endpoint: `${vps}:51888`,
          mode: securityMode.value,
          lastCheck: new Date().toISOString()
        });
        saveLocalState();
      }
    } catch (error) {
      pairingSettingsOpen = true;
      vpsAddress.value = vps;
      pairingCode.value = code;
      throw new Error(pairingErrorMessage(error));
    }

    pairingCode.value = "";
    pairingSettingsOpen = false;
  });
});

reclaimButton.addEventListener("click", () => {
  pairingSettingsOpen = true;
  render();
  vpsAddress.focus();
});

cancelReclaimButton.addEventListener("click", () => {
  pairingSettingsOpen = false;
  pairingCode.value = "";
  render();
});

addDeviceButton.addEventListener("click", showDeviceForm);
quickAddButton.addEventListener("click", showDeviceForm);

deviceForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  if (!state.paired) {
    setAttention("Pair VPS relay before adding devices");
    return;
  }

  const person = personName.value.trim() || "Tater Person";
  const type = deviceType.value;
  const name = deviceName.value.trim() || `${person}'s ${type}`;

  await withBusy(deviceForm, async () => {
    if (apiAvailable) {
      const result = await requestApi("/api/devices", {
        method: "POST",
        body: { person, name, type }
      });
      applyState(result.state);
      const device = state.devices.find((entry) => entry.id === result.enrollment.deviceId) || { name };
      showQr(device, result.enrollment);
    } else {
      const device = createLocalDevice({ person, name, type });
      applyState({
        ...state,
        devices: [device, ...state.devices],
        lastCheck: new Date().toISOString()
      });
      saveLocalState();
      showQr(device, { uri: device.token });
    }

    deviceForm.reset();
  });
});

healthButton.addEventListener("click", async () => {
  if (!state.paired) {
    setAttention("No VPS relay paired");
    return;
  }

  await withBusy(healthButton, async () => {
    await refreshHealth();
  });
});

resetButton.addEventListener("click", async () => {
  await withBusy(resetButton, async () => {
    if (apiAvailable) {
      const result = await requestApi("/api/reset", { method: "POST", body: {} });
      applyState(result.state);
    } else {
      applyState(structuredClone(defaultState));
      saveLocalState();
    }

    qrPanel.hidden = true;
    deviceForm.hidden = true;
  });
});

addRouteButton.addEventListener("click", showRouteForm);
routePreset.addEventListener("change", () => {
  applyRoutePreset(routePreset.value);
});

routeForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  if (!state.paired) {
    setAttention("Pair VPS relay before adding routes");
    return;
  }

  const name = routeName.value.trim().toLowerCase();
  const host = routeHost.value.trim() || "127.0.0.1";
  const port = routePort.value.trim();
  const path = routePath.value.trim();
  const websocket = routeWebsocket.checked;
  const hostHeader = routeHostHeader.value.trim();
  const rootPathPrefixes = parseRootPathPrefixes(routeRootPaths.value);
  const timeoutSeconds = parseRouteTimeout(routeTimeout.value);

  if (timeoutSeconds === null) {
    setAttention("Route timeout must be a number of seconds");
    return;
  }

  if (!name || !port) {
    setAttention("Route name and port required");
    return;
  }

  await withBusy(routeForm, async () => {
    const routePayload = { name, host, port, path, websocket, hostHeader };
    if (rootPathPrefixes.length) {
      routePayload.rootPathPrefixes = rootPathPrefixes;
    }
    if (timeoutSeconds) {
      routePayload.timeoutSeconds = timeoutSeconds;
    }
    if (apiAvailable) {
      const result = await requestApi("/api/relay-routes", {
        method: "POST",
        body: routePayload
      });
      applyState(result.state);
    } else {
      const routeSuffix = normalizeRoutePath(path);
      const nextRoutes = { ...getRelayRoutes(), [name]: `http://${host}:${port}${routeSuffix}` };
      const nextSettings = {
        ...getRelayRouteSettings(),
        [name]: {
          websocket,
          ...(hostHeader ? { hostHeader } : {}),
          ...(rootPathPrefixes.length ? { rootPathPrefixes } : {}),
          ...(timeoutSeconds ? { timeoutSeconds } : {})
        }
      };
      applyState(withRelayRoutes(state, nextRoutes, nextSettings));
      saveLocalState();
    }

    routeForm.reset();
    routePreset.value = "";
    routeHost.value = "127.0.0.1";
    routePath.value = "/";
    routeWebsocket.checked = true;
    routeRootPaths.value = "";
    routeTimeout.value = "";
    routeForm.hidden = true;
  });
});

boot();

async function boot() {
  state = await loadState();
  render();
  syncLiveRefresh();
  if (apiAvailable && state.paired) {
    refreshHealth({ silent: true });
  }
}

function showDeviceForm() {
  if (!state.paired) {
    setAttention("Pair VPS relay before adding devices");
    return;
  }

  deviceForm.hidden = false;
  personName.focus();
}

function showRouteForm() {
  if (!state.paired) {
    setAttention("Pair VPS relay before adding routes");
    return;
  }

  routeForm.hidden = false;
  if (!routeHost.value) {
    routeHost.value = "127.0.0.1";
  }
  if (!routePath.value) {
    routePath.value = "/";
  }
  routeName.focus();
}

function applyRoutePreset(presetName) {
  const preset = ROUTE_PRESETS[presetName];
  if (!preset) {
    return;
  }

  routeName.value = preset.name;
  routeHost.value = preset.host;
  routePort.value = preset.port;
  routePath.value = preset.path;
  routeWebsocket.checked = preset.websocket !== false;
  routeHostHeader.value = preset.hostHeader || "";
  routeRootPaths.value = (preset.rootPathPrefixes || []).join(", ");
  routeTimeout.value = preset.timeoutSeconds ? String(preset.timeoutSeconds) : "";
}

async function revokeDevice(id) {
  const device = state.devices.find((entry) => entry.id === id);

  if (apiAvailable) {
    const result = await requestApi(`/api/devices/${encodeURIComponent(id)}`, { method: "DELETE" });
    applyState(result.state);
  } else {
    applyState({
      ...state,
      devices: state.devices.filter((entry) => entry.id !== id),
      lastCheck: new Date().toISOString()
    });
    saveLocalState();
  }

  if (device && qrDeviceName.textContent === device.name) {
    qrPanel.hidden = true;
  }
}

async function removeRelayRoute(name) {
  if (apiAvailable) {
    const result = await requestApi(`/api/relay-routes/${encodeURIComponent(name)}`, { method: "DELETE" });
    applyState(result.state);
  } else {
    const routes = getRelayRoutes();
    const routeSettings = getRelayRouteSettings();
    delete routes[name];
    delete routeSettings[name];
    applyState(withRelayRoutes(state, routes, routeSettings));
    saveLocalState();
  }
  delete routeHealthResults[name];
}

async function testRelayRoute(name) {
  if (!state.paired) {
    throw new Error("Pair VPS relay before testing routes");
  }

  if (apiAvailable) {
    const result = await requestApi("/api/relay-routes/test", {
      method: "POST",
      body: { name }
    });
    return result.result;
  }

  return {
    ok: true,
    status: null,
    message: "Local preview cannot test routes without the Home Agent API.",
    checkedAt: new Date().toISOString()
  };
}

function showQr(device, enrollment) {
  qrDeviceName.textContent = device.name;
  const qrText = enrollment?.wireguardConfig || enrollment?.uri || device.token || "tt://pending";
  const qrReady = renderQr(qrText);
  if (qrReady) {
    qrToken.textContent = enrollment?.wireguardConfig ? "Scan with the WireGuard app" : qrText;
  }
  qrPanel.hidden = false;
}

function applyState(nextState) {
  attentionMessage = "";
  state = normalizeState(nextState);
  render();
  syncLiveRefresh();
}

function render() {
  appShell.classList.remove("is-connected", "needs-attention");
  const connectedDevices = state.devices.filter(isDeviceConnected).length;
  const hasLiveSnapshot = hasLiveDeviceSnapshot();
  const relayStatus = claimConnectionStatus();

  if (state.paired) {
    if (relayStatus.connected) {
      appShell.classList.add("is-connected");
    } else {
      appShell.classList.add("needs-attention");
    }
    setHeaderState(relayStatus.connected ? "Connected" : "Needs Attention");
    statusText.textContent = relayStatus.connected
      ? hasLiveSnapshot && connectedDevices > 0
        ? `${connectedDevices} VPN device live`
        : "Home Relay connected"
      : "Home Relay not connected";
    pairingState.textContent = relayStatus.connected ? "Connected" : "Not Connected";
    pairingState.className = `section-state ${relayStatus.connected ? "is-ok" : "is-bad"}`;
  } else {
    setHeaderState("Waiting for VPS");
    statusText.textContent = apiAvailable ? "Home Relay ready" : "Waiting for VPS pairing";
    pairingState.textContent = "Open";
    pairingState.className = "section-state";
    pairingSettingsOpen = true;
  }

  if (attentionMessage) {
    appShell.classList.remove("is-connected");
    appShell.classList.add("needs-attention");
    setHeaderState("Needs Attention");
    statusText.textContent = attentionMessage;
  }

  claimSummary.hidden = !state.paired;
  claimStatus.textContent = state.paired
    ? `Claimed: ${relayStatus.connected ? "Connected" : "Not connected"}`
    : "Not claimed";
  claimDetails.textContent = relayStatus.detail;
  pairingForm.hidden = state.paired && !pairingSettingsOpen;
  cancelReclaimButton.hidden = !state.paired || !pairingSettingsOpen;

  metricVps.textContent = state.vps || "Not paired";
  metricEndpoint.textContent = state.paired ? state.endpoint || `${state.vps}:51888` : "51888/udp";
  metricDevices.textContent =
    hasLiveSnapshot && state.devices.length > 0
      ? `${connectedDevices} connected / ${state.devices.length}`
      : `${state.devices.length} approved`;
  metricCheck.textContent = formatCheckTime(state.lastCheck);
  if (state.paired) {
    vpsAddress.value = state.vps;
    securityMode.value = state.mode;
  } else if (!vpsAddress.value && state.vps) {
    vpsAddress.value = state.vps;
  }

  addDeviceButton.disabled = !state.paired;
  quickAddButton.disabled = !state.paired;
  addRouteButton.disabled = !state.paired;
  if (!state.paired) {
    routeForm.hidden = true;
  }

  renderRelayRoutes();

  emptyState.hidden = state.devices.length > 0;
  deviceList.innerHTML = "";

  state.devices.forEach((device) => {
    const card = document.createElement("article");
    card.className = "device-card";
    card.innerHTML = `
      <div>
        <h3></h3>
        <p></p>
        <div class="device-meta"></div>
        <p class="device-live"></p>
      </div>
      <button class="danger-button" type="button">Revoke</button>
    `;

    card.querySelector("h3").textContent = device.name;
    card.querySelector("p").textContent = device.person;
    const live = device.wireguard?.live || {};
    const meta = card.querySelector(".device-meta");
    appendChip(meta, device.type);
    appendChip(meta, deviceStatusLabel(device), statusChipClass(device));
    appendChip(meta, deviceLastSeenLabel(device));
    if (live.endpoint) {
      appendChip(meta, live.endpoint, "is-endpoint");
    }

    const liveLine = card.querySelector(".device-live");
    const transfer = formatTransfer(live);
    liveLine.textContent = isLiveDeviceSnapshotStale() && transfer ? `Last known: ${transfer}` : transfer;
    liveLine.hidden = !transfer;

    card.querySelector("button").addEventListener("click", async () => {
      try {
        await revokeDevice(device.id);
      } catch (error) {
        setAttention(error.message);
      }
    });
    deviceList.append(card);
  });
}

function claimConnectionStatus() {
  if (!state.paired) {
    return {
      connected: false,
      detail: "Pair a VPS relay to start."
    };
  }

  const relay = state.homeAgent?.relay || {};
  const runtime = state.homeAgent?.runtime || {};
  const health = state.vpsAgent?.health || {};
  const message = String(runtime.message || "");
  const action = String(runtime.lastAction || "");
  const healthStatus = String(health.status || "").toLowerCase();
  const freshHealthOk = healthStatus === "ok" && isRecentTimestamp(health.checkedAt, LIVE_SNAPSHOT_STALE_MS);
  const freshRuntimeOk =
    ["polling", "relayed"].includes(action) && isRecentTimestamp(runtime.lastAppliedAt, RELAY_RUNTIME_STALE_MS);
  const freshDeviceConnected = state.devices.some(isDeviceConnected);
  const hasError =
    action === "relay-error" ||
    /failed|not reachable|error/i.test(message) ||
    (healthStatus && healthStatus !== "ok");

  if (hasError) {
    return {
      connected: false,
      detail: message
        ? `${state.vps || "VPS"} is claimed, but the relay check failed: ${message}`
        : `VPS check is ${health.status || "not connected"}.`
    };
  }

  const connected =
    freshRuntimeOk ||
    freshHealthOk ||
    freshDeviceConnected ||
    (relay.status === "connected" && action === "paired" && !runtime.lastAppliedAt);

  return {
    connected,
    detail: connected
      ? `${state.vps || "VPS"} claimed. Last check ${formatCheckTime(state.lastCheck)}.`
      : `${state.vps || "VPS"} is claimed, waiting for a fresh relay check.`
  };
}

function renderRelayRoutes() {
  const routes = getRelayRoutes();
  const settings = getRelayRouteSettings();
  const entries = Object.entries(routes);
  relayRouteList.innerHTML = "";

  entries.forEach(([name, target]) => {
    const routeSettings = settings[name] || {};
    const health = routeHealthResults[name];
    const card = document.createElement("article");
    card.className = "relay-route-card";
    card.innerHTML = `
      <div>
        <strong></strong>
        <div class="route-use">
          <span>Use</span>
          <code></code>
        </div>
        <small class="route-path"></small>
        <small class="route-target"></small>
        <small class="route-options"></small>
        <small class="route-health"></small>
      </div>
      <div class="route-actions">
        <button class="secondary-button route-test-button" type="button">Test</button>
        <button class="danger-button route-remove-button" type="button">Remove</button>
      </div>
    `;

    card.querySelector("strong").textContent = name;
    card.querySelector("code").textContent = routeAccessUrl(name);
    card.querySelector(".route-path").textContent = `Relay path: ${routeRelayPath(name)}`;
    card.querySelector(".route-target").textContent = `Local target: ${target}`;
    const options = [];
    options.push(routeSettings.websocket === false ? "WebSockets off" : "WebSockets on");
    if (routeSettings.hostHeader) {
      options.push(`Host header: ${routeSettings.hostHeader}`);
    }
    if (routeSettings.rootPathPrefixes?.length) {
      options.push(`Root paths: ${routeSettings.rootPathPrefixes.join(", ")}`);
    }
    if (routeSettings.timeoutSeconds) {
      options.push(`Timeout: ${routeSettings.timeoutSeconds}s`);
    }
    card.querySelector(".route-options").textContent = options.join(" · ");
    const healthLine = card.querySelector(".route-health");
    healthLine.textContent = routeHealthLabel(health);
    healthLine.className = `route-health ${health?.ok ? "is-ok" : health ? "is-bad" : ""}`.trim();

    const testButton = card.querySelector(".route-test-button");
    testButton.addEventListener("click", async () => {
      try {
        testButton.disabled = true;
        routeHealthResults[name] = {
          ok: false,
          status: null,
          message: "Testing...",
          checkedAt: new Date().toISOString()
        };
        renderRelayRoutes();
        routeHealthResults[name] = await testRelayRoute(name);
      } catch (error) {
        routeHealthResults[name] = {
          ok: false,
          status: null,
          message: error.message,
          checkedAt: new Date().toISOString()
        };
        setAttention(error.message);
      } finally {
        renderRelayRoutes();
      }
    });

    const removeButton = card.querySelector(".route-remove-button");
    removeButton.hidden = name === "tunnel";
    removeButton.addEventListener("click", async () => {
      try {
        await removeRelayRoute(name);
      } catch (error) {
        setAttention(error.message);
      }
    });
    relayRouteList.append(card);
  });
}

function routeHealthLabel(health) {
  if (!health) {
    return "Not tested yet";
  }

  const prefix = health.ok ? "Reachable" : "Needs attention";
  const status = health.status ? `HTTP ${health.status}` : "No HTTP status";
  return `${prefix}: ${status}${health.message ? ` · ${health.message}` : ""}`;
}

async function refreshHealth({ silent = false } = {}) {
  if (liveRefreshInFlight) {
    return;
  }

  liveRefreshInFlight = true;
  try {
    if (apiAvailable) {
      const result = await requestApi("/api/health", { method: "POST", body: {} });
      applyState(result.state);
    } else {
      applyState({ ...state, lastCheck: new Date().toISOString() });
      saveLocalState();
    }
  } catch (error) {
    if (apiAvailable && state.paired && isUnpairedApiError(error)) {
      try {
        const result = await requestApi("/api/state");
        applyState(result.state || result);
        pairingSettingsOpen = true;
      } catch {
        applyState({
          ...structuredClone(defaultState),
          lastCheck: new Date().toISOString()
        });
        pairingSettingsOpen = true;
      }
      if (!silent) {
        setAttention("Pair VPS relay to continue");
      }
      return;
    }

    if (apiAvailable && state.paired) {
      applyState({
        ...state,
        lastCheck: new Date().toISOString(),
        homeAgent: {
          ...(state.homeAgent || {}),
          runtime: {
            ...(state.homeAgent?.runtime || {}),
            backend: "relay",
            lastAction: "health-error",
            lastAppliedAt: new Date().toISOString(),
            message: error.message || "VPS health check failed",
            transport: "tls-reverse-tunnel"
          }
        }
      });
    }
    if (!silent) {
      throw error;
    }
  } finally {
    liveRefreshInFlight = false;
  }
}

function isUnpairedApiError(error) {
  const message = String(error?.message || "").toLowerCase();
  return message.includes("no vps is paired") || message.includes("vps management url is not available");
}

function syncLiveRefresh() {
  const shouldRefresh = apiAvailable && state.paired;
  if (shouldRefresh && !liveRefreshTimer) {
    liveRefreshTimer = window.setInterval(() => {
      refreshHealth({ silent: true });
    }, HEALTH_REFRESH_MS);
  }
  if (!shouldRefresh && liveRefreshTimer) {
    window.clearInterval(liveRefreshTimer);
    liveRefreshTimer = null;
  }
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

function statusChipClass(device) {
  if (isLiveDeviceSnapshotStale() && device?.wireguard?.live?.connected === true) {
    return "is-waiting";
  }

  if (isDeviceConnected(device)) {
    return "is-connected";
  }

  const status = String(device.status || "").toLowerCase();
  if (status === "waiting") {
    return "is-waiting";
  }
  if (status === "revoked" || status === "offline") {
    return "is-offline";
  }
  return "";
}

function isDeviceConnected(device) {
  if (hasLiveDeviceSnapshot()) {
    return hasFreshLiveDeviceSnapshot() && device?.wireguard?.live?.connected === true;
  }

  return device?.wireguard?.live?.connected === true || String(device?.status || "").toLowerCase() === "connected";
}

function hasLiveDeviceSnapshot() {
  return Array.isArray(state.vpsAgent?.wireguardRuntime?.livePeers);
}

function hasFreshLiveDeviceSnapshot() {
  return hasLiveDeviceSnapshot() && isRecentTimestamp(liveDeviceSnapshotAt(), LIVE_SNAPSHOT_STALE_MS);
}

function isLiveDeviceSnapshotStale() {
  return hasLiveDeviceSnapshot() && !hasFreshLiveDeviceSnapshot();
}

function liveDeviceSnapshotAt() {
  return state.vpsAgent?.wireguardRuntime?.livePeerSnapshotAt || state.vpsAgent?.health?.checkedAt || "";
}

function deviceStatusLabel(device) {
  if (isLiveDeviceSnapshotStale() && device?.wireguard?.live?.connected === true) {
    return "Last known connected";
  }

  return device.status;
}

function deviceLastSeenLabel(device) {
  if (isLiveDeviceSnapshotStale() && device?.wireguard?.live?.connected === true) {
    return `Snapshot ${formatCheckTime(liveDeviceSnapshotAt())}`;
  }

  return device.lastSeen;
}

function isRecentTimestamp(value, maxAgeMs) {
  if (!value) {
    return false;
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return false;
  }

  return Date.now() - date.getTime() <= maxAgeMs;
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

async function withBusy(control, action) {
  const buttons = [...(control instanceof HTMLFormElement ? control.querySelectorAll("button") : [control])];
  const disabledStates = buttons.map((button) => [button, button.disabled]);

  buttons.forEach((button) => {
    button.disabled = true;
  });

  try {
    await action();
  } catch (error) {
    setAttention(error.message || "Tater Tunnel needs attention");
  } finally {
    disabledStates.forEach(([button, wasDisabled]) => {
      button.disabled = wasDisabled;
    });
    render();
  }
}

async function loadState() {
  if (canUseApi()) {
    try {
      const result = await requestApi("/api/state");
      apiAvailable = true;
      clearLocalState();
      return normalizeState(result);
    } catch {
      apiAvailable = false;
    }
  }

  return loadLocalState();
}

async function requestApi(path, options = {}) {
  const response = await fetch(apiUrl(path), {
    method: options.method || "GET",
    headers: {
      "Content-Type": "application/json"
    },
    body: options.body ? JSON.stringify(options.body) : undefined
  });
  const payload = await response.json().catch(() => ({}));

  if (!response.ok) {
    throw new Error(payload.error || "Home Relay request failed");
  }

  apiAvailable = true;
  return payload;
}

function canUseApi() {
  return window.location.protocol === "http:" || window.location.protocol === "https:";
}

function apiUrl(path) {
  if (path.startsWith("/relay/") || path === "/relay") {
    return path;
  }

  const relayPrefix = relayBasePath();
  if (!relayPrefix) {
    return path;
  }

  return `${relayPrefix}${path}`;
}

function relayBasePath() {
  const parts = window.location.pathname.split("/").filter(Boolean);
  if (parts[0] !== "relay") {
    return "";
  }

  if (parts.length > 1 && parts[1] !== "api") {
    return `/relay/${parts[1]}`;
  }

  return "/relay";
}

function normalizeRoutePath(path) {
  const value = (path || "").trim();
  if (!value || value === "/") {
    return "";
  }

  const normalized = value.startsWith("/") ? value : `/${value}`;
  return normalized.replace(/\/+$/, "");
}

function parseRootPathPrefixes(value) {
  return [...new Set(String(value || "")
    .split(/[,\s]+/)
    .map((item) => item.trim())
    .filter(Boolean)
    .map((item) => item.startsWith("/") ? item : `/${item}`)
    .map((item) => item.replace(/\/+$/, ""))
    .filter((item) => item && item !== "/"))];
}

function parseRouteTimeout(value) {
  const cleaned = String(value || "").trim();
  if (!cleaned) {
    return 0;
  }

  return /^\d+$/.test(cleaned) ? Number.parseInt(cleaned, 10) : null;
}

function routeRelayPath(name) {
  return name === "tunnel" ? "/relay/" : `/relay/${name}/`;
}

function routeAccessUrl(name) {
  return `${relayAccessBaseUrl()}${routeRelayPath(name)}`;
}

function relayAccessBaseUrl() {
  const wireguardHost = String(state.vpsAgent?.wireguard?.address || "").split("/")[0];
  if (wireguardHost) {
    return `http://${wireguardHost}:${relayAccessPort()}`;
  }

  const managementUrl = String(state.vpsAgent?.managementUrl || "");
  try {
    const url = new URL(managementUrl);
    return `${url.protocol}//${url.host}`;
  } catch {
    if (state.vps) {
      return `http://${state.vps}:${relayAccessPort()}`;
    }
    return window.location.origin || `http://10.88.0.1:${relayAccessPort()}`;
  }
}

function relayAccessPort() {
  const managementUrl = String(state.vpsAgent?.managementUrl || "");
  try {
    const url = new URL(managementUrl);
    return url.port || "4174";
  } catch {
    return "4174";
  }
}

function setAttention(message) {
  attentionMessage = message;
  appShell.classList.remove("is-connected");
  appShell.classList.add("needs-attention");
  setHeaderState("Needs Attention");
  statusText.textContent = message;
}

function pairingErrorMessage(error) {
  const message = String(error?.message || "Could not pair with the VPS");
  const normalized = message.toLowerCase();

  if (normalized.includes("pairing mode is disabled")) {
    return "VPS pairing mode is disabled. Reopen pairing on the VPS with a fresh code, then try Pair again.";
  }
  if (normalized.includes("pairing code is not valid")) {
    return "Pairing code is not valid. Check the code shown by the VPS Agent and try again.";
  }
  if (normalized.includes("vps agent is not reachable")) {
    return `${message}. Check the VPS IP/domain, port 4174, and firewall.`;
  }

  return message;
}

function setHeaderState(message) {
  if (headerState) {
    headerState.textContent = message;
  }
}

function createLocalDevice({ person, name, type }) {
  return {
    id: crypto.randomUUID(),
    person,
    name,
    type,
    status: "Approved",
    lastSeen: "Just now",
    token: createToken(name)
  };
}

function createToken(name) {
  const slug = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "")
    .slice(0, 28);
  const suffix = Math.random().toString(16).slice(2, 10);

  return `tt://${slug || "device"}-${suffix}`;
}

function formatCheckTime(value) {
  if (!value) {
    return "Never";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return new Intl.DateTimeFormat([], {
    hour: "numeric",
    minute: "2-digit"
  }).format(date);
}

function normalizeState(payload) {
  const source = payload?.state || payload || {};
  const merged = {
    ...structuredClone(defaultState),
    ...source,
    routes: {
      ...defaultState.routes,
      ...(source.routes || {})
    },
    devices: Array.isArray(source.devices) ? source.devices : []
  };

  return merged;
}

function getRelayRoutes() {
  return {
    ...(state.homeAgent?.relay?.routes || {})
  };
}

function getRelayRouteSettings() {
  return {
    ...(state.homeAgent?.relay?.routeSettings || {})
  };
}

function withRelayRoutes(sourceState, routes, routeSettings = getRelayRouteSettings()) {
  return {
    ...sourceState,
    homeAgent: {
      ...(sourceState.homeAgent || {}),
      relay: {
        ...(sourceState.homeAgent?.relay || {}),
        routes,
        routeSettings
      }
    }
  };
}

function loadLocalState() {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    return saved ? normalizeState(JSON.parse(saved)) : structuredClone(defaultState);
  } catch {
    return structuredClone(defaultState);
  }
}

function saveLocalState() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

function clearLocalState() {
  try {
    localStorage.removeItem(STORAGE_KEY);
  } catch {
    // Browser-local fallback state is optional when the Home Agent API is available.
  }
}

function renderQr(value) {
  try {
    const svg = createQrSvg(value);
    qrImage.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
    return true;
  } catch (error) {
    qrImage.removeAttribute("src");
    qrToken.textContent = error.message || "QR could not be created";
    return false;
  }
}

function createQrSvg(value) {
  const matrix = createQrMatrix(value);
  const quiet = 4;
  const imageSize = matrix.length + quiet * 2;
  let path = "";

  matrix.forEach((row, rowIndex) => {
    row.forEach((dark, columnIndex) => {
      if (dark) {
        path += `M${columnIndex + quiet},${rowIndex + quiet}h1v1h-1z`;
      }
    });
  });

  return [
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${imageSize} ${imageSize}" shape-rendering="crispEdges">`,
    `<rect width="${imageSize}" height="${imageSize}" fill="#fff6e6"/>`,
    `<path fill="#100f0e" d="${path}"/>`,
    "</svg>"
  ].join("");
}

function createQrMatrix(value) {
  const version = 10;
  const size = 17 + version * 4;
  const dataBlockLengths = [68, 68, 69, 69];
  const eccLength = 18;
  const dataCodewords = 274;
  const maxByteLength = 271;
  const bytes = [...new TextEncoder().encode(value)];

  if (bytes.length > maxByteLength) {
    throw new Error("WireGuard config is too long for this QR");
  }

  const bitBuffer = [];
  appendBits(bitBuffer, 0b0100, 4);
  appendBits(bitBuffer, bytes.length, 16);
  bytes.forEach((byte) => appendBits(bitBuffer, byte, 8));

  const maxBits = dataCodewords * 8;
  appendBits(bitBuffer, 0, Math.min(4, maxBits - bitBuffer.length));
  while (bitBuffer.length % 8 !== 0) {
    bitBuffer.push(0);
  }

  const codewords = [];
  for (let index = 0; index < bitBuffer.length; index += 8) {
    codewords.push(bitsToByte(bitBuffer.slice(index, index + 8)));
  }

  for (let pad = 0xec; codewords.length < dataCodewords; pad = pad === 0xec ? 0x11 : 0xec) {
    codewords.push(pad);
  }

  const blocks = [];
  let cursor = 0;
  dataBlockLengths.forEach((length) => {
    const data = codewords.slice(cursor, cursor + length);
    blocks.push({
      data,
      ecc: reedSolomonRemainder(data, eccLength)
    });
    cursor += length;
  });

  const finalCodewords = [];
  const longestDataBlock = Math.max(...dataBlockLengths);
  for (let index = 0; index < longestDataBlock; index += 1) {
    blocks.forEach((block) => {
      if (index < block.data.length) {
        finalCodewords.push(block.data[index]);
      }
    });
  }
  for (let index = 0; index < eccLength; index += 1) {
    blocks.forEach((block) => {
      finalCodewords.push(block.ecc[index]);
    });
  }

  const matrix = Array.from({ length: size }, () => Array(size).fill(false));
  const reserved = Array.from({ length: size }, () => Array(size).fill(false));
  const setFunction = (row, column, dark) => {
    if (row < 0 || row >= size || column < 0 || column >= size) {
      return;
    }
    matrix[row][column] = dark;
    reserved[row][column] = true;
  };

  drawFinder(matrix, reserved, 0, 0);
  drawFinder(matrix, reserved, 0, size - 7);
  drawFinder(matrix, reserved, size - 7, 0);

  for (let index = 8; index < size - 8; index += 1) {
    const dark = index % 2 === 0;
    setFunction(6, index, dark);
    setFunction(index, 6, dark);
  }

  [6, 28, 50].forEach((row) => {
    [6, 28, 50].forEach((column) => {
      const overlapsFinder =
        (row < 9 && column < 9) ||
        (row < 9 && column > size - 10) ||
        (row > size - 10 && column < 9);
      if (!overlapsFinder) {
        drawAlignment(matrix, reserved, row, column);
      }
    });
  });

  reserveFormatAndVersion(setFunction, size, version);
  placeData(matrix, reserved, finalCodewords);
  drawFormatBits(setFunction, size, 0);
  drawVersionBits(setFunction, size, version);

  return matrix;
}

function appendBits(buffer, value, length) {
  for (let bit = length - 1; bit >= 0; bit -= 1) {
    buffer.push((value >>> bit) & 1);
  }
}

function bitsToByte(bits) {
  return bits.reduce((byte, bit) => (byte << 1) | bit, 0);
}

function drawFinder(matrix, reserved, row, column) {
  const setFunction = (targetRow, targetColumn, dark) => {
    if (targetRow < 0 || targetRow >= matrix.length || targetColumn < 0 || targetColumn >= matrix.length) {
      return;
    }
    matrix[targetRow][targetColumn] = dark;
    reserved[targetRow][targetColumn] = true;
  };

  for (let offsetRow = -1; offsetRow <= 7; offsetRow += 1) {
    for (let offsetColumn = -1; offsetColumn <= 7; offsetColumn += 1) {
      const inPattern = offsetRow >= 0 && offsetRow <= 6 && offsetColumn >= 0 && offsetColumn <= 6;
      const dark =
        inPattern &&
        (offsetRow === 0 ||
          offsetRow === 6 ||
          offsetColumn === 0 ||
          offsetColumn === 6 ||
          (offsetRow >= 2 && offsetRow <= 4 && offsetColumn >= 2 && offsetColumn <= 4));
      setFunction(row + offsetRow, column + offsetColumn, dark);
    }
  }
}

function drawAlignment(matrix, reserved, row, column) {
  for (let offsetRow = -2; offsetRow <= 2; offsetRow += 1) {
    for (let offsetColumn = -2; offsetColumn <= 2; offsetColumn += 1) {
      const distance = Math.max(Math.abs(offsetRow), Math.abs(offsetColumn));
      const targetRow = row + offsetRow;
      const targetColumn = column + offsetColumn;
      matrix[targetRow][targetColumn] = distance !== 1;
      reserved[targetRow][targetColumn] = true;
    }
  }
}

function reserveFormatAndVersion(setFunction, size, version) {
  for (let index = 0; index < 9; index += 1) {
    if (index !== 6) {
      setFunction(8, index, false);
      setFunction(index, 8, false);
    }
  }
  for (let index = 0; index < 8; index += 1) {
    setFunction(8, size - 1 - index, false);
    setFunction(size - 1 - index, 8, false);
  }
  setFunction(size - 8, 8, true);

  if (version >= 7) {
    for (let row = 0; row < 6; row += 1) {
      for (let column = 0; column < 3; column += 1) {
        setFunction(row, size - 11 + column, false);
        setFunction(size - 11 + column, row, false);
      }
    }
  }
}

function placeData(matrix, reserved, codewords) {
  const bits = [];
  codewords.forEach((codeword) => appendBits(bits, codeword, 8));

  let bitIndex = 0;
  let upward = true;
  for (let right = matrix.length - 1; right >= 1; right -= 2) {
    if (right === 6) {
      right -= 1;
    }

    for (let vertical = 0; vertical < matrix.length; vertical += 1) {
      const row = upward ? matrix.length - 1 - vertical : vertical;
      for (let offset = 0; offset < 2; offset += 1) {
        const column = right - offset;
        if (reserved[row][column]) {
          continue;
        }

        const dataBit = bitIndex < bits.length ? bits[bitIndex] === 1 : false;
        const mask = (row + column) % 2 === 0;
        matrix[row][column] = dataBit !== mask;
        bitIndex += 1;
      }
    }

    upward = !upward;
  }
}

function drawFormatBits(setFunction, size, mask) {
  const errorCorrectionLevel = 1;
  const data = (errorCorrectionLevel << 3) | mask;
  let remainder = data << 10;
  for (let bit = 14; bit >= 10; bit -= 1) {
    if (((remainder >>> bit) & 1) !== 0) {
      remainder ^= 0x537 << (bit - 10);
    }
  }
  const bits = ((data << 10) | remainder) ^ 0x5412;
  const getBit = (index) => ((bits >>> index) & 1) !== 0;

  for (let index = 0; index <= 5; index += 1) {
    setFunction(index, 8, getBit(index));
  }
  setFunction(7, 8, getBit(6));
  setFunction(8, 8, getBit(7));
  setFunction(8, 7, getBit(8));
  for (let index = 9; index < 15; index += 1) {
    setFunction(8, 14 - index, getBit(index));
  }

  for (let index = 0; index < 8; index += 1) {
    setFunction(8, size - 1 - index, getBit(index));
  }
  for (let index = 8; index < 15; index += 1) {
    setFunction(size - 15 + index, 8, getBit(index));
  }
  setFunction(size - 8, 8, true);
}

function drawVersionBits(setFunction, size, version) {
  let remainder = version;
  for (let index = 0; index < 12; index += 1) {
    remainder = (remainder << 1) ^ (((remainder >>> 11) & 1) * 0x1f25);
  }
  const bits = (version << 12) | remainder;
  const getBit = (index) => ((bits >>> index) & 1) !== 0;

  for (let index = 0; index < 18; index += 1) {
    const a = size - 11 + (index % 3);
    const b = Math.floor(index / 3);
    const bit = getBit(index);
    setFunction(b, a, bit);
    setFunction(a, b, bit);
  }
}

const QR_EXP = [];
const QR_LOG = [];
for (let value = 1, exponent = 0; exponent < 255; exponent += 1) {
  QR_EXP[exponent] = value;
  QR_LOG[value] = exponent;
  value <<= 1;
  if (value & 0x100) {
    value ^= 0x11d;
  }
}
for (let exponent = 255; exponent < 512; exponent += 1) {
  QR_EXP[exponent] = QR_EXP[exponent - 255];
}

function gfMultiply(left, right) {
  if (left === 0 || right === 0) {
    return 0;
  }
  return QR_EXP[QR_LOG[left] + QR_LOG[right]];
}

function reedSolomonRemainder(data, degree) {
  const generator = reedSolomonGenerator(degree);
  const result = [...data, ...Array(degree).fill(0)];

  for (let index = 0; index < data.length; index += 1) {
    const factor = result[index];
    if (factor === 0) {
      continue;
    }

    generator.forEach((coefficient, generatorIndex) => {
      result[index + generatorIndex] ^= gfMultiply(coefficient, factor);
    });
  }

  return result.slice(data.length);
}

function reedSolomonGenerator(degree) {
  let result = [1];
  for (let index = 0; index < degree; index += 1) {
    result = polynomialMultiply(result, [1, QR_EXP[index]]);
  }
  return result;
}

function polynomialMultiply(left, right) {
  const result = Array(left.length + right.length - 1).fill(0);
  left.forEach((leftCoefficient, leftIndex) => {
    right.forEach((rightCoefficient, rightIndex) => {
      result[leftIndex + rightIndex] ^= gfMultiply(leftCoefficient, rightCoefficient);
    });
  });
  return result;
}
