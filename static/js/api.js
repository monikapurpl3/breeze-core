// api.js — the single HTTP client layer for the UI.
//
// LOAD-BEARING: every request to the backend goes through apiFetch(),
// which attaches BOTH credentials — the enrollment/API key (X-API-Key)
// and, once this device is paired, its per-device bearer token. A past
// UI rewrite bypassed this wrapper and shipped a panel that 401'd on
// every call. If you add new API calls, route them through apiFetch —
// never call fetch() directly.
//
// Two secrets live in localStorage:
//   meow_ac_key           the shared enrollment key (prompted for)
//   meow_ac_device_token  this device's access token (obtained by
//                         completing the pairing flow — see enroll.js)
// apiFetch does not auto-clear either on 401; app.js/enroll.js own that
// decision, because a 401 can mean "wrong key" or "token expired" and
// the recovery differs.

const KEY_STORAGE = "meow_ac_key";
const TOKEN_STORAGE = "meow_ac_device_token";

export function getApiKey(){
  let key = localStorage.getItem(KEY_STORAGE);
  if(!key){
    key = (prompt("API key (from /etc/meow-ac/config.json on meow):") || "").trim();
    if(key) localStorage.setItem(KEY_STORAGE, key);
  }
  return key;
}

export function clearApiKey(){
  localStorage.removeItem(KEY_STORAGE);
}

export function getDeviceToken(){
  return localStorage.getItem(TOKEN_STORAGE) || "";
}

export function setDeviceToken(token){
  localStorage.setItem(TOKEN_STORAGE, token);
}

export function clearDeviceToken(){
  localStorage.removeItem(TOKEN_STORAGE);
}

// Thin fetch wrapper: attaches the API key and (if present) the device
// token. Returns the raw Response — callers inspect status so they can
// tell "needs pairing" (401) from other failures.
export async function apiFetch(path, opts = {}){
  const headers = Object.assign({}, opts.headers, {"X-API-Key": getApiKey()});
  const token = getDeviceToken();
  if(token) headers["Authorization"] = "Bearer " + token;
  return fetch(path, Object.assign({}, opts, {headers}));
}
