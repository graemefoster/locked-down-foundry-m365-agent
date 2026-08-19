using System.Collections.Concurrent;
using Azure.Core;
using Azure.Identity;
using GitHub.Copilot.SDK;
using Microsoft.Extensions.Options;

namespace CopilotAgent;

public sealed class CopilotSessionManager(
    DefaultAzureCredential credential,
    IOptions<CopilotHostedAgentOptions> options,
    IWebHostEnvironment environment,
    ILogger<CopilotSessionManager> logger) : IAsyncDisposable
{
    private static readonly TokenRequestContext ByokTokenRequestContext = new(["https://ai.azure.com/.default"]);

    private readonly CopilotHostedAgentOptions _options = options.Value;
    private readonly SemaphoreSlim _sessionLock = new(1, 1);
    private readonly CopilotClient _client = new(new CopilotClientOptions
    {
        AutoStart = false,
        Cwd = environment.ContentRootPath,
    });
    private readonly ConcurrentDictionary<string, CopilotSession> _sessions = new();
    private Task? _startTask;

    public async Task<CopilotSession> GetSessionAsync(string sessionId, CancellationToken cancellationToken)
    {
        if (_sessions.TryGetValue(sessionId, out CopilotSession? existingSession))
        {
            logger.LogDebug("Using cached Copilot session {SessionId}.", sessionId);
            return existingSession;
        }

        await _sessionLock.WaitAsync(cancellationToken);
        try
        {
            if (_sessions.TryGetValue(sessionId, out existingSession))
            {
                return existingSession;
            }

            await EnsureClientStartedAsync(cancellationToken);

            CopilotSession session = await TryResumeSessionAsync(sessionId, cancellationToken)
                ?? await CreateSessionAsync(sessionId, cancellationToken);

            _sessions[sessionId] = session;
            return session;
        }
        finally
        {
            _sessionLock.Release();
        }
    }

    private async Task EnsureClientStartedAsync(CancellationToken cancellationToken)
    {
        if (_startTask is null)
        {
            logger.LogDebug("Starting Copilot client. ContentRootPath={ContentRootPath}", environment.ContentRootPath);
        }

        _startTask ??= _client.StartAsync(cancellationToken);
        await _startTask;
    }

    private async Task<CopilotSession?> TryResumeSessionAsync(string sessionId, CancellationToken cancellationToken)
    {
        try
        {
            ResumeSessionConfig resumeConfig = await CreateResumeSessionConfigAsync(cancellationToken);
            CopilotSession session = await _client.ResumeSessionAsync(sessionId, resumeConfig, cancellationToken);
            logger.LogInformation("Resumed Copilot session {SessionId}.", sessionId);
            return session;
        }
        catch (Exception ex)
        {
            logger.LogDebug(ex, "Unable to resume Copilot session {SessionId}; creating a new session. ExceptionType={ExceptionType}", sessionId, ex.GetType().FullName);
            return null;
        }
    }

    private async Task<CopilotSession> CreateSessionAsync(string sessionId, CancellationToken cancellationToken)
    {
        SessionConfig createConfig = await CreateSessionConfigAsync(sessionId, cancellationToken);
        CopilotSession session = await _client.CreateSessionAsync(createConfig, cancellationToken);
        logger.LogInformation("Created Copilot session {SessionId}.", sessionId);
        return session;
    }

    private async Task<SessionConfig> CreateSessionConfigAsync(string sessionId, CancellationToken cancellationToken)
    {
        ProviderConfig provider = await CreateProviderConfigAsync(cancellationToken);
        string model = GetModelDeploymentName();
        string workingDirectory = GetWorkingDirectory();
        List<string> skillDirectories = GetSkillDirectories();
        SystemMessageConfig? systemMessage = CreateSystemMessageConfig();

        logger.LogDebug(
            "Creating session config for {SessionId}. Model={Model}, WorkingDirectory={WorkingDirectory}, SkillDirectoryCount={SkillDirectoryCount}, HasSystemMessage={HasSystemMessage}",
            sessionId,
            model,
            workingDirectory,
            skillDirectories.Count,
            systemMessage is not null);

        return new SessionConfig
        {
            SessionId = sessionId,
            Provider = provider,
            Model = model,
            SystemMessage = systemMessage,
            SkillDirectories = skillDirectories,
            WorkingDirectory = workingDirectory,
            Streaming = true,
            OnPermissionRequest = PermissionHandler.ApproveAll,
        };
    }

    private async Task<ResumeSessionConfig> CreateResumeSessionConfigAsync(CancellationToken cancellationToken)
    {
        ProviderConfig provider = await CreateProviderConfigAsync(cancellationToken);
        string model = GetModelDeploymentName();
        string workingDirectory = GetWorkingDirectory();
        List<string> skillDirectories = GetSkillDirectories();
        SystemMessageConfig? systemMessage = CreateSystemMessageConfig();

        logger.LogDebug(
            "Creating resume config. Model={Model}, WorkingDirectory={WorkingDirectory}, SkillDirectoryCount={SkillDirectoryCount}, HasSystemMessage={HasSystemMessage}",
            model,
            workingDirectory,
            skillDirectories.Count,
            systemMessage is not null);

        return new ResumeSessionConfig
        {
            Provider = provider,
            Model = model,
            SystemMessage = systemMessage,
            SkillDirectories = skillDirectories,
            WorkingDirectory = workingDirectory,
            Streaming = true,
            OnPermissionRequest = PermissionHandler.ApproveAll,
        };
    }

    private async Task<ProviderConfig> CreateProviderConfigAsync(CancellationToken cancellationToken)
    {
        string endpoint = GetFoundryProjectEndpoint().TrimEnd('/');
        string baseUrl = $"{endpoint}/openai/v1/";

        logger.LogDebug("Requesting BYOK token for scope {Scope}.", string.Join(',', ByokTokenRequestContext.Scopes));
        AccessToken accessToken = await credential.GetTokenAsync(ByokTokenRequestContext, cancellationToken);

        logger.LogDebug(
            "Created provider config. EndpointHost={EndpointHost}, BaseUrl={BaseUrl}, TokenExpiresUtc={TokenExpiresUtc}, WireApi={WireApi}",
            TryGetUriHost(endpoint),
            baseUrl,
            accessToken.ExpiresOn.UtcDateTime,
            "responses");

        return new ProviderConfig
        {
            Type = "openai",
            BaseUrl = baseUrl,
            BearerToken = accessToken.Token,
            WireApi = "responses",
        };
    }

    private SystemMessageConfig? CreateSystemMessageConfig()
    {
        string? instructionsPath = _options.InstructionsFile;
        if (string.IsNullOrWhiteSpace(instructionsPath))
        {
            instructionsPath = "copilot-instructions.md";
            logger.LogDebug("No instructions file configured. Using default path {InstructionsPath}.", instructionsPath);
        }

        string absolutePath = Path.IsPathRooted(instructionsPath)
            ? instructionsPath
            : Path.Combine(environment.ContentRootPath, instructionsPath);

        if (!File.Exists(absolutePath))
        {
            logger.LogDebug("System instructions file not found at {InstructionsPath}. Continuing without system message.", absolutePath);
            return null;
        }

        string content = File.ReadAllText(absolutePath).Trim();
        if (string.IsNullOrWhiteSpace(content))
        {
            logger.LogDebug("System instructions file at {InstructionsPath} is empty. Continuing without system message.", absolutePath);
            return null;
        }

        logger.LogDebug("Loaded system instructions from {InstructionsPath}. CharacterCount={CharacterCount}", absolutePath, content.Length);

        return new SystemMessageConfig
        {
            Mode = SystemMessageMode.Replace,
            Content = content,
        };
    }

    private List<string> GetSkillDirectories()
    {
        List<string> skillDirectories = [];

        foreach (string skillDirectory in _options.SkillDirectories)
        {
            if (string.IsNullOrWhiteSpace(skillDirectory))
            {
                continue;
            }

            string resolvedDirectory = Path.IsPathRooted(skillDirectory)
                ? skillDirectory
                : Path.Combine(environment.ContentRootPath, skillDirectory);

            if (Directory.Exists(resolvedDirectory))
            {
                skillDirectories.Add(resolvedDirectory);
                logger.LogDebug("Using configured skill directory: {SkillDirectory}", resolvedDirectory);
            }
            else
            {
                logger.LogDebug("Configured skill directory does not exist and will be ignored: {SkillDirectory}", resolvedDirectory);
            }
        }

        string defaultSkillsDirectory = Path.Combine(environment.ContentRootPath, "skills");
        if (Directory.Exists(defaultSkillsDirectory) && !skillDirectories.Contains(defaultSkillsDirectory))
        {
            skillDirectories.Add(defaultSkillsDirectory);
            logger.LogDebug("Using default skill directory: {SkillDirectory}", defaultSkillsDirectory);
        }

        logger.LogDebug("Resolved {SkillDirectoryCount} skill directories.", skillDirectories.Count);

        return skillDirectories;
    }

    private string GetFoundryProjectEndpoint()
    {
        string? endpoint = Environment.GetEnvironmentVariable("FOUNDRY_PROJECT_ENDPOINT");
        if (!string.IsNullOrWhiteSpace(endpoint))
        {
            logger.LogDebug("Using Foundry project endpoint from FOUNDRY_PROJECT_ENDPOINT. EndpointHost={EndpointHost}", TryGetUriHost(endpoint));
            return endpoint;
        }

        endpoint = Environment.GetEnvironmentVariable("AZURE_AI_PROJECT_ENDPOINT");
        if (!string.IsNullOrWhiteSpace(endpoint))
        {
            logger.LogDebug("Using Foundry project endpoint from AZURE_AI_PROJECT_ENDPOINT. EndpointHost={EndpointHost}", TryGetUriHost(endpoint));
            return endpoint;
        }

        if (!string.IsNullOrWhiteSpace(_options.FoundryProjectEndpoint))
        {
            logger.LogDebug("Using Foundry project endpoint from HostedAgent options. EndpointHost={EndpointHost}", TryGetUriHost(_options.FoundryProjectEndpoint));
            return _options.FoundryProjectEndpoint;
        }

        throw new InvalidOperationException(
            "Set FOUNDRY_PROJECT_ENDPOINT or AZURE_AI_PROJECT_ENDPOINT to your Foundry project endpoint.");
    }

    private string GetModelDeploymentName()
    {
        string? model = Environment.GetEnvironmentVariable("MODEL_DEPLOYMENT_NAME");
        if (!string.IsNullOrWhiteSpace(model))
        {
            logger.LogDebug("Using model deployment from MODEL_DEPLOYMENT_NAME: {ModelDeployment}", model);
            return model;
        }

        model = Environment.GetEnvironmentVariable("AZURE_AI_MODEL_DEPLOYMENT_NAME");
        if (!string.IsNullOrWhiteSpace(model))
        {
            logger.LogDebug("Using model deployment from AZURE_AI_MODEL_DEPLOYMENT_NAME: {ModelDeployment}", model);
            return model;
        }

        if (!string.IsNullOrWhiteSpace(_options.ModelDeploymentName))
        {
            logger.LogDebug("Using model deployment from HostedAgent options: {ModelDeployment}", _options.ModelDeploymentName);
            return _options.ModelDeploymentName;
        }

        logger.LogDebug("No configured model deployment found. Falling back to default model deployment gpt-5.4.");
        return "gpt-5.4";
    }

    private string GetWorkingDirectory()
    {
        string? configuredWorkingDirectory = _options.WorkingDirectory;
        if (!string.IsNullOrWhiteSpace(configuredWorkingDirectory))
        {
            logger.LogDebug("Using configured working directory: {WorkingDirectory}", configuredWorkingDirectory);
            return configuredWorkingDirectory;
        }

        string homeDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrWhiteSpace(homeDirectory))
        {
            logger.LogDebug("Using user profile home directory as working directory: {WorkingDirectory}", homeDirectory);
            return homeDirectory;
        }

        logger.LogDebug("User profile home directory was empty. Falling back to content root as working directory: {WorkingDirectory}", environment.ContentRootPath);
        return environment.ContentRootPath;
    }

    private static string? TryGetUriHost(string? endpoint)
    {
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            return null;
        }

        return Uri.TryCreate(endpoint, UriKind.Absolute, out Uri? uri) ? uri.Host : endpoint;
    }

    public async ValueTask DisposeAsync()
    {
        foreach (CopilotSession session in _sessions.Values)
        {
            await session.DisposeAsync();
        }

        await _client.DisposeAsync();
        _sessionLock.Dispose();
    }
}
