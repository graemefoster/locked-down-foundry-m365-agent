---
name: GraeIdentity
description: |
  Guide a user through the GraeIdentity identity-management process to check and request
  application access roles. Use when a problem has been identified as an access or permission
  issue — for example a user is missing a role required to use an application (such as the
  GraeCRM access role) and needs to request it and get it approved.
  Triggers: "request access", "missing role", "need a role", "permission / access issue",
  "check my access in GraeIdentity", "AccessGraeCRM role".
---

# GraeIdentity Identity-Management Process

GraeIdentity is a fictitious identity-management application in this proof-of-concept. Use this
skill to take a user through checking their current access and requesting a required role when a
problem has been identified as a permission issue (for example, GraeCRM will not start because
the account is missing the **AccessGraeCRM** role).

Follow the process exactly. Do not invent alternative URLs, roles, policies, support teams, or
remediation steps.

## GraeIdentity application guide

GraeIdentity is available at **https://graeidentity.localtest.me**.

Its relevant navigation and controls are:

- **My Access**: the main navigation item for the signed-in user's application access.
- **Application Access**: a page listing applications and current access status.
- **GraeCRM**: the application entry to open.
- **Assigned Roles**: a section showing roles currently assigned to the user.
- **Available Roles**: a section showing roles the user may request.
- **AccessGraeCRM**: the role required to start and use GraeCRM.
- **Request access**: the button that begins a role request.
- **Business justification**: a required text field in the request form.
- **Submit request**: the button that sends the request for approval.
- **Request status**: a field that displays **Pending approval**, **Approved**, or **Denied**.

AccessGraeCRM is request-based. The user cannot approve their own request. A submitted request
may remain pending until an approver acts on it.

Remember: you cannot operate GraeIdentity. Never claim you opened GraeIdentity, inspected an
account, submitted a request, approved a request, or changed a role. Only the user can perform
those actions. Treat screenshots as the source of truth; do not infer text, status, identity, or
actions that are not visible.

## 1. Open GraeIdentity and verify the account

Ask the user to:

1. Open **https://graeidentity.localtest.me**.
2. Sign in if prompted.
3. Open the account menu in the upper-right corner.
4. Provide a screenshot showing the GraeIdentity header and the signed-in account identifier.

Verify from the screenshot that the user is in GraeIdentity and that an account identifier is
visible. Ask the user to confirm this is the same account they use for the application with the
access problem (for example GraeCRM). If it is the wrong account, guide them to sign out and
sign back in with the correct account before continuing.

## 2. Check the current role assignment

Ask the user to select **My Access**, open **Application Access**, and choose **GraeCRM**. Then
ask for a screenshot that includes the application name and the **Assigned Roles** section.

Evaluate the screenshot as follows:

- If **AccessGraeCRM** appears under Assigned Roles with status **Active**, ask the user to retry
  the application. Do not submit another request.
- If AccessGraeCRM is absent, continue to the role-request process.
- If the role shows **Pending approval**, explain that the request has already been submitted and
  stop the request flow.
- If the role shows **Expired**, **Denied**, or another unexpected status, state the visible
  status and guide the user to check Available Roles for a new request. Do not reinterpret the
  status as active access.

## 3. Request AccessGraeCRM

Guide the user through these steps one at a time:

1. In the GraeCRM application page, open **Available Roles**.
2. Locate **AccessGraeCRM** and select **Request access**.
3. In **Business justification**, enter a brief work-related reason for needing GraeCRM. Help
   draft the justification if asked, but do not fabricate a job title, manager, project, urgency,
   or business need.
4. Review the application name, role name, and signed-in account before submission.

Before the user selects Submit request, ask for a screenshot showing **GraeCRM**,
**AccessGraeCRM**, the signed-in account, and the completed Business justification. Verify those
details and explicitly call out any mismatch. Do not ask the user to expose sensitive
information.

After the details are verified, instruct the user to select **Submit request** and provide a
screenshot of the resulting Request status.

## 4. Interpret the request result

- **Pending approval**: explain the request was submitted successfully and must be approved
  before the application will work. Do not promise an approval time or identify an approver
  unless that information is visible in the UI.
- **Approved**: ask the user to sign out of the application, sign back in, and try again.
- **Denied**: report that the request was denied and ask the user to review any visible decision
  reason. This PoC cannot override the decision.
- No confirmation or an error: ask for the exact visible message and a screenshot containing the
  GraeIdentity page context. Do not assume the request was submitted.

## 5. Confirm resolution

When AccessGraeCRM is shown as **Active** or **Approved**, ask the user to retry the application.
Consider the access issue resolved only when the user confirms the application now starts
successfully.

If the active role is clearly verified but the application still does not start, summarise the
evidence collected — the account identifier, the active AccessGraeCRM role, and the exact
application error — and use the **EscalationSkill** to raise an escalation to application support,
giving the user the ticket reference it returns. Do not invent further technical fixes.

If an access request is **Denied** and the user needs the decision reviewed, use the
**EscalationSkill** to escalate to a human rather than attempting to override the decision.
