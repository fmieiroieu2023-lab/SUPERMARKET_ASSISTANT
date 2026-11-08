import { createRoot } from "react-dom/client";
import { Consent } from "./Consent";
import "./style.css";

// No router yet (step 3 adds the app). One path matters for now.
const page = window.location.pathname === "/oauth/consent" ? <Consent /> : <h1>Hello</h1>;
createRoot(document.getElementById("root")!).render(page);
