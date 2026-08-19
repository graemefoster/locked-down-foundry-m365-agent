FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base

# Install Python, LibreOffice, and system dependencies for document processing
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    libreoffice \
    libreoffice-calc \
    libreoffice-writer \
    && rm -rf /var/lib/apt/lists/*

# Install common document processing Python libraries
RUN pip install --no-cache-dir --break-system-packages \
    PyPDF2 \
    python-docx \
    openpyxl \
    pandas \
    pillow \
    python-pptx \
    unidecode \
    pydantic

WORKDIR /app
EXPOSE 8088
ENV ASPNETCORE_URLS=http://+:8088
ENV PYTHONPATH=/app/skills

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY . .
RUN dotnet restore
RUN dotnet publish -c Release -o /app/publish

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .

# Copy skills packages into the container (sourced from src/agent/skills/ in the build context)
COPY --from=build /src/skills ./skills

ENTRYPOINT ["dotnet", "support_case_agent_ghcpsdk.Agent.dll"]
