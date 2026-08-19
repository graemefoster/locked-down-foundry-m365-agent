# Container image for the hosted support-case-agent-ghcpsdk (GitHub Copilot SDK, .NET 10).
# The CODE deploy path (_deploy-code-agent.yml) builds the `build` stage with `docker build
# --target build`, copies the publish output from /app, and ships it to Foundry as a zip
# (code_configuration) - so no image is pushed and Foundry never pulls from the private ACR.
# Build context is THIS folder (the .Agent project).

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore first (better layer caching) then publish to /app. The csproj copies copilot-instructions.md
# and skills/** into the output, so /app already contains everything the agent needs at runtime.
COPY *.csproj ./
RUN dotnet restore
COPY . ./
RUN dotnet publish "support-case-agent-ghcpsdk.Agent.csproj" -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app ./

# The AgentHost web server hosts the agent protocol endpoints on port 8088 (its default) and
# Foundry reaches it over HTTP on that port. Do NOT override ASPNETCORE_URLS.
EXPOSE 8088

ENTRYPOINT ["dotnet", "support-case-agent-ghcpsdk.Agent.dll"]
