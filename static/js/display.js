// display.js — client-side display preferences (temperature unit).
//
// Display-only: the wire contract is always Celsius (16–30 in 0.5° steps);
// this just converts for presentation, like the mobile app's °C/°F toggle.
// The choice is per-browser, stored in localStorage.

const UNIT_KEY = "meow_ac_temp_unit";

export function tempUnit(){
  return localStorage.getItem(UNIT_KEY) === "F" ? "F" : "C";
}
export function setTempUnit(u){
  localStorage.setItem(UNIT_KEY, u === "F" ? "F" : "C");
}
export function toggleTempUnit(){
  const next = tempUnit() === "C" ? "F" : "C";
  setTempUnit(next);
  return next;
}

// Format a Celsius value in the active unit. `showUnit` appends °C/°F;
// otherwise just a degree sign. Null/undefined -> "--°".
export function fmtTemp(celsius, { showUnit = true } = {}){
  if(celsius === null || celsius === undefined) return "--°";
  const f = tempUnit() === "F";
  const v = f ? (celsius * 9 / 5 + 32) : celsius;
  return v.toFixed(1) + "°" + (showUnit ? (f ? "F" : "C") : "");
}
