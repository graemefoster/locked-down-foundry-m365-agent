using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Azure.AI.AgentServer.Invocations;
using GitHub.Copilot.SDK;
using Microsoft.AspNetCore.Http;

namespace CopilotAgent;

public sealed class GitHubCopilotInvocationHandler(
    CopilotSessionManager sessionManager,
    ILogger<GitHubCopilotInvocationHandler> logger) : InvocationHandler
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public override async Task HandleAsync(
        HttpRequest request,
        HttpResponse response,
        InvocationContext context,
        CancellationToken cancellationToken)
    {
        CopilotInvocationRequest? body;
        try
        {
            body = await request.ReadFromJsonAsync<CopilotInvocationRequest>(JsonOptions, cancellationToken);
        }
        catch (JsonException)
        {
            body = null;
        }

        string prompt = body?.Input ?? body?.Message ?? string.Empty;
        if (string.IsNullOrWhiteSpace(prompt))
        {
            response.StatusCode = StatusCodes.Status400BadRequest;
            await response.WriteAsJsonAsync(
                new
                {
                    error = "invalid_request",
                    message = "Request body must contain a non-empty \"input\" string.",
                },
                JsonOptions,
                cancellationToken);
            return;
        }

        CopilotSession session = await sessionManager.GetSessionAsync(context.SessionId, cancellationToken);

        response.StatusCode = StatusCodes.Status200OK;
        response.ContentType = "text/event-stream";
        response.Headers.CacheControl = "no-cache";
        response.Headers.Append("X-Accel-Buffering", "no");

        Channel<SessionEvent> events = Channel.CreateUnbounded<SessionEvent>();
        using IDisposable subscription = session.On(sessionEvent => events.Writer.TryWrite(sessionEvent));

        string? completeMessage = null;
        StringBuilder deltaText = new();
        MessageOptions message = new()
        {
            Prompt = prompt,
            RequestHeaders = new Dictionary<string, string>
            {
                ["x-agent-invocation-id"] = context.InvocationId,
            },
        };

        Task<string> sendTask = session.SendAsync(message, cancellationToken);

        try
        {
            while (await events.Reader.WaitToReadAsync(cancellationToken))
            {
                while (events.Reader.TryRead(out SessionEvent? sessionEvent))
                {
                    switch (sessionEvent)
                    {
                        case AssistantMessageDeltaEvent deltaEvent when !string.IsNullOrEmpty(deltaEvent.Data?.DeltaContent):
                            deltaText.Append(deltaEvent.Data.DeltaContent);
                            await WriteEventAsync(response, deltaEvent, cancellationToken);
                            break;

                        case AssistantMessageEvent messageEvent when !string.IsNullOrEmpty(messageEvent.Data?.Content):
                            completeMessage = messageEvent.Data.Content;
                            await WriteEventAsync(response, messageEvent, cancellationToken);
                            break;

                        case SessionErrorEvent errorEvent:
                            logger.LogError("Copilot session {SessionId} reported an error: {EventType}", context.SessionId, errorEvent.Type);
                            await WritePayloadAsync(
                                response,
                                new
                                {
                                    type = "error",
                                    invocationId = context.InvocationId,
                                    sessionId = context.SessionId,
                                    detail = errorEvent,
                                },
                                cancellationToken);
                            await WriteDoneAsync(response, context, completeMessage, deltaText.ToString(), cancellationToken);
                            return;

                        case SessionIdleEvent idleEvent:
                            await WriteEventAsync(response, idleEvent, cancellationToken);
                            await sendTask;
                            await WriteDoneAsync(response, context, completeMessage, deltaText.ToString(), cancellationToken);
                            return;

                        default:
                            await WriteEventAsync(response, sessionEvent, cancellationToken);
                            break;
                    }
                }
            }

            await sendTask;
            await WriteDoneAsync(response, context, completeMessage, deltaText.ToString(), cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Copilot invocation {InvocationId} failed.", context.InvocationId);
            await WritePayloadAsync(
                response,
                new
                {
                    type = "error",
                    invocationId = context.InvocationId,
                    sessionId = context.SessionId,
                    message = ex.Message,
                },
                cancellationToken);
            await WriteDoneAsync(response, context, completeMessage, deltaText.ToString(), cancellationToken);
        }
    }

    private static Task WriteEventAsync(HttpResponse response, SessionEvent sessionEvent, CancellationToken cancellationToken) =>
        WriteRawPayloadAsync(response, JsonSerializer.Serialize(sessionEvent, sessionEvent.GetType(), JsonOptions), cancellationToken);

    private static Task WritePayloadAsync(HttpResponse response, object payload, CancellationToken cancellationToken) =>
        WriteRawPayloadAsync(response, JsonSerializer.Serialize(payload, JsonOptions), cancellationToken);

    private static async Task WriteDoneAsync(
        HttpResponse response,
        InvocationContext context,
        string? completeMessage,
        string deltaText,
        CancellationToken cancellationToken)
    {
        await WritePayloadAsync(
            response,
            new
            {
                type = "done",
                invocationId = context.InvocationId,
                sessionId = context.SessionId,
                fullText = string.IsNullOrEmpty(completeMessage) ? deltaText : completeMessage,
            },
            cancellationToken);
    }

    private static async Task WriteRawPayloadAsync(
        HttpResponse response,
        string jsonPayload,
        CancellationToken cancellationToken)
    {
        await response.WriteAsync($"data: {jsonPayload}\n\n", cancellationToken);
        await response.Body.FlushAsync(cancellationToken);
    }

    private sealed record CopilotInvocationRequest(string? Input, string? Message);
}
