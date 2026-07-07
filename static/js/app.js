// app.js — the entry module: ensures this device is paired, loads units,
// wires each card's control callback to the API, and runs the poll loop.
// It's the only module that combines transport (api.js), pairing
// (enroll.js), and rendering (unit-card.js).

import { apiFetch, clearDeviceToken } from "./api.js";
import { buildPanel, render, setError, setName } from "./unit-card.js";
import { enroll } from "./enroll.js";
import {
  addUnitDialog, renameDialog, confirmDialog,
  apiAddUnit, apiRenameUnit, apiDeleteUnit,
} from "./manage.js";
import { tempUnit, toggleTempUnit } from "./display.js";
import { initPalette, buildPalettePicker } from "./theme.js";

const POLL_INTERVAL_MS = 5000;
const panels = {}; // unit id -> panel object
let reauthing = false;

// A 401 on a normally-authorized request means the device token is
// missing/expired. Clear it and re-run pairing; because apiFetch reads
// the token from localStorage on every call, the next poll tick just
// works once a new token is stored. Guarded so concurrent 401s (one per
// panel) trigger a single pairing flow.
async function reauth(){
  if(reauthing) return;
  reauthing = true;
  clearDeviceToken();
  try{ await enroll(); }
  finally{ reauthing = false; }
}

async function control(p, body){
  if(p.pending) return;
  p.pending = true;
  try{
    const res = await apiFetch(`/api/units/${p.id}/control`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify(body)
    });
    if(res.status === 401){ setError(p, "session expired — re-pairing…"); reauth(); return; }
    if(!res.ok) throw new Error(await res.text());
    render(p, await res.json());
    setError(p, null);
  }catch(e){
    setError(p, "control failed — " + e.message);
  }finally{
    p.pending = false;
  }
}

// Poll every unit in ONE request via the batch endpoint (Breeze Core >= 2.4.0),
// fanned out server-side. Falls back to per-panel polling on an older server
// (batch route missing -> 404/405).
async function fetchAllStates(){
  let res;
  try{
    res = await apiFetch("/api/units/state");
  }catch(e){
    document.getElementById("globalStatus").textContent = "can't reach server — " + e.message;
    return;
  }
  if(res.status === 401){ reauth(); return; }
  if(res.status === 404 || res.status === 405){  // older server without the batch route
    Object.values(panels).forEach(fetchStateOne);
    return;
  }
  if(!res.ok){
    document.getElementById("globalStatus").textContent = "can't refresh (" + res.status + ")";
    return;
  }
  document.getElementById("globalStatus").textContent = "";
  const data = await res.json();
  for(const s of (data.states || [])){
    const p = panels[s.id];
    if(p){ render(p, s); setError(p, null); }
  }
  for(const err of (data.errors || [])){
    const p = panels[err.id];
    if(p) setError(p, "can't reach this unit — " + (err.detail || "offline"));
  }
}

// Single-unit fetch — fallback path and initial per-panel load.
async function fetchStateOne(p){
  try{
    const res = await apiFetch(`/api/units/${p.id}/state`);
    if(res.status === 401){ setError(p, "session expired — re-pairing…"); reauth(); return; }
    if(!res.ok) throw new Error(await res.text());
    render(p, await res.json());
    setError(p, null);
  }catch(e){
    setError(p, "can't reach this unit — " + e.message);
  }
}

// Fetch the unit list, driving the pairing flow on a 401 and retrying.
async function loadUnits(){
  while(true){
    let res;
    try{
      res = await apiFetch("/api/units");
    }catch(e){
      document.getElementById("globalStatus").textContent = "can't reach server — " + e.message;
      return null;
    }
    if(res.ok) return await res.json();
    if(res.status === 401){
      clearDeviceToken();
      await enroll();   // resolves once a device token is stored
      continue;         // retry with the new token
    }
    document.getElementById("globalStatus").textContent = "can't load units (" + res.status + ")";
    return null;
  }
}

// Re-render every panel from its last state (used when the °C/°F unit flips).
function rerenderAll(){
  Object.values(panels).forEach(p => { if(p.state) render(p, p.state); });
}

// Per-card ⋮ actions: rename and remove.
function makeActions(){
  return {
    onRename: async (p) => {
      const cur = (p.state && p.state.name) || "";
      const r = await renameDialog(cur);
      if(!r || !r.name || r.name === cur) return;
      const res = await apiRenameUnit(p.id, r.name);
      if(res.status === 401){ reauth(); return; }
      if(!res.ok){ setError(p, "rename failed — " + await res.text()); return; }
      setName(p, r.name);
      if(p.state) p.state.name = r.name;
    },
    onRemove: async (p) => {
      const name = (p.state && p.state.name) || p.id;
      const ok = await confirmDialog({
        title: "Remove unit?",
        message: `"${name}" will be removed from the server config. Pair it again to re-add it.`,
        confirmLabel: "Remove",
      });
      if(!ok) return;
      const res = await apiDeleteUnit(p.id);
      if(res.status === 401){ reauth(); return; }
      if(!res.ok){ setError(p, "remove failed — " + await res.text()); return; }
      p.root.remove();
      delete panels[p.id];
      if(Object.keys(panels).length === 0){
        document.getElementById("emptyState").classList.remove("hidden");
      }
    },
  };
}

// (Re)build the grid from a unit list, replacing any existing panels.
function buildGrid(units){
  const grid = document.getElementById("grid");
  grid.innerHTML = "";
  Object.keys(panels).forEach(k => delete panels[k]);
  const empty = document.getElementById("emptyState");
  if(units.length === 0){ empty.classList.remove("hidden"); return; }
  empty.classList.add("hidden");
  const actions = makeActions();
  units.forEach(u => {
    const p = buildPanel(u, control, actions);
    panels[u.id] = p;
    grid.appendChild(p.root);
  });
}

async function reloadUnits(){
  const units = await loadUnits();
  if(units !== null) buildGrid(units);
}

// Add-unit dialog -> POST /api/units (server discovers it), then refresh.
async function doAddUnit(){
  const r = await addUnitDialog();
  if(!r || !r.ip) return;
  const status = document.getElementById("globalStatus");
  status.textContent = "discovering unit…";
  const res = await apiAddUnit(r.ip, r.name);
  if(res.status === 401){ status.textContent = ""; reauth(); return; }
  if(!res.ok){ status.textContent = "add failed — " + await res.text(); return; }
  status.textContent = "";
  await reloadUnits();
  await fetchAllStates();
}

function wireHeader(){
  const actions = document.querySelector(".header-actions");
  if(actions) actions.prepend(buildPalettePicker());  // 🎨 Theme, first
  const toggle = document.getElementById("unitToggle");
  if(toggle){
    toggle.textContent = "°" + tempUnit();
    toggle.addEventListener("click", () => {
      toggle.textContent = "°" + toggleTempUnit();
      rerenderAll();
    });
  }
  const add = document.getElementById("addUnitBtn");
  if(add) add.addEventListener("click", doAddUnit);
  const emptyAdd = document.getElementById("emptyAddBtn");
  if(emptyAdd) emptyAdd.addEventListener("click", doAddUnit);
}

// Fill the page footer with the server's version + build commit.
async function loadVersion(){
  const el = document.getElementById("appFooter");
  if(!el) return;
  try{
    const res = await apiFetch("/api/version");
    if(!res.ok) return;
    const v = await res.json();
    el.textContent = "";
    const name = document.createElement("span");
    name.textContent = `${v.name || "Breeze Core"} v${v.version}`;
    el.appendChild(name);
    if(v.commit && v.commit !== "unknown"){
      el.appendChild(document.createTextNode(" · "));
      const c = document.createElement("code");
      c.textContent = v.commit;
      el.appendChild(c);
    }
  }catch(_){/* footer is best-effort */}
}

async function init(){
  initPalette();  // apply the saved colour palette before first paint
  wireHeader();   // header (theme, add unit, °C/°F) works even with zero units
  loadVersion();  // fill the footer (best-effort, independent of units)
  const units = await loadUnits();
  if(units === null) return;
  buildGrid(units);

  // Skip poll ticks while re-pairing (each tick would 401 for every panel —
  // enough to trip a server-side fail2ban jail) and while the tab is hidden.
  const poll = () => {
    if(reauthing || document.hidden) return;
    if(Object.keys(panels).length === 0) return;
    fetchAllStates();
  };
  document.addEventListener("visibilitychange", () => {
    if(!document.hidden) poll();
  });
  poll();
  setInterval(poll, POLL_INTERVAL_MS);
}

init();
