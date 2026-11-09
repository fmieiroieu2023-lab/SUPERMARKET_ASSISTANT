import { lazy, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
// The consent screen is rarely used, so it loads only when needed.
const Consent = lazy(() => import("./Consent").then((m) => ({ default: m.Consent })));
import "./style.css";

// Two pages: the Claude consent screen, and the app.
const page =
  window.location.pathname === "/oauth/consent" ? (
    <div className="app center"><Suspense fallback={null}><Consent /></Suspense></div>
  ) : (
    <App />
  );
createRoot(document.getElementById("root")!).render(page);

if ("serviceWorker" in navigator && import.meta.env.PROD) void navigator.serviceWorker.register("/sw.js");
