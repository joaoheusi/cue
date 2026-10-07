import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles/app.css";
document.documentElement.dataset.surface =
  new URLSearchParams(location.search).get("surface") === "palette"
    ? "palette"
    : "library";
ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
