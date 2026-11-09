import { createRoot } from "react-dom/client";
import { App } from "./App";
import { Consent } from "./Consent";
import "./style.css";

// Two pages: the Claude consent screen, and the app.
const page =
  window.location.pathname === "/oauth/consent" ? (
    <div className="app center"><Consent /></div>
  ) : (
    <App />
  );
createRoot(document.getElementById("root")!).render(page);
