# Container image for the hosted workflow-support-agent (Microsoft Agents Framework, .NET 10).
# Mirrors agents/support-case-agent/support-case-agent.Agent/Dockerfile. The CODE deploy path
# (deploy-workflow-support-agent-code.yml -> _deploy-code-agent.yml) only uses the `build` stage to
# produce the `dotnet publish` output; the `runtime` stage exists for parity / local image runs.
# Build context is THIS folder (the .Agent project).

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore first (better layer caching) then build.
COPY *.csproj ./
RUN dotnet restore
COPY . ./
RUN dotnet publish "workflow-support-agent.Agent.csproj" -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app ./

# The AgentHost web server hosts the agent protocol endpoints on port 8088 (its default) and
# Foundry reaches it over HTTP on that port. Do NOT override ASPNETCORE_URLS.
EXPOSE 8088

ENTRYPOINT ["dotnet", "workflow-support-agent.Agent.dll"]
