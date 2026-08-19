---
name: EscalationSkill
description: |
  Escalate a support case to a human support team when first-line triage cannot resolve it.
  Use when the supported diagnostic steps are exhausted, a request was denied, the user asks
  to escalate or raise a ticket, or the problem is outside the PoC's supported scope and needs
  a human. Provides an escalation tool that returns a support ticket reference.
  Triggers: "escalate", "raise a ticket", "log a case", "speak to a human", "this isn't fixed",
  "hand this to support".
---

# Escalation

Use this skill to escalate a support case to a human support team once first-line triage has
been exhausted or the user explicitly asks to escalate. It provides an escalation tool that
records the case and returns a ticket reference the user can quote.

> **PoC note:** The escalation tool is a proof-of-concept stub. It does not actually notify any
> team — it returns a randomly generated ticket reference so the hand-off can be demonstrated.
> Do not imply a real person has been paged or promise a response time.## When to escalate

Escalate when any of the following is true:

- The supported triage steps have been completed but the problem persists (for example, the
  required access role is verified as active but the application still will not start).
- A required action failed in a way this PoC cannot resolve (for example, an access request was
  **Denied** and the user needs a human to review it).
- The user's issue is outside the scope of the available skills and needs a human.
- The user explicitly asks to escalate, raise a ticket, or speak to a human.

Do not escalate before working through the relevant triage skill, unless the user insists.

## Raising the escalation

1. Summarise the case for the user and confirm the key facts before escalating:
   - the affected account identifier,
   - the application involved (for example, GraeCRM),
   - the exact error or symptom,
   - the triage steps already completed and their outcome.
2. Run the bundled escalation tool from this skill's directory, passing what you have gathered:

   ```bash
   bash scripts/escalate.sh \
     --summary "<one-line description of the issue and steps already tried>" \
     --account "<affected account identifier>" \
     --application "<application, e.g. GraeCRM>"
   ```

   The tool is a small .NET program (the `escalate` subcommand of the agent binary; the wrapper
   locates it automatically). It prints a JSON object containing a `ticket_number`, `status`,
   `queue`, and `created_utc`. All arguments are optional; include whatever you have confirmed.

3. Read the `ticket_number` from the tool's output and give it to the user, along with a short
   summary of what was escalated and the current status. For example: *"I've escalated this to
   Tier 2 Support. Your reference is ESC-XXXXXXX — please quote it in any follow-up."*

Do not invent a ticket number yourself — always use the number returned by the tool. If the tool
fails to run, tell the user the escalation could not be raised rather than fabricating a
reference.
