// enroll.js — drives the device-pairing overlay.
//
// Flow (client side of the RFC 8628-style handshake):
//   1. POST /api/auth/enroll/start  → show the one-time code + countdown
//   2. an admin approves that code on the LAN
//   3. poll /api/auth/enroll/poll   → on approval, store the device token
//
// enroll() resolves true once a device token has been stored; the caller
// (app.js) then retries the request that triggered pairing.

import { apiFetch, clearApiKey, setDeviceToken } from "./api.js";

const POLL_MS = 2000;

export function enroll(){
  return new Promise((resolve) => {
    const ov = document.getElementById("enrollOverlay");
    const step1 = document.getElementById("enrollStep1");
    const step2 = document.getElementById("enrollStep2");
    const labelInput = document.getElementById("enrollLabel");
    const startBtn = document.getElementById("enrollStartBtn");
    const codeEl = document.getElementById("enrollCode");
    const countdownEl = document.getElementById("enrollCountdown");
    const errorEl = document.getElementById("enrollError");

    let pollTimer = null, countdownTimer = null;

    const showError = (msg) => { errorEl.textContent = msg; errorEl.classList.remove("hidden"); };
    const clearError = () => errorEl.classList.add("hidden");
    const stopTimers = () => {
      if(pollTimer) clearInterval(pollTimer);
      if(countdownTimer) clearInterval(countdownTimer);
      pollTimer = countdownTimer = null;
    };
    const toStep1 = () => {
      stopTimers();
      step2.classList.add("hidden");
      step1.classList.remove("hidden");
      startBtn.disabled = false;
    };

    ov.classList.remove("hidden");

    async function begin(){
      clearError();
      startBtn.disabled = true;
      const label = (labelInput.value || "").trim();

      let res;
      try{
        res = await apiFetch("/api/auth/enroll/start", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify({label})
        });
      }catch(e){
        showError("network error — " + e.message);
        startBtn.disabled = false;
        return;
      }

      if(res.status === 401){
        clearApiKey();  // wrong enrollment key — will re-prompt next attempt
        showError("wrong API key — press start to enter it again");
        startBtn.disabled = false;
        return;
      }
      if(res.status === 429){
        showError("too many attempts — wait a minute and try again");
        startBtn.disabled = false;
        return;
      }
      if(!res.ok){
        showError("couldn't start pairing (" + res.status + ")");
        startBtn.disabled = false;
        return;
      }

      const {session_id, user_code, expires_in} = await res.json();
      codeEl.textContent = user_code;
      step1.classList.add("hidden");
      step2.classList.remove("hidden");

      let remaining = expires_in;
      countdownEl.textContent = remaining;
      countdownTimer = setInterval(() => {
        remaining -= 1;
        countdownEl.textContent = Math.max(0, remaining);
        if(remaining <= 0){ showError("code expired — start again"); toStep1(); }
      }, 1000);

      pollTimer = setInterval(async () => {
        let pres;
        try{
          pres = await apiFetch("/api/auth/enroll/poll", {
            method: "POST",
            headers: {"Content-Type": "application/json"},
            body: JSON.stringify({session_id})
          });
        }catch(e){ return; }  // transient network blip — keep polling
        if(!pres.ok) return;

        const data = await pres.json();
        if(data.status === "approved" && data.device_token){
          stopTimers();
          setDeviceToken(data.device_token);
          ov.classList.add("hidden");
          resolve(true);
        }else if(data.status === "expired" || data.status === "unknown"){
          showError("code expired — start again");
          toStep1();
        }
      }, POLL_MS);
    }

    startBtn.onclick = begin;
  });
}
