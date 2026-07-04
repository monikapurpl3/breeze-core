// app.js — the entry module: ensures this device is paired, loads units,
// wires each card's control callback to the API, and runs the poll loop.
// It's the only module that combines transport (api.js), pairing
// (enroll.js), and rendering (unit-card.js).

import { apiFetch, clearDeviceToken } from "./api.js";
import { buildPanel, render, setError } from "./unit-card.js";
import { enroll } from "./enroll.js";

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

async function fetchState(p){
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

async function init(){
  const units = await loadUnits();
  if(units === null) return;

  if(units.length === 0){
    document.getElementById("emptyState").classList.remove("hidden");
    return;
  }

  const grid = document.getElementById("grid");
  units.forEach(u => {
    const p = buildPanel(u, control);
    panels[u.id] = p;
    grid.appendChild(p.root);
  });

  // Skip poll ticks while re-pairing (each tick would 401 for every
  // panel — enough to trip a server-side fail2ban jail) and while the
  // tab is hidden (no point hammering the API for an invisible page).
  const poll = () => {
    if(reauthing || document.hidden) return;
    Object.values(panels).forEach(fetchState);
  };
  document.addEventListener("visibilitychange", () => {
    if(!document.hidden) poll();
  });
  poll();
  setInterval(poll, POLL_INTERVAL_MS);
}

init();
