# Container image for the hosted support-case-agent (Microsoft Agents Framework, .NET 10).
# Built on the in-VNet runner with `docker build` from the deploy-hosted-agent.yml workflow and
# pushed to the private ACR (over its private endpoint); Foundry pulls it to run the agent.
# Build context is THIS folder (the .Agent project).

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore first (better layer caching) then build.
COPY *.csproj ./
RUN dotnet restore
COPY . ./
RUN dotnet publish "support-case-agent.Agent.csproj" -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app ./

# The AgentHost web server hosts the agent protocol endpoints on port 8088 (its default) and
# Foundry reaches it over HTTP on that port. Do NOT override ASPNETCORE_URLS — setting a
# different port makes Foundry's provisioning probe hit nothing and the version fails to start.
EXPOSE 8088

ENTRYPOINT ["dotnet", "support-case-agent.Agent.dll"]
