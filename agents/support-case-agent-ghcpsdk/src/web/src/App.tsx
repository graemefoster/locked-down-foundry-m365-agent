import { useEffect, useRef, useState } from "react";
import { useIsAuthenticated, useMsal } from "@azure/msal-react";
import { loginRequest } from "./authConfig";
import {
  type ChatMessage,
  type AgentActivity,
  streamMessage,
  uploadSessionFile,
} from "./services/agentService";
import "./App.css";

function App() {
  const isAuthenticated = useIsAuthenticated();
  const { instance, accounts } = useMsal();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [streamingText, setStreamingText] = useState<string | null>(null);
  const [activities, setActivities] = useState<AgentActivity[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [uploadPath, setUploadPath] = useState("");
  const [uploadMessage, setUploadMessage] = useState<string | null>(null);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    // Keep the latest streamed/message content in view.
    bottomRef.current?.scrollIntoView({ behavior: "auto" });
  }, [messages, streamingText, activities, error]);

  const handleSignIn = async () => {
    try {
      const result = await instance.loginPopup(loginRequest);
      instance.setActiveAccount(result.account);
    } catch (err) {
      console.error(err);
    }
  };

  const handleSignOut = async () => {
    try {
      const account = instance.getActiveAccount() ?? accounts[0];

      await instance.logoutPopup({
        account,
        postLogoutRedirectUri: loginRequest.redirectUri,
        mainWindowRedirectUri: window.location.origin,
      });

      instance.setActiveAccount(null);
    } catch (err) {
      console.error(err);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || loading) return;

    const userMessage: ChatMessage = { role: "user", content: input.trim() };
    const nextMessages = [...messages, userMessage];
    setMessages(nextMessages);
    setInput("");
    setError(null);
    setLoading(true);
    setStreamingText("");
    setActivities([]);

    try {
      const tokenResult = await instance
        .acquireTokenSilent({ ...loginRequest, account: accounts[0] })
        .catch(() => instance.acquireTokenPopup({ ...loginRequest, account: accounts[0] }));

      let nextStreamingText = "";
      const { text, sessionId: nextSessionId } = await streamMessage(
        tokenResult.accessToken,
        nextMessages,
        sessionId,
        (delta) => {
          nextStreamingText += delta;
          setStreamingText(nextStreamingText);
        },
        (activity) => {
          setActivities((prev) => [...prev, activity]);
        }
      );

      setSessionId(nextSessionId);
      setMessages([...nextMessages, { role: "assistant", content: text }]);
      setStreamingText(null);
      bottomRef.current?.scrollIntoView({ behavior: "smooth" });
    } catch (err) {
      setError(err instanceof Error ? err.message : "Unknown error");
      setStreamingText(null);
    } finally {
      setLoading(false);
    }
  };

  const handleUpload = async () => {
    if (!selectedFile || !uploadPath.trim() || uploading || loading) {
      return;
    }

    if (!sessionId) {
      setError("Start a chat first so a session is created, then upload the file.");
      return;
    }

    setUploadMessage(null);
    setError(null);
    setUploading(true);

    try {
      const tokenResult = await instance
        .acquireTokenSilent({ ...loginRequest, account: accounts[0] })
        .catch(() => instance.acquireTokenPopup({ ...loginRequest, account: accounts[0] }));

      const result = await uploadSessionFile(tokenResult.accessToken, sessionId, uploadPath.trim(), selectedFile);
      setUploadMessage(`Uploaded ${result.fileName} to ${result.remotePath}`);
      setSelectedFile(null);
      setUploadPath("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "File upload failed");
    } finally {
      setUploading(false);
    }
  };

  if (!isAuthenticated) {
    return (
      <div className="auth-container">
        <h1>support_case_agent_ghcpsdk Agent</h1>
        <button onClick={handleSignIn}>Sign in</button>
      </div>
    );
  }

  const userName = accounts[0]?.name ?? accounts[0]?.username ?? "User";

  return (
    <div className="chat-shell">
      <header className="chat-header">
        <h1>support_case_agent_ghcpsdk Agent</h1>
        <div className="header-right">
          <span className="user-name">{userName}</span>
          <button className="sign-out" onClick={handleSignOut}>Sign out</button>
        </div>
      </header>

      <div className="messages">
        {messages.map((m, i) => (
          <div key={i} className={`message ${m.role}`}>
            <span className="bubble">{m.content}</span>
          </div>
        ))}
        {streamingText !== null && (
          <div className="message assistant">
            <div className="assistant-content">
              {activities.length > 0 && (
                <details className="activity-log" open>
                  <summary className="activity-summary">
                    {activities[activities.length - 1].label}
                  </summary>
                  <ul className="activity-list">
                    {activities.map((a, i) => (
                      <li key={i} className={`activity-item activity-${a.kind}`}>
                        <span className="activity-icon">
                          {a.kind === "tool" ? "🔧" : a.kind === "reasoning" ? "💭" : "🎯"}
                        </span>
                        {a.label}
                      </li>
                    ))}
                  </ul>
                </details>
              )}
              {streamingText ? (
                <span className="bubble streaming">{streamingText}</span>
              ) : (
                <span className="bubble streaming">…</span>
              )}
            </div>
          </div>
        )}
        {error && <div className="message error"><span className="bubble">{error}</span></div>}
        <div ref={bottomRef} />
      </div>

      <form onSubmit={handleSubmit} className="chat-input-row">
        <label className="file-picker" aria-label="Upload file to current session">
          <input
            type="file"
            onChange={(e) => {
              const nextFile = e.target.files?.[0] ?? null;
              setSelectedFile(nextFile);
              if (nextFile) {
                setUploadPath(nextFile.name);
              }
              setUploadMessage(null);
            }}
            disabled={loading || uploading}
          />
          <span>{selectedFile?.name ?? "Choose file"}</span>
        </label>
        <input
          type="text"
          value={uploadPath}
          onChange={(e) => setUploadPath(e.target.value)}
          className="upload-path"
          placeholder="Session path (for example data/file.csv)"
          disabled={loading || uploading}
        />
        <button
          type="button"
          className="upload-btn"
          disabled={!selectedFile || !uploadPath.trim() || !sessionId || loading || uploading}
          onClick={handleUpload}
          title={sessionId ? "Upload to active agent session" : "Send a message first to create a session"}
        >
          {uploading ? "Uploading…" : "Upload"}
        </button>
        <input
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Message GitHub Copilot…"
          disabled={loading}
          autoFocus
        />
        <button type="submit" disabled={loading || !input.trim()}>
          {loading ? "…" : "Send"}
        </button>
      </form>
      {uploadMessage && <div className="upload-status">{uploadMessage}</div>}
    </div>
  );
}

export default App;
