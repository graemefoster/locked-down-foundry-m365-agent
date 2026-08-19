import type { Configuration, PopupRequest } from "@azure/msal-browser";

const redirectUri = new URL("/auth.html", window.location.origin).toString();

export const msalConfig: Configuration = {
  auth: {
    clientId: import.meta.env.VITE_MSAL_CLIENT_ID,
    authority: import.meta.env.VITE_MSAL_AUTHORITY,
    redirectUri,
    postLogoutRedirectUri: redirectUri,
  },
  cache: {
    cacheLocation: "localStorage",
  },
};

export const loginRequest: PopupRequest = {
  scopes: ["https://ai.azure.com/.default"],
  redirectUri,
};
