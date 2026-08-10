# Container image for the hosted support-case-agent (Microsoft Agents Framework, .NET 10).
# Built server-side by `az acr build` from the deploy-hosted-agent.yml workflow (no Docker
# daemon on the in-VNet runner) and pushed to the private ACR; Foundry pulls it to run the agent.
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

# The AgentHost web server hosts the agent protocol endpoints; Foundry reaches it over HTTP.
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "support-case-agent.Agent.dll"]
