// manage.js — unit management: add-by-IP, rename, delete.
//
// Talks to the /api config-management endpoints (Breeze Core >= 2.2.0 for
// add/rename, >= 2.4.0 for delete) through apiFetch, so both credentials ride
// along. Dialogs are built in-DOM (CSP-safe: no inline styles/handlers) and
// reuse the .enroll-* overlay styles.

import { apiFetch } from "./api.js";

// A tiny modal: title + text fields, resolves to {key: value, …} or null.
// fields: [{ key, label, placeholder?, value? }]
function modal({ title, fields, submitLabel = "Save" }){
  return new Promise((resolve) => {
    const overlay = document.createElement("div");
    overlay.className = "enroll-overlay";

    const card = document.createElement("div");
    card.className = "enroll-card";
    overlay.appendChild(card);

    const h = document.createElement("h2");
    h.textContent = title;
    card.appendChild(h);

    const inputs = {};
    fields.forEach((f) => {
      const inp = document.createElement("input");
      inp.className = "enroll-input";
      inp.type = "text";
      inp.maxLength = 64;
      if(f.placeholder) inp.placeholder = f.placeholder;
      if(f.value) inp.value = f.value;
      card.appendChild(inp);
      inputs[f.key] = inp;
    });

    const err = document.createElement("div");
    err.className = "enroll-error hidden";
    card.appendChild(err);

    const btnRow = document.createElement("div");
    btnRow.className = "btn-row";
    const cancel = document.createElement("button");
    cancel.className = "enroll-btn secondary";
    cancel.textContent = "Cancel";
    const submit = document.createElement("button");
    submit.className = "enroll-btn";
    submit.textContent = submitLabel;
    btnRow.append(cancel, submit);
    card.appendChild(btnRow);

    const close = (result) => { overlay.remove(); resolve(result); };
    cancel.onclick = () => close(null);
    overlay.addEventListener("click", (e) => { if(e.target === overlay) close(null); });
    submit.onclick = () => {
      const out = {};
      for(const [k, inp] of Object.entries(inputs)) out[k] = inp.value.trim();
      close(out);
    };
    fields.forEach((f) => {
      inputs[f.key].addEventListener("keydown", (e) => { if(e.key === "Enter") submit.click(); });
    });

    document.body.appendChild(overlay);
    const first = inputs[fields[0].key];
    if(first) first.focus();
  });
}

// --- dialogs ---
export function addUnitDialog(){
  return modal({
    title: "Add unit by IP",
    submitLabel: "Add",
    fields: [
      { key: "ip", placeholder: "unit IP address (e.g. 192.168.1.73)" },
      { key: "name", placeholder: "name (optional)" },
    ],
  });
}
export function renameDialog(current){
  return modal({
    title: "Rename unit",
    submitLabel: "Save",
    fields: [{ key: "name", value: current || "", placeholder: "name" }],
  });
}

// A yes/no confirmation. Resolves true (confirmed) or false (cancelled).
export function confirmDialog({ title, message, confirmLabel = "OK" }){
  return new Promise((resolve) => {
    const overlay = document.createElement("div");
    overlay.className = "enroll-overlay";
    const card = document.createElement("div");
    card.className = "enroll-card";
    overlay.appendChild(card);

    const h = document.createElement("h2");
    h.textContent = title;
    card.appendChild(h);
    if(message){
      const p = document.createElement("p");
      p.className = "enroll-intro";
      p.textContent = message;
      card.appendChild(p);
    }

    const btnRow = document.createElement("div");
    btnRow.className = "btn-row";
    const cancel = document.createElement("button");
    cancel.className = "enroll-btn secondary";
    cancel.textContent = "Cancel";
    const ok = document.createElement("button");
    ok.className = "enroll-btn danger";
    ok.textContent = confirmLabel;
    btnRow.append(cancel, ok);
    card.appendChild(btnRow);

    const close = (r) => { overlay.remove(); resolve(r); };
    cancel.onclick = () => close(false);
    ok.onclick = () => close(true);
    overlay.addEventListener("click", (e) => { if(e.target === overlay) close(false); });
    document.body.appendChild(overlay);
    ok.focus();
  });
}

// --- API calls (return the raw Response; caller handles 401/errors) ---
export function apiAddUnit(ip, name){
  const body = name ? { ip, name } : { ip };
  return apiFetch("/api/units", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}
export function apiRenameUnit(id, name){
  return apiFetch(`/api/units/${id}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  });
}
export function apiDeleteUnit(id){
  return apiFetch(`/api/units/${id}`, { method: "DELETE" });
}
