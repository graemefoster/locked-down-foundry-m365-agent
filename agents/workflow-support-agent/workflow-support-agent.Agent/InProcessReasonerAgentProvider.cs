using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Workflows.Declarative;
using Microsoft.Extensions.AI;

namespace workflow_support_agent.Agent;

/// <summary>
/// A <see cref="ResponseAgentProvider"/> that resolves the declarative workflow's
/// <c>InvokeAzureAgent</c> steps against a single <b>in-process</b> <see cref="AIAgent"/> instead of
/// a separately-seeded, persisted Foundry agent. This keeps the whole agent one self-contained
/// deployable: the reasoning helper lives inside this process and never needs its own manifest,
/// workflow, or project-side create/publish.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="AzureAgentProvider"/> is sealed, so we implement the abstract base directly. The
/// <c>agentId</c>/<c>agentVersion</c> from the YAML are intentionally ignored — there is exactly one
/// reasoning helper. The rich per-step context the workflow passes in <c>input.messages</c> is what
/// the agent reasons over.
/// </para>
/// <para>
/// <b>Durability.</b> Each workflow conversation gets its own reasoner <see cref="AgentSession"/> so
/// multi-turn reasoning stays coherent. That session (plus this provider's conversation message
/// store) is <b>persisted to disk</b> under the same root the host's
/// <c>FileSystemAgentSessionStore</c> uses, and rehydrated on demand. Without this, a process
/// restart (VM suspend/resume, container recycle) would drop the reasoner's memory mid-case even
/// though the outer workflow session survives — leaving the two layers inconsistent. State is
/// written through <see cref="AIAgent.SerializeSessionAsync"/> /
/// <see cref="AIAgent.DeserializeSessionAsync"/>. Persistence is only as durable as the underlying
/// volume — if the host disk is ephemeral, both layers still reset together, which is the platform
/// baseline.
/// </para>
/// </remarks>
public sealed class InProcessReasonerAgentProvider : ResponseAgentProvider
{
    private static readonly JsonSerializerOptions SerializerOptions = AIJsonUtilities.DefaultOptions;

    private readonly AIAgent _reasoner;
    private readonly string _persistenceDirectory;
    private readonly ConcurrentDictionary<string, Conversation> _conversations = new();

    public InProcessReasonerAgentProvider(AIAgent reasoner, string persistenceDirectory)
    {
        _reasoner = reasoner;
        _persistenceDirectory = persistenceDirectory;
        Directory.CreateDirectory(_persistenceDirectory);
    }

    private sealed class Conversation
    {
        public required string Id { get; init; }
        public readonly List<ChatMessage> Messages = [];
        public AgentSession? Session;
        public bool Loaded;

        // Serializes all disk + session access for this one conversation. Conversations are
        // human-paced, so this coarse gate costs nothing and keeps the on-disk snapshot consistent.
        public readonly SemaphoreSlim Gate = new(1, 1);
    }

    private sealed class PersistedConversation
    {
        public List<ChatMessage> Messages { get; set; } = [];
        public JsonElement? Session { get; set; }
    }

    private Conversation GetOrCreate(string? conversationId)
    {
        var id = string.IsNullOrWhiteSpace(conversationId) ? "default" : conversationId;
        return _conversations.GetOrAdd(id, key => new Conversation { Id = key });
    }

    private string FilePath(string conversationId)
    {
        var safe = string.Concat(conversationId.Select(c =>
            char.IsLetterOrDigit(c) || c is '-' or '_' ? c : '_'));
        return Path.Combine(_persistenceDirectory, $"{safe}.json");
    }

    // Rehydrates the conversation (message store + reasoner session) from disk exactly once.
    // Callers MUST hold conversation.Gate.
    private async Task EnsureLoadedAsync(Conversation conversation, CancellationToken cancellationToken)
    {
        if (conversation.Loaded)
        {
            return;
        }

        var path = FilePath(conversation.Id);
        if (File.Exists(path))
        {
            try
            {
                await using var stream = File.OpenRead(path);
                var persisted = await JsonSerializer
                    .DeserializeAsync<PersistedConversation>(stream, SerializerOptions, cancellationToken)
                    .ConfigureAwait(false);

                if (persisted is not null)
                {
                    conversation.Messages.Clear();
                    conversation.Messages.AddRange(persisted.Messages);
                    if (persisted.Session is { } sessionState)
                    {
                        conversation.Session = await _reasoner
                            .DeserializeSessionAsync(sessionState, SerializerOptions, cancellationToken)
                            .ConfigureAwait(false);
                    }
                }
            }
            catch (Exception ex) when (ex is JsonException or IOException)
            {
                // A corrupt / half-written snapshot must never brick the agent: start this
                // conversation fresh rather than throwing on every turn.
                Console.Error.WriteLine(
                    $"[InProcessReasonerAgentProvider] Ignoring unreadable state for conversation " +
                    $"'{conversation.Id}': {ex.Message}");
                conversation.Messages.Clear();
                conversation.Session = null;
            }
        }

        conversation.Loaded = true;
    }

    // Writes the conversation snapshot atomically (temp file + move). Callers MUST hold the gate.
    private async Task PersistAsync(Conversation conversation, CancellationToken cancellationToken)
    {
        JsonElement? sessionState = conversation.Session is null
            ? null
            : await _reasoner
                .SerializeSessionAsync(conversation.Session, SerializerOptions, cancellationToken)
                .ConfigureAwait(false);

        var record = new PersistedConversation
        {
            Messages = [.. conversation.Messages],
            Session = sessionState
        };

        var path = FilePath(conversation.Id);
        var tempPath = path + ".tmp";

        await using (var stream = File.Create(tempPath))
        {
            await JsonSerializer.SerializeAsync(stream, record, SerializerOptions, cancellationToken)
                .ConfigureAwait(false);
        }

        File.Move(tempPath, path, overwrite: true);
    }

    public override async Task<string> CreateConversationAsync(CancellationToken cancellationToken)
    {
        var id = Guid.NewGuid().ToString("n");
        var conversation = new Conversation { Id = id, Loaded = true };
        _conversations[id] = conversation;

        await conversation.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await PersistAsync(conversation, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            conversation.Gate.Release();
        }

        return id;
    }

    public override async Task<ChatMessage> CreateMessageAsync(
        string conversationId, ChatMessage conversationMessage, CancellationToken cancellationToken)
    {
        var conversation = GetOrCreate(conversationId);
        await conversation.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(conversation, cancellationToken).ConfigureAwait(false);

            if (string.IsNullOrEmpty(conversationMessage.MessageId))
            {
                conversationMessage.MessageId = Guid.NewGuid().ToString("n");
            }

            conversation.Messages.Add(conversationMessage);
            await PersistAsync(conversation, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            conversation.Gate.Release();
        }

        return conversationMessage;
    }

    public override async Task<ChatMessage> GetMessageAsync(
        string conversationId, string messageId, CancellationToken cancellationToken)
    {
        var conversation = GetOrCreate(conversationId);
        await conversation.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(conversation, cancellationToken).ConfigureAwait(false);
            return conversation.Messages.FirstOrDefault(m => m.MessageId == messageId)
                ?? throw new KeyNotFoundException(
                    $"Message '{messageId}' not found in conversation '{conversationId}'.");
        }
        finally
        {
            conversation.Gate.Release();
        }
    }

    public override async IAsyncEnumerable<ChatMessage> GetMessagesAsync(
        string conversationId, int? limit, string? after, string? before, bool newestFirst,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var conversation = GetOrCreate(conversationId);
        List<ChatMessage> snapshot;
        await conversation.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(conversation, cancellationToken).ConfigureAwait(false);
            snapshot = [.. conversation.Messages];
        }
        finally
        {
            conversation.Gate.Release();
        }

        if (newestFirst)
        {
            snapshot.Reverse();
        }

        var count = 0;
        foreach (var message in snapshot)
        {
            if (limit is int max && count >= max)
            {
                yield break;
            }

            count++;
            yield return message;
        }
    }

    public override async IAsyncEnumerable<AgentResponseUpdate> InvokeAgentAsync(
        string agentId, string? agentVersion, string? conversationId,
        IEnumerable<ChatMessage>? messages, IDictionary<string, object?>? inputArguments,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var conversation = GetOrCreate(conversationId);
        await conversation.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureLoadedAsync(conversation, cancellationToken).ConfigureAwait(false);
            conversation.Session ??= await _reasoner.CreateSessionAsync(cancellationToken).ConfigureAwait(false);

            await foreach (var update in _reasoner
                .RunStreamingAsync(messages ?? [], conversation.Session, (AgentRunOptions?)null, cancellationToken)
                .ConfigureAwait(false))
            {
                yield return update;
            }

            // The streamed run advanced the reasoner session in place; snapshot it so the reasoner
            // keeps its memory across a process restart.
            await PersistAsync(conversation, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            conversation.Gate.Release();
        }
    }
}
