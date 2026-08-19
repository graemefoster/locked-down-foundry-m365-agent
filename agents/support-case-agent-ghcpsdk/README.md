# support_case_agent_ghcpsdk Hosted Agent Template

This folder is a `dotnet new` template source.

## Install locally

```bash
dotnet new install ./template
```

## Create a project

```bash
dotnet new ghcp-hosted-agent -n MyHostedAgent
```

This creates:

- `MyHostedAgent.sln`
- `src/agent/MyHostedAgent.Agent.csproj`
- `src/web/*` React + Vite client

## Run

```bash
cd MyHostedAgent/src/agent
dotnet run

cd ../web
npm install
npm run dev
```
